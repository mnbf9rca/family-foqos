# #294 — New profile does not sync until an incidental foreground: Send-on-Enqueue Fix Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make user-initiated profile create/edit/delete (and location/emergency mutations) propagate to CloudKit **promptly** by triggering a CKSyncEngine send after a successful enqueue, and stop silently **losing** enqueues that hit the `.notAttached` window by deferring them for retry on attach.

**Architecture:** The profile-create path is *enqueue-only*: `finalizeSave → enqueueProfileSave → funnel.enqueueSave → driver.add(pendingRecordZoneChanges)` terminates at `engine.state.add()`, and the driver runs with `automaticallySync = false`, so a queued `.saveRecord` is never transmitted until an incidental `syncNow` (scenePhase `.active`, remote push, or manual "Sync Now"). The fix adds a single `requestSync()` call in the `ProfileSyncManager` enqueue facade after a successful enqueue, and a small deferred-retry set drained on `attachEngine` so a create that lands in the brief `.notAttached` window is re-enqueued instead of dropped. Verified by unit tests (`MockSyncEngineControlling.requestSyncCount`) and a two-device physical acceptance.

**Tech Stack:** Swift 6, `@MainActor`, CKSyncEngine (custom driver seam), SwiftData, XCTest with `MockSyncEngineControlling` / `CutoverRecordingDriver`, custom durable `Log` (category `.sync`), two-device physical verification.

---

## Investigation history (why this replaced the earlier validation plan)

The original #294 framing — "new profile with 'Tap to stop' fails validation, so no profile is created and nothing syncs" — was **falsified**. A code investigation (triple-verified by an adversarial panel) found the issue's cited symbols (`applyNewProfileDefaults`, `didLoadTriggerConfig`) do not exist and no code path clears `stopConditions.manual`. Then the maintainer supplied decisive device evidence (`docs/plans/FamilyFoqos-Logs-2026-07-08-235429.log`):

- The `22:00:50` `validate()` error was the **first** create attempt, before a stop condition was set — **correct** validation behavior on an incomplete config, and a **red herring** for the real defect. It has no effect on sync (a validation failure early-returns from `saveProfile()`; nothing is created or enqueued).
- The profile was then created with **manual stop**, **works**, and **activates** (`22:54:08 AppBlockerUtil "Starting restrictions"`). Its **session** state syncs via `SessionSyncService` direct CAS (`22:54:09 "CAS save succeeded … seq=1"`). But the **profile record** never appears being sent by CKSyncEngine.
- The maintainer observed the profile reached the remote device **only after starting it**, and flagged this **could be coincidence**.

An 8-hypothesis adversarial analysis (coincidence / causal / common-cause) resolved it: the "synced after start" correlation is **coincidental** — starting the profile does not touch profile sync; the flush came from the relaunch/foreground `scenePhase == .active → syncNow` that happened around the same time. Verdicts: **H5 (create enqueues but never sends) = root cause**, **H7 (flush is scenePhase-driven) = supported**; H1/H3/H4/H6/H8 refuted.

---

## Root cause (established; citations re-verified in Task 0.0)

