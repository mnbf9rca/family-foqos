# Fix #286 — Reset Sync poisons CKSyncEngine state (crash-loop) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop "Reset Sync" from enqueuing a `.deleteZone` that coexists with pending `.saveRecord`/`.saveZone` for the same zone (which trips a CloudKit-internal assertion at `sendChanges()`), and self-heal installs already stuck in the resulting crash-loop.

**Architecture:** Three implementation-level changes, none of which alter the §8.1 reset protocol's delete→recreate→seed sequence: **(A)** `ResetController.beginReset` clears all pending record-zone + database changes before enqueuing the `deleteZone`; **(B)** the `.deleting`-stage resume (`reenqueueDeleting`) does the same before re-enqueuing its `deleteZone`; **(D)** `SyncEngineController.start()` self-heals by discarding a restored engine serialization that carries a pending zone-deletion (or was captured mid-reset) and re-bootstrapping a fresh engine — preserving `resetIntent`/`pendingSeedIntent`/tombstones (which live in `SyncEngineStore`, not the serialization). Diagnostic instrumentation added during Phase 1 is removed at the end.

**Tech Stack:** Swift 6, `@MainActor`, CloudKit `CKSyncEngine`, SwiftData, XCTest with `MockSyncEngineDriver`/`MockResetOutbox` seams.

## Global Constraints

- **Confirmed root cause (issue #286, reproduced on device iOS 27.0):** at `beginReset`, the I11 seed's record-saves (`emergency-settings` + profiles) were still pending; `beginReset` enqueued `deleteZone(DeviceSync)` on top → the send carried `db=deleteZone(DeviceSync) rec=save(...)×4` → CloudKit `_assertionFailure` synchronously at `engine.sendChanges()` entry (before `nextRecordZoneChangeBatch`, before network). It persists because the poisoned pair is serialized into `engineState`; the T1 strip removes the pending `deleteZone` but the engine still asserts on the rebuilt `[saveZone + saves]` seed — so the serialization must be **discarded**, not stripped. See the confirmed-diagnosis comment on #286.
- **The invariant to enforce everywhere:** a pending `.deleteZone(DeviceSync)` must never coexist with any pending `.saveRecord`/`.saveZone` for that zone in the engine queue at a `sendChanges()`.
- **Decision-gate outcome:** this is an **implementation** defect, not a protocol defect — do not redesign §8; refine §8.1 step 1, the §8.1 `.deleting` resume, and the §3 strip only.
- **Zone name:** `CloudKitConstants.syncZoneName == "DeviceSync"`; the engine manages exactly this one zone. `zoneID = CKRecordZone.ID(zoneName: syncZoneName, ownerName: CKCurrentUserDefaultName)`.
- **Self-heal must not require reinstall:** a user mid-crash-loop must recover on next launch.
- **No live users** (pre-release): prefer the structural fix; no migration/back-compat constraints.
- **House rules:** 2-space indent; `Log` (never `print`); never force-commit/amend — new commits only; run `swift-format` (pre-commit hook auto-formats); request code review before merge.
- **Tests:** boot the iPhone 17 simulator ONCE and reuse its UUID in `-destination 'platform=iOS Simulator,id=<UUID>'` (never the device name — it clones a new sim each run). Pin `now`: one `let now = Date()` per test.
- **Build note (already applied in this worktree):** `git config core.hooksPath .githooks` (was an absolute path that hard-failed the "Configure Git Hooks" build phase for every checkout). Keep it relative.

## Conformance notes (reset-flow steps changed)

The reset acceptance contract for the CKSyncEngine path is `docs/plans/2026-07-02-sync-engine-design.md` §8 + the S-scenarios — **not** the `reset-sync-a1-*` corpus, which is the pre-#267 query-based design and never deletes/recreates a zone (it models none of this mechanism). For every step this plan changes:

- **§8.1 step 1 (origin `beginReset`):** contract says "Enqueue `deleteZone(DeviceSync)`; `sendChanges()`." Change: quiesce the pending queue first so the `deleteZone` send is `[deleteZone]` alone. Conformance: the delete→recreate→seed sequence is unchanged; the seed's record-saves are re-derived at §8.1 step 4 / I11 after recreation, so nothing durable is lost. Covered by S-13 (origin resume) + the new Task 1 test.
- **§8.1 `.deleting` resume (`reenqueueDeleting`):** contract says "Zone changes for a resumed stage are re-enqueued only after this gate passes (the T1 strip removed the restored ones)." Change: also clear pending record-saves before re-enqueuing the `deleteZone`, matching the strip's intent (no unsafe restored state reaches a send). Covered by S-13 + new Task 2 test.
- **§3 / AB-4 / S-38 T1 strip:** contract says the strip removes restored pending `.deleteRecord`s (except legacy) and all restored pending database changes. Change: **before** the strip, if the restored serialization carries a pending `.deleteZone` (or an active `resetIntent` exists), discard the whole serialization and re-init the engine with `nil` — the strip cannot neutralize a serialization poisoned by an in-flight zone deletion (proven on-device: the rebuilt `[saveZone+saves]` seed still asserts). Conformance: strengthens the strip's stated goal ("never let restored unsafe state reach a send"); `resetIntent`/`pendingSeedIntent`/tombstones survive (they are not in the serialization). Covered by new Task 3 tests.

---

## File Structure

- **Modify** `Foqos/CloudKit/SyncEngine/ResetController.swift`
  - `protocol ResetOutbox`: add `func clearPendingChangesForReset()`.
  - `ResetController.beginReset(...)`: call `outbox.clearPendingChangesForReset()` before `enqueueZoneDelete()`.
  - `ResetController.reenqueueDeleting()`: same, before `enqueueZoneDelete()`.
- **Modify** `Foqos/CloudKit/SyncEngine/SyncEngineController+Reset.swift`
  - `DriverResetOutbox`: implement `clearPendingChangesForReset()`.
- **Modify** `Foqos/CloudKit/SyncEngine/SyncEngineController.swift`
  - `start()`: discard a poisoned restored serialization + rebuild the driver with `nil`.
  - Add private `restoredStateIsPoisoned() -> Bool`.
  - Remove the `[#286 DIAGNOSTIC]` logging (final cleanup task).
- **Modify** `Foqos/CloudKit/SyncEngine/CKSyncEngineDriver.swift`
  - Remove the `[#286 DIAGNOSTIC]` logging + `describePending`/`describePendingRecords` (final cleanup task).
- **Modify** `FoqosTests/Mocks/ResetSeamMocks.swift`
  - `MockResetOutbox`: add `clearPendingChangesForReset()` (counter).
- **Modify** `FoqosTests/SyncEngineResetTests.swift`
  - Add Task 1 + Task 2 driver-level coexistence tests.
- **Modify** `FoqosTests/SyncEngineControllerTests.swift`
  - Add Task 3 self-heal tests.
- **Delete** `FoqosTests/CKSyncEnginePoisonProbeTests.swift` (Phase 1 throwaway; final cleanup task).

---

### Task 1: `beginReset` clears the pending queue before the zone delete (Fix A)

**Files:**
- Modify: `Foqos/CloudKit/SyncEngine/ResetController.swift` (protocol `ResetOutbox` ~lines 6-15; `beginReset` ~lines 109-123)
- Modify: `Foqos/CloudKit/SyncEngine/SyncEngineController+Reset.swift` (`DriverResetOutbox` ~lines 20-39)
- Modify: `FoqosTests/Mocks/ResetSeamMocks.swift` (`MockResetOutbox` ~lines 7-21)
- Test: `FoqosTests/SyncEngineResetTests.swift`

**Interfaces:**
- Produces: `ResetOutbox.clearPendingChangesForReset()` — removes every pending record-zone change and database change from the engine queue. `DriverResetOutbox` implements it over the driver; `MockResetOutbox` counts calls.
- Consumes: `MockSyncEngineDriver(pendingRecordZoneChanges:pendingDatabaseChanges:)`, `DriverResetOutbox(driver:zoneID:)`, `MockResetSeeder`, `MockRecordFetcher`, `MockResetConflictSurfacer` (existing test seams).

- [ ] **Step 1: Write the failing test** (append to `FoqosTests/SyncEngineResetTests.swift`)

```swift
// MARK: - #286 coexistence guard (origin)

func testGivenPendingSeedSaves_WhenBeginReset_ThenDeleteZoneAloneNoRecordSaves() {
  let now = Date()
  let mockDriver = MockSyncEngineDriver(
    pendingRecordZoneChanges: [
      .saveRecord(CKRecord.ID(recordName: "emergency-settings", zoneID: zoneID)),
      .saveRecord(CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID)),
    ],
    pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
  let controller = ResetController(
    store: store, outbox: DriverResetOutbox(driver: mockDriver, zoneID: zoneID),
    seeder: MockResetSeeder(), fetcher: MockRecordFetcher(),
    surfacer: MockResetConflictSurfacer(), deviceId: "device-A")

  controller.beginReset(clearRemoteAppSelections: true, now: now)

  // #286: the delete send must carry ONLY the deleteZone — no coexisting record-saves or
  // saveZone (CKSyncEngine asserts on that combination at sendChanges()).
  XCTAssertEqual(mockDriver.pendingDatabaseChanges, [.deleteZone(zoneID)])
  XCTAssertTrue(
    mockDriver.pendingRecordZoneChanges.isEmpty,
    "pending record saves must be cleared before the zone delete")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SyncEngineResetTests/testGivenPendingSeedSaves_WhenBeginReset_ThenDeleteZoneAloneNoRecordSaves | xcpretty`
Expected: FAIL — either a compile error (`clearPendingChangesForReset` unknown) or the assertion fails because `pendingRecordZoneChanges` still holds the two saves and `pendingDatabaseChanges` holds `[saveZone, deleteZone]`.

- [ ] **Step 3a: Add the protocol method** — in `ResetController.swift`, inside `protocol ResetOutbox`, after `func requestSend()`:

```swift
  /// #286: remove every pending record-zone change and database change so a subsequent
  /// `.deleteZone` cannot coexist with a `.saveRecord`/`.saveZone` for the zone (CKSyncEngine
  /// asserts on that combination at `sendChanges()`). Seed record-saves are re-derived after
  /// recreation (§8.1 step 4 / I11), so nothing durable is lost.
  func clearPendingChangesForReset()
```

- [ ] **Step 3b: Implement it on the driver outbox** — in `SyncEngineController+Reset.swift`, inside `DriverResetOutbox`, after `func requestSend()`:

```swift
  func clearPendingChangesForReset() {
    driver.remove(pendingRecordZoneChanges: driver.pendingRecordZoneChanges)
    driver.remove(pendingDatabaseChanges: driver.pendingDatabaseChanges)
  }
```

- [ ] **Step 3c: Implement it on the mock** — in `FoqosTests/Mocks/ResetSeamMocks.swift`, inside `MockResetOutbox`:

```swift
  var clearPendingCount = 0
```
and, alongside the other methods:
```swift
  func clearPendingChangesForReset() { clearPendingCount += 1 }
```

- [ ] **Step 3d: Call it in `beginReset`** — in `ResetController.swift`, in `beginReset(...)`, replace the tail `outbox.enqueueZoneDelete(); outbox.requestSend()` with:

```swift
    outbox.clearPendingChangesForReset()  // #286: no record-save may coexist with the deleteZone
    outbox.enqueueZoneDelete()
    outbox.requestSend()
```

- [ ] **Step 4: Run test to verify it passes**

Run: same command as Step 2.
Expected: PASS.

- [ ] **Step 5: Run the full reset + controller suites (no regressions)**

Run: `xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SyncEngineResetTests -only-testing:FoqosTests/SyncEngineControllerTests | xcpretty`
Expected: PASS (existing `MockResetOutbox`-based tests still compile via the new `clearPendingChangesForReset()` counter).

- [ ] **Step 6: Commit**

```bash
git add Foqos/CloudKit/SyncEngine/ResetController.swift \
        Foqos/CloudKit/SyncEngine/SyncEngineController+Reset.swift \
        FoqosTests/Mocks/ResetSeamMocks.swift FoqosTests/SyncEngineResetTests.swift
git commit -m "fix(#286): clear pending changes before the reset zone delete (origin)"
```

---

### Task 2: `.deleting` resume clears the pending queue before re-enqueuing the zone delete (Fix B)

**Files:**
- Modify: `Foqos/CloudKit/SyncEngine/ResetController.swift` (`reenqueueDeleting()` ~lines 283-286)
- Test: `FoqosTests/SyncEngineResetTests.swift`

**Interfaces:**
- Consumes: `ResetOutbox.clearPendingChangesForReset()` (Task 1). `ResetController.resume()` (existing, `async`). `MockRecordFetcher` default result is `.success(nil)` ⇒ the `.deleting` gate's direct fetch returns "no command" ⇒ `reenqueueDeleting()`.

- [ ] **Step 1: Write the failing test** (append to `FoqosTests/SyncEngineResetTests.swift`)

```swift
func testGivenDeletingResumeWithPendingSaves_WhenResume_ThenDeleteZoneAloneNoCoexistence() async {
  let now = Date()
  store.resetIntent = ResetIntent(
    id: UUID(), clear: true, stage: .deleting, priorCommandId: nil)
  let mockDriver = MockSyncEngineDriver(
    pendingRecordZoneChanges: [
      .saveRecord(CKRecord.ID(recordName: "emergency-settings", zoneID: zoneID))
    ],
    pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
  // Default MockRecordFetcher returns .success(nil) ⇒ gate sees "no command" ⇒ reenqueueDeleting.
  let controller = ResetController(
    store: store, outbox: DriverResetOutbox(driver: mockDriver, zoneID: zoneID),
    seeder: MockResetSeeder(), fetcher: MockRecordFetcher(),
    surfacer: MockResetConflictSurfacer(), deviceId: "device-A")
  _ = now  // gate is date-independent; pinned per house rule

  await controller.resume()

  XCTAssertEqual(mockDriver.pendingDatabaseChanges, [.deleteZone(zoneID)])
  XCTAssertTrue(
    mockDriver.pendingRecordZoneChanges.isEmpty,
    "#286: a resumed .deleting stage must not re-add a deleteZone alongside pending saves")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SyncEngineResetTests/testGivenDeletingResumeWithPendingSaves_WhenResume_ThenDeleteZoneAloneNoCoexistence | xcpretty`
Expected: FAIL — `pendingRecordZoneChanges` still holds the save and `pendingDatabaseChanges` holds `[saveZone, deleteZone]`.

- [ ] **Step 3: Implement** — in `ResetController.swift`, change `reenqueueDeleting()`:

```swift
  private func reenqueueDeleting() {
    outbox.clearPendingChangesForReset()  // #286: quiesce before re-adding the deleteZone
    outbox.enqueueZoneDelete()
    outbox.requestSend()
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: same command as Step 2.
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Foqos/CloudKit/SyncEngine/ResetController.swift FoqosTests/SyncEngineResetTests.swift
git commit -m "fix(#286): clear pending changes before re-enqueuing the resumed deleteZone"
```

---

### Task 3: `start()` self-heals a poisoned restored serialization (Fix D)

**Files:**
- Modify: `Foqos/CloudKit/SyncEngine/SyncEngineController.swift` (`start()` ~lines 94-116; add `restoredStateIsPoisoned()`)
- Test: `FoqosTests/SyncEngineControllerTests.swift`

**Interfaces:**
- Consumes: `driverFactory: (Data?) -> SyncEngineDriver` (existing ctor param), `SyncEngineStore.engineState`, `SyncEngineStore.resetIntent`, `driver.pendingDatabaseChanges`, `controller.driver` (internal, `@testable`), `controller.startupTask` (internal).
- Produces: after `start()`, if the restored state is poisoned, `store.engineState == nil` and the active `driver` is a fresh engine built with `nil` (no pending zone-deletion).

- [ ] **Step 1: Write the failing tests** (append to `FoqosTests/SyncEngineControllerTests.swift`)

```swift
// MARK: - #286 self-heal (discard poisoned restored serialization)

func testGivenRestoredStateHasPendingZoneDelete_WhenStart_ThenSerializationDiscardedAndFreshEngine() async {
  store.engineState = Data([0x01])  // non-nil stand-in for a poisoned serialization
  let poisoned = MockSyncEngineDriver(pendingDatabaseChanges: [.deleteZone(zoneID)])
  let fresh = MockSyncEngineDriver()
  var pending: [MockSyncEngineDriver] = [poisoned, fresh]
  var factoryArgs: [Data?] = []
  let controller = SyncEngineController(
    modelContext: context, store: store,
    driverFactory: { data in factoryArgs.append(data); return pending.removeFirst() },
    apply: apply, provider: provider, sessionSync: sessionSync, deviceId: deviceId)

  controller.start()
  await controller.startupTask?.value

  XCTAssertNil(store.engineState, "#286 self-heal: poisoned serialization discarded")
  XCTAssertEqual(factoryArgs.count, 2, "engine rebuilt exactly once after discard")
  XCTAssertNil(factoryArgs[1], "rebuilt with nil serialization (fresh engine, no restored tokens)")
  XCTAssertFalse(
    (controller.driver as! MockSyncEngineDriver).pendingDatabaseChanges.contains {
      if case .deleteZone = $0 { return true } else { return false }
    },
    "active engine carries no pending zone-deletion")
}

func testGivenNonPoisonedRestoredState_WhenStart_ThenSerializationKeptEngineNotRebuilt() async {
  store.engineState = Data([0x01])  // non-nil, no reset in progress, no pending deleteZone
  let normal = MockSyncEngineDriver()
  var factoryCount = 0
  let controller = SyncEngineController(
    modelContext: context, store: store,
    driverFactory: { _ in factoryCount += 1; return normal },
    apply: apply, provider: provider, sessionSync: sessionSync, deviceId: deviceId)

  controller.start()
  await controller.startupTask?.value

  XCTAssertEqual(factoryCount, 1, "no rebuild for a healthy serialization")
  XCTAssertNotNil(store.engineState, "healthy serialization retained (ordinary relaunch, S-19)")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SyncEngineControllerTests/testGivenRestoredStateHasPendingZoneDelete_WhenStart_ThenSerializationDiscardedAndFreshEngine -only-testing:FoqosTests/SyncEngineControllerTests/testGivenNonPoisonedRestoredState_WhenStart_ThenSerializationKeptEngineNotRebuilt | xcpretty`
Expected: the first test FAILS (`factoryArgs.count == 1`, `store.engineState != nil`); the second PASSES already (documents no-regression).

- [ ] **Step 3: Implement** — in `SyncEngineController.swift`, change the head of `start()` (immediately after the `guard`):

```swift
  func start() {
    guard state == .disabled || state == .purged else { return }
    driver = driverFactory(store.engineState)
    // #286 self-heal: a serialization that carries a pending zone-deletion (or was captured
    // mid-reset) cannot be safely restored — CKSyncEngine asserts on subsequent record-saves
    // to that zone even after the pending .deleteZone is removed. Discard it and rebuild a
    // fresh engine; resetIntent / pendingSeedIntent / tombstones live in `store` (not the
    // serialization) and drive a clean re-seed. Lost fetch tokens (⇒ full re-fetch) are the
    // accepted cost of recovering an otherwise-bricked install.
    if store.engineState != nil && restoredStateIsPoisoned() {
      Log.warning(
        "[#286] restored engine state carries a pending zone-deletion; discarding "
          + "serialization and re-bootstrapping", category: .sync)
      store.engineState = nil
      driver = driverFactory(nil)
    }
    funnel = MutationFunnel(
      modelContext: modelContext, store: store, driver: driver, deviceId: deviceId)
    // ...rest of start() unchanged...
```

Add this private helper near `performStrip()`:

```swift
  /// #286: a restored serialization is unsafe to keep if it carries a pending `.deleteZone`
  /// for the sync zone, or if a `resetIntent` is in progress (the reset state machine, not
  /// the restored queue/tokens, is the source of truth for zone changes — defense in depth).
  private func restoredStateIsPoisoned() -> Bool {
    if store.resetIntent != nil { return true }
    return driver.pendingDatabaseChanges.contains {
      if case .deleteZone(let id) = $0 { return id == zoneID }
      return false
    }
  }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: same command as Step 2.
Expected: both PASS.

- [ ] **Step 5: Run the full controller + reset + cutover suites (no regressions)**

Run: `xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SyncEngineControllerTests -only-testing:FoqosTests/SyncEngineResetTests -only-testing:FoqosTests/SyncEngineCutoverTests -only-testing:FoqosTests/SyncEngineControllerCutoverTests | xcpretty`
Expected: PASS. In particular the ordinary-relaunch test (`...S-19`) and origin-resume tests must remain green (they have `resetIntent == nil` or no pending `deleteZone` in the restored state, so they are not discarded).

- [ ] **Step 6: Commit**

```bash
git add Foqos/CloudKit/SyncEngine/SyncEngineController.swift FoqosTests/SyncEngineControllerTests.swift
git commit -m "fix(#286): discard a reset-poisoned engine serialization on launch (self-heal)"
```

---

### Task 4: Skeptic pass on interleavings around the changed reset steps

Not a code task by itself — a written adversarial review the implementer performs and records (as a commit message note or a comment on #286) before device verification. Confirm each interleaving stays legal (never a `.deleteZone` coexisting with a `.saveRecord`/`.saveZone` at any `sendChanges()`), reading the code as changed by Tasks 1–3.

- [ ] **Step 1: Walk each interleaving and confirm the invariant holds**

1. **Origin, seed still pending** (the reproduced case): `beginReset` → `clearPendingChangesForReset()` empties the queue → `enqueueZoneDelete` → send `[deleteZone]`. ✅ legal.
2. **Relaunch at `.deleting`, `pendingSeedIntent` true, poisoned serialization:** `start()` discards serialization (Fix D) → fresh engine (`engineState == nil`). `runStartupSequence`: `applySeedDecision` seeds `[saveZone + saves]` (no send yet — seeding never calls `requestSend`). `onResumeReset` schedules `resume()`; `runDeletingGate` awaits a fetch, then `reenqueueDeleting` → `clearPendingChangesForReset()` (removes the seed's `saveZone+saves`) → `enqueueZoneDelete` → **first send** `[deleteZone]`. ✅ Confirm no `sendChanges()` fires between the seed and the quiesce (only `fetchChanges()` — a fetch, not a send — runs at the tail of `runStartupSequence`).
3. **Relaunch at `.recreating`, poisoned serialization** (the reproduced relaunch): `start()` discards → fresh engine. `applySeedDecision` seeds `[saveZone + saves]`; `resume(.recreating)` enqueues `saveZone` (dedup). Send `[saveZone + saves]` on a **fresh** engine = first-boot shape. ✅ legal (no `deleteZone` present or in the restored engine).
4. **Relaunch at `.seeding`, no pending `deleteZone`:** not discarded (unless `resetIntent != nil` defense-in-depth trips — which it does, so it IS discarded → fresh engine → `[saveZone + saves + command]`). ✅ legal. If the defense-in-depth condition were removed, the un-discarded path is the normal seeding shape that already works.
5. **T5 fetched zone-deletion** (`handleZoneDeletions .deleted`): enqueues `seedZoneAndRecords()` only — no `.deleteZone` is ever enqueued (the zone is already gone server-side). ✅ legal.
6. **Concurrent funnel save during an active reset:** a `.saveRecord` enqueued by the funnel after `beginReset` has sent `[deleteZone]` and before recreation would re-introduce coexistence. Confirm the reset window: `beginReset` sets `resetIntent`; the funnel path (`MutationFunnel`) is the only other `.saveRecord` source. **Action:** verify whether `MutationFunnel.enqueueSave` can fire between `beginReset` and `.seeding`; if so, note it as a residual and confirm the next launch's Fix D + `.deleting`/`.recreating` handling re-quiesces it. (Record the finding; do not expand scope without evidence.)

- [ ] **Step 2: Record the skeptic-pass findings** on #286 (comment) or in the Task 5 commit message. If interleaving 6 reveals a real hole, add a follow-up task; otherwise state it is covered by Fix D on the next launch.

---

### Task 5: Device verification — two-device checklist (reset scenarios) [MAINTAINER-ASSISTED]

The exit criterion is `docs/sync-engine-two-device-checklist.md`, run on-device (it has never been executed). The `[#286 DIAGNOSTIC]` logging is still present at this point — use it to confirm the fix on-device, THEN remove it in Task 6.

- [ ] **Step 1: Build the worktree to a device (iOS 27) and reproduce the original steps**

Fresh install, enable Profile Sync, create ≥1 profile, then **Settings → Reset Syncing → "Clear App Selections."** With Console filtered to `#286`, confirm:
- The origin `sendChanges pending:` line now shows `db=deleteZone(DeviceSync) rec=` (empty `rec`) — the delete send is `[deleteZone]` alone.
- **No crash.** The reset proceeds through recreate + seed; subsequent sends show `[saveZone …]` / `[save…]` legal shapes.

- [ ] **Step 2: Verify self-heal on an already-poisoned install**

On a device currently in the crash-loop (or one re-poisoned from a pre-fix build), install the fixed build **without deleting the app**. Confirm Console shows `[#286] … discarding serialization and re-bootstrapping` and the app launches and recovers (no crash-loop) — no reinstall required.

- [ ] **Step 3: Run the full `docs/sync-engine-two-device-checklist.md`, reset rows included**

Two devices on the same iCloud account. Tick every row. Pay special attention to:
- **Reset Sync — Keep App Selections** and **— Clear App Selections** (origin re-seeds; other device converges / re-selects).
- **Device offline across a reset**, **Token-expired device across a reset** (re-seed; nothing deleted).
- **Restore-from-backup then edit** (heals forward).

- [ ] **Step 4: Record results** — paste the checklist outcomes (and the `#286` Console confirmation from Steps 1–2) as a comment on #286. Any failed row blocks merge.

---

### Task 6: Remove diagnostic instrumentation and the probe; final green suite

**Files:**
- Modify: `Foqos/CloudKit/SyncEngine/CKSyncEngineDriver.swift` (remove `[#286 DIAGNOSTIC]` log in `sendChanges()` + `describePending`/`describePendingRecords`)
- Modify: `Foqos/CloudKit/SyncEngine/SyncEngineController.swift` (remove `[#286 DIAGNOSTIC]` logs in `performStrip()` and `runStartupSequence`; keep the `[#286]` self-heal `Log.warning` from Task 3 — it is intentional, not diagnostic scaffolding)
- Delete: `FoqosTests/CKSyncEnginePoisonProbeTests.swift`

- [ ] **Step 1: Remove the diagnostic logging**

In `CKSyncEngineDriver.sendChanges()`, restore it to:
```swift
  func sendChanges() {
    let engine = self.engine!
    Task { try? await engine.sendChanges() }
  }
```
and delete the `describePending(_:)` and `describePendingRecords(_:)` static helpers.

In `SyncEngineController.swift`, delete the three `[#286 DIAGNOSTIC]` `Log.error` blocks (`strip BEFORE`, `strip AFTER`, `resume reset`), restoring `performStrip()` and the resume site to their pre-instrumentation bodies. **Do not** remove the Task 3 self-heal `Log.warning` in `start()`.

- [ ] **Step 2: Delete the probe test**

```bash
git rm FoqosTests/CKSyncEnginePoisonProbeTests.swift
```

- [ ] **Step 3: Run the FULL test suite**

Run: `xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' | xcpretty`
Expected: BUILD SUCCEEDS, all tests PASS, and `grep -rn "#286 DIAGNOSTIC" Foqos` returns nothing.

- [ ] **Step 4: Format + commit**

```bash
swift-format --in-place --recursive Foqos
git add -A
git commit -m "chore(#286): remove diagnostic instrumentation and probe after fix verified"
```

- [ ] **Step 5: Open the PR**

```bash
gh pr create --title "Fix #286: Reset Sync poisons CKSyncEngine state (crash-loop)" \
  --body "Fixes #286. Clears pending record/zone changes before the reset zone-delete (origin + .deleting resume) so a .deleteZone never coexists with a .saveRecord/.saveZone (CKSyncEngine asserts on that at sendChanges()); self-heals an already-poisoned install by discarding a reset-poisoned engine serialization on launch. Diagnosis + on-device reproduction: see #286 comments. Two-device checklist (reset scenarios) executed — see #286."
```
Request code review before merging (house rule).

---

## Self-Review

**Spec coverage:**
- "Fix argued against the acceptance corpus, conformance note per changed step" → **Conformance notes** section (with the A1-corpus premise correction) + per-task notes. ✅
- "Self-heal an already-poisoned install on launch" → Task 3 (Fix D) + Task 5 Step 2. ✅
- "Exit criterion = full two-device checklist, reset scenarios included" → Task 5. ✅
- "One skeptic pass on interleavings around the changed reset steps" → Task 4. ✅
- "Prescriptive, per-task TDD, complete code, named tests" → Tasks 1–3 each ship a named failing test + exact code. ✅
- "Commit plan to docs/superpowers/plans/; PR says 'plans the fix for #286'; no implementation" → this file; the plan is written only (no production code changed by *this* plan document). ✅

**Placeholder scan:** no TBD/TODO/"handle edge cases"; every code step shows the code. ✅

**Type consistency:** `clearPendingChangesForReset()` is defined once (protocol) and implemented on `DriverResetOutbox` + `MockResetOutbox`, called in `beginReset` and `reenqueueDeleting`. `restoredStateIsPoisoned()` defined + called in `start()`. `zoneID`, `driverFactory: (Data?) -> SyncEngineDriver`, `MockSyncEngineDriver(pendingRecordZoneChanges:pendingDatabaseChanges:)`, `MockRecordFetcher` default `.success(nil)` all match the current code. ✅