1. **Create path is enqueue-only.** `BlockedProfileView.finalizeSave` (`BlockedProfileView.swift:929`) → `ProfileSyncManager.enqueueProfileSave` (`ProfileSyncManager.swift:213-216`) → `SyncEngineController+Cutover.enqueueProfileSave` (`SyncEngineController+Cutover.swift:29-32`) → `MutationFunnel.enqueueSave` (`MutationFunnel.swift:50-71`) → `CKSyncEngineDriver.add` (`CKSyncEngineDriver.swift:43-45`). The chain terminates at `engine.state.add(pendingRecordZoneChanges:)`. **No `sendChanges()`.**
2. **No auto-send.** `CKSyncEngineDriver` sets `configuration.automaticallySync = false` (`CKSyncEngineDriver.swift:27`). The queued `.saveRecord` is inert until an explicit `driver.sendChanges()`.
3. **The only send path is off the create path.** `requestSync()` = `driver?.fetchChanges(); driver?.sendChanges()` (`SyncEngineController+Cutover.swift:9-12`), reachable only via `ProfileSyncManager.syncNow()` (`ProfileSyncManager.swift:196-199`), whose only callers are scenePhase `.active` (`FoqosApp.swift:152`), remote push (`FoqosApp.swift:378`), and manual "Sync Now" (`SettingsView.swift:176`). **Creating or starting a profile is none of these.**
4. **Secondary bug — silent drop.** If enqueue throws `.notAttached` (engineController nil, or the "I10" window where the controller exists but its `MutationFunnel` isn't built yet — `SyncEngineController+Cutover.swift:30`), `finalizeSave` **catches and swallows** it (`BlockedProfileView.swift:930-933`). The save is then never enqueued **and never retried** — no ordinary-relaunch backfill re-derives it (`restorableRecordNames` runs only under seed conditions). Permanent loss until the user re-edits.
5. **Consistent with the log.** Session 1 shows `engineAttached=true` at creation yet **no** CKSyncEngine `sentRecordZoneChanges`/profile-save entry; the relaunch line 57 `"syncNow skipped: Sync isn't ready yet"` is the `.active` handler firing `syncNow` before attach finished.

---

## Maintainer approval points (folded in from PR #295 review)

The maintainer approved this plan with three implementation points; each is bound into the tasks below:

1. **All five facade verbs.** The enqueue-only gap hits every `SyncEngineControlling` mutation — `enqueueProfileSave`, `enqueueProfileDelete`, `enqueueLocationSave`, `enqueueLocationDelete`, `enqueueEmergencySettingsSave` — not just profile-save. The send-on-enqueue fix **and** the deferred-loss fix must cover all of them (deletes via a tombstone path, because their model is already gone by drain time — see Task 1.4).
2. **AB-4 conformance (explicit).** Send-on-enqueue must fire **only on fresh local mutations and only after the T1 strip has run** — never flushing restored engine state — so it cannot reintroduce the #286 poison hazard. Enforced by the `isSyncReady` gate (Task 1.1) and documented in "AB-4 Conformance", with a dedicated test (Task 1.5).
3. **The `.notAttached` swallow is the permanent-loss half**, correctly closed by deferred-drain-on-attach (Tasks 1.3–1.4).

## Global Constraints

- **Chosen fix = send-on-enqueue + deferred-drain-on-attach**, across **all five** facade verbs (approval point 1). Do not implement a full startup re-scan/backfill; do not touch the trigger/validation UI (it is not the defect).
- **AB-4 invariant (approval point 2).** The send-on-enqueue `requestSync()` runs only when `isSyncReady == true`, a flag set only after `attachEngine` awaits `startupTask` (which runs the T1 strip). `requestSync()` is called **only** from the facade enqueue verbs (fresh local mutations) and the post-startup flush; it is never wired into `handleEvent`/restore/T1-seed. See "AB-4 Conformance".
- **Two-device physical acceptance is authoritative.** The bug is a device-timing/propagation defect; the acceptance test is "create on device A, foregrounded, without starting it and without relaunching → appears on device B within seconds," plus edit and delete propagation.
- **TDD.** Write the failing test first; names follow `testGivenX_WhenY_ThenZ`.
- **The send must stay outside `handleEvent`.** `requestSync()`/`sendChanges()` may only be scheduled outside the CKSyncEngine delegate (`SyncEngineController+Cutover.swift:6-8`). All enqueue facade calls originate from UI actions (outside `handleEvent`), so calling `requestSync()` there is permitted. Do **not** add sends inside `nextRecordZoneChangeBatch`/`handleEvent`.
- **Preserve the delete fallback + I2 contract.** Delete call sites must still receive `.notAttached` (they fall back to a local delete — `BlockedProfileView.swift:826-838`); send-on-enqueue runs only *after* a successful enqueue. The new tombstone-delete verb lives **inside `MutationFunnel`** (an I2-whitelisted enqueue site — `scripts/check-sync-guards.sh`), never in `ProfileSyncManager`.
- **Single build/test stream.** Simulator UUID `B9E4A679-BDF3-4541-A59F-DA4BE21F80ED` (iPhone 17, booted). Never a device *name* in `-destination`. Use `-parallel-testing-enabled NO` if launch hangs.
- **Branch.** Implement on `fix/294-tap-to-stop-validation` off `origin/main`. Do **not** fold into `#286`.
- **No amend/force-push.** Revert temporary probes with normal commits.
- **PR wording.** Plan PR titled **"plans the fix for #294"** (not a closing keyword).
- **#294 blocks #286** (its two-device sync checklist can't run until create-time sync works) and is top of the queue.

---

## File Structure

- Modify: `Foqos/CloudKit/ProfileSyncManager.swift`
  - Add `isSyncReady` flag (set after `startupTask` in `attachEngine`, cleared on `stop`/detach).
  - Add gated `requestSync()` after a successful enqueue in **all five** facade verbs.
  - Add deferred sets (`deferredProfileSaveIds`, `deferredLocationSaveIds`, `deferredDeleteRecordNames: Set<String>`, `deferredEmergencySave: Bool`); record on `.notAttached`; `drainDeferredMutations()` on attach.
- Modify: `Foqos/CloudKit/SyncEngine/SyncEngineControlling.swift`
  - Add `func enqueueDeferredDelete(recordName: String)` to the protocol (tombstone-only delete for a model that is already locally gone).
- Modify: `Foqos/CloudKit/SyncEngine/SyncEngineController+Cutover.swift`
  - Implement `enqueueDeferredDelete(recordName:)` forwarding to the funnel (I10 guard).
- Modify: `Foqos/CloudKit/SyncEngine/MutationFunnel.swift`
  - Add `func enqueueTombstoneDelete(recordName: String)` — sets the tombstone and adds `.deleteRecord`, mirroring the tail of `enqueueDelete` (`:108-109,136-137`) without a model read.
- Modify (tests): `FoqosTests/SyncEngineFacadeTests.swift`, `FoqosTests/Mocks/MockSyncEngineControlling.swift`
  - Add `enqueueDeferredDelete` to the mock (record `deferredDeletes: [String]`); update `testGivenController_WhenFacadeVerbsCalled_ThenTheyForward`; add send-on-enqueue, AB-4-gate, and deferred-drain tests.
- Optional temporary probe (reverted before merge): `Foqos/CloudKit/SyncEngine/MutationFunnel.swift`, `Foqos/CloudKit/SyncEngine/CKSyncEngineDriver.swift` — one log line at enqueue and one at `sendChanges` (with caller) for device baseline/acceptance.

---

## AB-4 Conformance (approval point 2)

The #286 poison arises when a **restored** pending zone-delete (a `pendingDatabaseChange`) is transmitted before the **T1 strip** removes it. Send-on-enqueue must never do this. Two independent guarantees:

1. **Trigger provenance.** `requestSync()` for this feature is added **only** inside the five `ProfileSyncManager` facade enqueue verbs and the post-startup flush in `attachEngine`. Those verbs are invoked exclusively by fresh local mutations (`BlockedProfileView` create/edit/clone/delete, `BlockedProfileListView` reorder/delete, emergency-settings edits). No new `requestSync`/`sendChanges` is added to `handleEvent`, `nextRecordZoneChangeBatch`, `runStartupSequence`, the T1 seed, or any restore path.
2. **Ordering gate.** `start()` creates the `MutationFunnel` synchronously (`SyncEngineController.swift:103`) but the T1 strip runs inside the async `startupTask` (`:121`, MARK "T1 strip (AB-4…)" `:193`). So there is a window where the funnel exists yet restored poison is unstripped. The send is therefore gated on `isSyncReady`, which `attachEngine` sets to `true` **only after** `await controller.startupTask?.value` (`ProfileSyncManager.swift:176`) — i.e. after the T1 strip. In that window an enqueue still records its pending change but does **not** send; the post-startup flush (also post-T1) transmits it. Net: no send can execute before T1 strips the poison.

Task 1.5 asserts both: an enqueue with `isSyncReady == false` records the change but issues **zero** `sendChanges`, and the post-startup flush issues exactly one.

---

## Phase 0 (optional, recommended): device baseline probe

Confirms on the real device that the current build enqueues-without-send, and is reused to confirm the fix flushes promptly. Skip only if you accept the unit tests + two-device acceptance as sufficient.

### Task 0.0: Refresh citations against the build commit

**Files:** none (verification only).

- [ ] **Step 1: Confirm the root-cause anchors still match**

```bash
git rev-parse HEAD
sed -n '27p' Foqos/CloudKit/SyncEngine/CKSyncEngineDriver.swift          # automaticallySync = false
sed -n '9,12p' Foqos/CloudKit/SyncEngine/SyncEngineController+Cutover.swift  # requestSync = fetch+send
sed -n '196,199p' Foqos/CloudKit/ProfileSyncManager.swift                # syncNow -> requestSync
sed -n '213,220p' Foqos/CloudKit/ProfileSyncManager.swift                # enqueueProfileSave/Delete facade
sed -n '50,71p' Foqos/CloudKit/SyncEngine/MutationFunnel.swift           # enqueueSave ends at driver.add
sed -n '929,936p' Foqos/Views/BlockedProfileView.swift                   # finalizeSave enqueue + notAttached swallow
```

Expected: `automaticallySync = false`; `requestSync` = `driver?.fetchChanges(); driver?.sendChanges()`; the facade enqueue verbs guard `engineController` and forward without a send; `MutationFunnel.enqueueSave` ends at `driver.add(...)`; `finalizeSave` catches `SyncEngineControllingError.notAttached`. If any anchor drifted, update the Task references before editing.

### Task 0.1: Temporary enqueue/send instrumentation (optional)

**Files:**
- Modify temporarily: `Foqos/CloudKit/SyncEngine/MutationFunnel.swift`, `Foqos/CloudKit/SyncEngine/CKSyncEngineDriver.swift`

- [ ] **Step 1: Log the enqueue**

In `MutationFunnel.enqueueSave(profileId:)`, after `driver.add(pendingRecordZoneChanges: [.saveRecord(recordID)])` (`MutationFunnel.swift:70`):

```swift
    Log.debug("[#294 PROBE] enqueued .saveRecord for profile \(profileId) (no send here)", category: .sync)
```

- [ ] **Step 2: Log the send with its caller**

In `CKSyncEngineDriver.sendChanges()` (`CKSyncEngineDriver.swift:64`), at the top:

```swift
    Log.debug(
      "[#294 PROBE] sendChanges called\n"
        + Thread.callStackSymbols.dropFirst().prefix(6).joined(separator: "\n"),
      category: .sync)
```

- [ ] **Step 3: Compile**

```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -destination 'platform=iOS Simulator,id=B9E4A679-BDF3-4541-A59F-DA4BE21F80ED' \
  -parallel-testing-enabled NO -only-testing:FoqosTests/SyncEngineFacadeTests | xcpretty
```

Expected: pass. Commit as `refs #294: add temporary enqueue/send probe`.

- [ ] **Step 4: Device baseline**

Build/install/launch on the reference device (`xcrun devicectl list devices` for the id). With sync enabled and engine attached, create a profile and **stay foregrounded** (do not background, relaunch, or start it). Expected: the `[#294 PROBE] enqueued .saveRecord` line appears with **no** following `[#294 PROBE] sendChanges called` — confirming the record is queued but never sent. This is the bug, reproduced deterministically.

---

## Phase 1: Send-on-Enqueue + Deferred-Drain Fix (TDD)

### Task 1.1: `isSyncReady` gate + send-on-enqueue for the profile-save facade

**Files:**
- Modify: `Foqos/CloudKit/ProfileSyncManager.swift`
- Test: `FoqosTests/SyncEngineFacadeTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `SyncEngineFacadeTests` (the harness's `setUp` leaves `manager.isSyncReady == false`, so set it explicitly):

```swift
func testGivenReadyController_WhenEnqueueProfileSave_ThenRequestSyncIsScheduled() throws {
  manager.isSyncReady = true
  let id = UUID()
  try manager.enqueueProfileSave(id)

  XCTAssertEqual(mock.enqueuedProfileSaves, [id], "the save is forwarded to the engine")
  XCTAssertEqual(
    mock.requestSyncCount, 1,
    "a ready engine flushes a user-initiated save promptly, not on the next foreground")
}
```

- [ ] **Step 2: Run it red**

```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -destination 'platform=iOS Simulator,id=B9E4A679-BDF3-4541-A59F-DA4BE21F80ED' \
  -parallel-testing-enabled NO \
  -only-testing:FoqosTests/SyncEngineFacadeTests/testGivenReadyController_WhenEnqueueProfileSave_ThenRequestSyncIsScheduled | xcpretty
```

Expected: compile failure — `isSyncReady` does not exist yet — then FAIL once it compiles (`requestSyncCount` is 0).

- [ ] **Step 3: Add the `isSyncReady` gate and send-on-enqueue**

In `ProfileSyncManager.swift`, add the flag near `engineController`:

```swift
  /// True once the engine is attached AND startup (incl. the AB-4 T1 strip) has completed.
  /// Gates send-on-enqueue so a send can never flush restored state before T1 (#286 poison).
  var isSyncReady = false
```

Replace `enqueueProfileSave` (`:213-216`):

```swift
  func enqueueProfileSave(_ id: UUID) throws {
    guard let engineController else { throw SyncEngineControllingError.notAttached }
    try engineController.enqueueProfileSave(id)
    if isSyncReady { engineController.requestSync() }
  }
```

In `attachEngine(...)`, inside the `if isEnabled { … }` block, after `await controller.startupTask?.value` (`:176`), add:

```swift
      isSyncReady = true
```

In the `isEnabled` off-branch that stops the engine (the `$isEnabled` sink / `stop()` path, `:56-67`), set `isSyncReady = false` so a detach can never leave sends enabled against a torn-down engine. (Task 1.3 replaces the `isSyncReady = true` line with `markSyncReadyAndFlush()`.)

- [ ] **Step 4: Run it green**

Rerun the Step 2 command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git commit -am "fix(#294): gate a prompt send on isSyncReady and flush profile save after enqueue"
```

### Task 1.2: Extend send-on-enqueue to delete/location/emergency and fix the existing forward test

**Files:**
- Modify: `Foqos/CloudKit/ProfileSyncManager.swift`
- Test: `FoqosTests/SyncEngineFacadeTests.swift`

- [ ] **Step 1: Update the existing forward test to the new contract**

`testGivenController_WhenFacadeVerbsCalled_ThenTheyForward` currently asserts `mock.requestSyncCount == 1` (from `syncNow` alone). With the gate, the enqueue verbs only flush when `isSyncReady`, so set it at the top of the test (after the existing forwards, before the assertions is fine too — set it before the enqueue calls):

```swift
    manager.isSyncReady = true
```

and change the count assertion (`SyncEngineFacadeTests.swift:62`):

```swift
    XCTAssertEqual(
      mock.requestSyncCount, 6,
      "syncNow (1) + five enqueue verbs each flush once when ready (5)")
```

- [ ] **Step 2: Run it red**

```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -destination 'platform=iOS Simulator,id=B9E4A679-BDF3-4541-A59F-DA4BE21F80ED' \
  -parallel-testing-enabled NO \
  -only-testing:FoqosTests/SyncEngineFacadeTests/testGivenController_WhenFacadeVerbsCalled_ThenTheyForward | xcpretty
```

Expected: FAIL — count is 2 (only `enqueueProfileSave` from Task 1.1 sends so far), not 6.

- [ ] **Step 3: Add `requestSync()` to the remaining enqueue verbs**

In `ProfileSyncManager.swift`, apply the same gated pattern to `enqueueProfileDelete` (`:217-220`), `enqueueLocationSave` (`:221-224`), `enqueueLocationDelete` (`:225-228`), and `enqueueEmergencySettingsSave` (`:229-…`): after the `try engineController.enqueue…(…)` line, add `if isSyncReady { engineController.requestSync() }`. Example for delete:

```swift
  func enqueueProfileDelete(_ id: UUID) throws {
    guard let engineController else { throw SyncEngineControllingError.notAttached }
    try engineController.enqueueProfileDelete(id)
    if isSyncReady { engineController.requestSync() }
  }
```

- [ ] **Step 4: Run it green**

Rerun Step 2. Expected: PASS. Then run the whole file:

```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -destination 'platform=iOS Simulator,id=B9E4A679-BDF3-4541-A59F-DA4BE21F80ED' \
  -parallel-testing-enabled NO -only-testing:FoqosTests/SyncEngineFacadeTests | xcpretty
```

Expected: all pass. (Note: `BlockedProfileListView` reorder enqueues N profiles in a loop, producing N `requestSync()` calls; CKSyncEngine coalesces concurrent `sendChanges()`, so this is chatty but functionally correct. A batched flush is a possible future optimization, out of scope.)

- [ ] **Step 5: Commit**

```bash
git commit -am "fix(#294): flush delete/location/emergency mutations after enqueue"
```

### Task 1.3: Deferred re-enqueue for the save verbs so a `.notAttached` mutation is not lost

Covers approval points 1 (all save-type verbs: profile save, location save, emergency save) and 3 (the swallow is the permanent-loss half). Deletes are handled in Task 1.4.

**Files:**
- Modify: `Foqos/CloudKit/ProfileSyncManager.swift`
- Test: `FoqosTests/SyncEngineFacadeTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
func testGivenNotAttached_WhenEnqueueProfileSave_ThenIdIsDeferredAndReEnqueuedOnReady() throws {
  let id = UUID()
  manager.engineController = nil                      // pre-attach window

  XCTAssertThrowsError(try manager.enqueueProfileSave(id)) { error in
    XCTAssertEqual(error as? SyncEngineControllingError, .notAttached)
  }

  // Engine attaches and startup (T1) completes; deferred saves are replayed and flushed once.
  let attached = MockSyncEngineControlling()
  manager.engineController = attached
  manager.markSyncReadyAndFlush()

  XCTAssertEqual(attached.enqueuedProfileSaves, [id], "the dropped save is retried on attach")
  XCTAssertEqual(attached.requestSyncCount, 1, "exactly one flush covers all drained mutations")
  XCTAssertTrue(manager.hasNoDeferredMutations, "the deferred sets are cleared after draining")
}
```

- [ ] **Step 2: Run it red**

```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -destination 'platform=iOS Simulator,id=B9E4A679-BDF3-4541-A59F-DA4BE21F80ED' \
  -parallel-testing-enabled NO \
  -only-testing:FoqosTests/SyncEngineFacadeTests/testGivenNotAttached_WhenEnqueueProfileSave_ThenIdIsDeferredAndReEnqueuedOnReady | xcpretty
```

Expected: compile failure — `markSyncReadyAndFlush` / `hasNoDeferredMutations` do not exist, and nothing is recorded on `.notAttached`.

- [ ] **Step 3: Add the deferred stores and drain**

In `ProfileSyncManager.swift`, add near `engineController` (the delete set is populated in Task 1.4):

```swift
  // Mutations that could not be enqueued because the engine was not attached yet (#294).
  // Drained on attach so a mutation in the pre-attach window is retried instead of lost.
  private var deferredProfileSaveIds: Set<UUID> = []
  private var deferredLocationSaveIds: Set<UUID> = []
  private var deferredDeleteRecordNames: Set<String> = []   // Task 1.4
  private var deferredEmergencySave = false

  /// Test seam: true when nothing is pending re-enqueue.
  var hasNoDeferredMutations: Bool {
    deferredProfileSaveIds.isEmpty && deferredLocationSaveIds.isEmpty
      && deferredDeleteRecordNames.isEmpty && !deferredEmergencySave
  }
```

Update the three **save** facade verbs to record on `.notAttached` (shown for profile save; apply the same shape to `enqueueLocationSave` → `deferredLocationSaveIds`, and `enqueueEmergencySettingsSave` → `deferredEmergencySave = true`):

```swift
  func enqueueProfileSave(_ id: UUID) throws {
    guard let engineController else {
      deferredProfileSaveIds.insert(id)
      throw SyncEngineControllingError.notAttached
    }
    do {
      try engineController.enqueueProfileSave(id)
    } catch SyncEngineControllingError.notAttached {
      deferredProfileSaveIds.insert(id)          // I10: controller exists, funnel not built yet
      throw SyncEngineControllingError.notAttached
    }
    if isSyncReady { engineController.requestSync() }
  }
```

Add the drain (delete replay is added in Task 1.4) and the ready hook, and drop `requestSync()` out of the drain so exactly one flush covers everything:

```swift
  /// Replay every mutation deferred while the engine was unattached (#294). Uses the
  /// controller-level enqueue verbs (which do not themselves send), so the single
  /// `requestSync()` in `markSyncReadyAndFlush()` flushes them all at once. Ids whose model
  /// no longer exists throw `entityNotFound` in the funnel and are dropped.
  private func drainDeferredMutations() {
    guard let engineController else { return }
    for id in deferredProfileSaveIds { try? engineController.enqueueProfileSave(id) }
    for id in deferredLocationSaveIds { try? engineController.enqueueLocationSave(id) }
    for name in deferredDeleteRecordNames { engineController.enqueueDeferredDelete(recordName: name) }  // Task 1.4
    if deferredEmergencySave { try? engineController.enqueueEmergencySettingsSave() }
    deferredProfileSaveIds.removeAll()
    deferredLocationSaveIds.removeAll()
    deferredDeleteRecordNames.removeAll()
    deferredEmergencySave = false
  }

  /// Called once the engine is attached AND startup (incl. the AB-4 T1 strip) has completed.
  /// Enables prompt sends and flushes anything enqueued while not ready — always post-T1, so
  /// it can never transmit restored poison (AB-4, #286).
  func markSyncReadyAndFlush() {
    isSyncReady = true
    drainDeferredMutations()
    engineController?.requestSync()
  }
```

Replace the `isSyncReady = true` line added in Task 1.1 (`attachEngine`, after `await controller.startupTask?.value`) with:

```swift
      markSyncReadyAndFlush()
```

- [ ] **Step 4: Run it green**

Rerun Step 2. Expected: PASS. (`enqueueDeferredDelete` is not on the protocol yet — Task 1.4 adds it; if the compiler blocks here, do Task 1.4 Step 3 first, then return.)

- [ ] **Step 5: Commit**

```bash
git commit -am "fix(#294): defer and retry save-type mutations dropped before attach; flush once on ready"
```

### Task 1.4: Deferred tombstone-delete so a `.notAttached` delete still propagates

The delete call sites fall back to a **local** delete on `.notAttached` (`BlockedProfileView.swift:826-838`, `BlockedProfileListView.swift:188`), leaving the model gone but the remote delete un-enqueued — a re-run of `enqueueProfileDelete` would hit `entityNotFound`. Add a tombstone-only delete replayed on attach.

**Files:**
- Modify: `Foqos/CloudKit/SyncEngine/MutationFunnel.swift`, `Foqos/CloudKit/SyncEngine/SyncEngineControlling.swift`, `Foqos/CloudKit/SyncEngine/SyncEngineController+Cutover.swift`, `Foqos/CloudKit/ProfileSyncManager.swift`
- Test: `FoqosTests/SyncEngineFacadeTests.swift`, `FoqosTests/Mocks/MockSyncEngineControlling.swift`

- [ ] **Step 1: Write the failing test**

```swift
func testGivenNotAttached_WhenEnqueueProfileDelete_ThenTombstoneDeleteIsReplayedOnReady() throws {
  let id = UUID()
  manager.engineController = nil

  XCTAssertThrowsError(try manager.enqueueProfileDelete(id)) { error in
    XCTAssertEqual(error as? SyncEngineControllingError, .notAttached)
  }

  let attached = MockSyncEngineControlling()
  manager.engineController = attached
  manager.markSyncReadyAndFlush()

  XCTAssertEqual(
    attached.deferredDeletes, [id.uuidString],
    "a delete dropped before attach is replayed as a tombstone delete")
  XCTAssertEqual(attached.requestSyncCount, 1)
  XCTAssertTrue(manager.hasNoDeferredMutations)
}
```

- [ ] **Step 2: Run it red**

Focused run of the new test. Expected: compile failure — `enqueueDeferredDelete` / `deferredDeletes` do not exist.

- [ ] **Step 3: Add the tombstone-delete seam**

In `MutationFunnel.swift`, add (mirrors the tail of `enqueueDelete(profileId:)` at `:108-109,136-137`, without a model read — I2-whitelisted funnel site):

```swift
  /// Enqueue a delete for a record whose model is already gone locally (a delete that fell
  /// back to a local delete while unattached, #294). Writes the tombstone and the
  /// `.deleteRecord`; no persisted delete because the row no longer exists.
  func enqueueTombstoneDelete(recordName: String) {
    let changeTag = Self.changeTag(fromSystemFields: store.systemFields(for: recordName))
    store.setTombstone(recordName: recordName, changeTag: changeTag)
    let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
    driver.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
  }
```

In `SyncEngineControlling.swift`, add to the protocol:

```swift
  func enqueueDeferredDelete(recordName: String)
```

In `SyncEngineController+Cutover.swift`, implement it (I10 guard — no-op if the funnel isn't built):

```swift
  func enqueueDeferredDelete(recordName: String) {
    funnel?.enqueueTombstoneDelete(recordName: recordName)
  }
```

In `MockSyncEngineControlling.swift`, add:

```swift
  private(set) var deferredDeletes: [String] = []
  func enqueueDeferredDelete(recordName: String) { deferredDeletes.append(recordName) }
```

In `ProfileSyncManager.swift`, record the recordName on `.notAttached` in **both** delete facade verbs (`enqueueProfileDelete`, `enqueueLocationDelete`), shown for profile:

```swift
  func enqueueProfileDelete(_ id: UUID) throws {
    guard let engineController else {
      deferredDeleteRecordNames.insert(id.uuidString)
      throw SyncEngineControllingError.notAttached
    }
    do {
      try engineController.enqueueProfileDelete(id)
    } catch SyncEngineControllingError.notAttached {
      deferredDeleteRecordNames.insert(id.uuidString)
      throw SyncEngineControllingError.notAttached
    }
    if isSyncReady { engineController.requestSync() }
  }
```

- [ ] **Step 4: Run it green**

Rerun the Step 1 test and the full `SyncEngineFacadeTests`. Expected: PASS. (Locations share the profile zone, so `enqueueTombstoneDelete` handles both — `MutationFunnel.zoneID` is the single zone used by `enqueueDelete(profileId:)` `:69` and `enqueueDelete(locationId:)` `:171`.)

- [ ] **Step 5: Commit**

```bash
git commit -am "fix(#294): replay a dropped delete as a tombstone delete on attach"
```

### Task 1.5: AB-4 conformance test (no send before the T1 strip)

**Files:**
- Test: `FoqosTests/SyncEngineFacadeTests.swift`

- [ ] **Step 1: Write the test**

```swift
func testGivenNotReady_WhenEnqueueProfileSave_ThenNoSendUntilReadyFlush() throws {
  manager.isSyncReady = false            // funnel present (mock) but startup/T1 not done
  let id = UUID()

  try manager.enqueueProfileSave(id)
  XCTAssertEqual(mock.enqueuedProfileSaves, [id], "the change is enqueued")
  XCTAssertEqual(
    mock.requestSyncCount, 0,
    "no send may fire before the engine is ready — restored poison must be T1-stripped first (AB-4)")

  manager.markSyncReadyAndFlush()
  XCTAssertEqual(mock.requestSyncCount, 1, "the post-startup flush sends exactly once, post-T1")
}
```

- [ ] **Step 2: Run it green**

Focused run. Expected: PASS with the gate + `markSyncReadyAndFlush` from Tasks 1.1/1.3 already in place (no new production code — this locks the AB-4 invariant).

- [ ] **Step 3: Commit**

```bash
git commit -am "test(#294): assert send-on-enqueue never fires before the AB-4 T1 strip"
```

### Task 1.6: Full verification

**Files:** none.

- [ ] **Step 1: Full suite + guards + format**

```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -destination 'platform=iOS Simulator,id=B9E4A679-BDF3-4541-A59F-DA4BE21F80ED' \
  -parallel-testing-enabled NO | xcpretty
swift-format lint --recursive .
scripts/check-sync-guards.sh
```

Expected: full `FoqosTests` suite passes, 0 failures; lint clean; sync guards pass. The one new enqueue site — `MutationFunnel.enqueueTombstoneDelete` — is inside the funnel (I2-whitelisted); if `scripts/check-sync-guards.sh` maintains an allow-list of `driver.add(...)` sites, add this method to it in the same commit.

- [ ] **Step 2: Revert the Phase 0 probe (if added)**

```bash
git revert --no-edit "$(git log --format=%H --grep='refs #294: add temporary enqueue/send probe' -n 1)"
rg -n "\[#294 PROBE\]" . ; echo "rg-exit=$?"
```

Expected: `rg-exit=1` (no matches).

### Task 1.7: Two-device physical acceptance (authoritative)

**Files:** none.

- [ ] **Step 1: Build the production (non-probe) build on both devices signed into the same iCloud account.**

- [ ] **Step 2: Prompt-sync acceptance**

On device A: enable sync, create a profile with a manual stop condition, and **stay foregrounded** — do **not** start it, do **not** relaunch. Within a few seconds, the profile must appear on device B. (Before the fix it would not appear until A was backgrounded/foregrounded, received a push, or the user tapped "Sync Now".)

- [ ] **Step 3: Edit + delete propagation**

On A: edit the profile (rename) → B reflects it promptly. Delete it on A → it disappears on B promptly.

- [ ] **Step 4: Regression — start still works and session sync intact**

On A: start the profile → restrictions activate and the session syncs (`SessionSyncService … seq=1`) exactly as before; no duplicate/most-recent profile churn.

- [ ] **Step 5: Confirm #286 is unblocked**

With create-time sync working, the `#286` two-device sync checklist (`docs/sync-engine-two-device-checklist.md`) can now run. Note this on `#286`.

---

## Risks / notes for the reviewer

- **Chattiness on bulk reorder.** `BlockedProfileListView` reorder enqueues each remaining profile in a loop; each now calls `requestSync()` (when ready). CKSyncEngine coalesces concurrent `sendChanges()`, so this is functionally correct but issues multiple send cycles. If it proves noisy, a single post-loop flush is a clean follow-up (out of scope).
- **Coverage (approval point 1).** Send-on-enqueue covers all five facade verbs; deferred-drain covers all five (saves + emergency re-enqueue by id/flag; deletes replayed as tombstone deletes). No verb is left with the enqueue-only gap or the silent-drop.
- **`requestSync()` also fetches.** It runs `fetchChanges()` then `sendChanges()`; fetching on enqueue is harmless (it also pulls remote changes) and reuses the existing verb rather than adding a send-only protocol method.
- **Not a #286 change; AB-4-safe (approval point 2).** This fix does not alter `beginReset`/T1/AB-4 behavior. The only sends it adds are gated on `isSyncReady` (set post-T1) and triggered only by fresh local mutations, so it cannot resend restored poison. See "AB-4 Conformance".

---

## Self-Review

- **Spec coverage (incl. all three approval points):** send-on-enqueue added to **all five** facade verbs, gated on `isSyncReady` (Tasks 1.1–1.2); the `.notAttached` silent-drop closed for all five via deferred-drain-on-attach — saves/emergency re-enqueued, deletes replayed as tombstone deletes (Tasks 1.3–1.4); AB-4 conformance enforced by the `isSyncReady` gate and asserted (Task 1.5); the existing forward test updated to the new `requestSyncCount` contract; two-device acceptance proves prompt create/edit/delete propagation without starting or relaunching (Task 1.7). The validation/trigger UI is untouched (established as a red herring).
- **Placeholder scan:** no `TBD`/`TODO`/"handle edge cases"; every code step shows complete code and exact assertions.
- **Type/citation consistency:** `enqueueProfileSave/Delete`, `enqueueLocationSave/Delete`, `enqueueEmergencySettingsSave`, `enqueueDeferredDelete(recordName:)`, `MutationFunnel.enqueueTombstoneDelete(recordName:)`, `requestSync()`, `isSyncReady`, `deferredProfileSaveIds`/`deferredLocationSaveIds`/`deferredDeleteRecordNames`/`deferredEmergencySave`, `drainDeferredMutations()`, `markSyncReadyAndFlush()`, `hasNoDeferredMutations`, `MockSyncEngineControlling.requestSyncCount`/`enqueuedProfileSaves`/`deferredDeletes`/`errorToThrow`, and `attachEngine`/`startupTask` are used consistently and match the current code.
- **Device rigor:** the two-device acceptance is authoritative; unit tests assert the send is scheduled and the drop is retried, but the propagation claim is proven on hardware.
- **Process integrity:** probes reverted with normal commits (no amend/force-push); PR titled "plans the fix for #294"; scoped to `fix/294-tap-to-stop-validation`, not folded into `#286`.
