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

## Global Constraints

- **Chosen fix = send-on-enqueue + swallow deferred-retry** (maintainer decision). Do not implement a full startup backfill; do not touch the trigger/validation UI (it is not the defect).
- **Two-device physical acceptance is authoritative.** The bug is a device-timing/propagation defect; the acceptance test is "create on device A, foregrounded, without starting it and without relaunching → appears on device B within seconds."
- **TDD.** Write the failing test first; names follow `testGivenX_WhenY_ThenZ`.
- **The send must stay outside `handleEvent`.** `requestSync()`/`sendChanges()` may only be scheduled outside the CKSyncEngine delegate (`SyncEngineController+Cutover.swift:6-8`). All enqueue facade calls originate from UI actions (outside `handleEvent`), so calling `requestSync()` there is permitted. Do **not** add sends inside `nextRecordZoneChangeBatch`/`handleEvent`.
- **Preserve the delete fallback contract.** Delete call sites must still receive `.notAttached` (they fall back to a local delete — `BlockedProfileView.swift:826-838`). Send-on-enqueue must run only *after* a successful enqueue, so a throwing enqueue never reaches it.
- **Single build/test stream.** Simulator UUID `B9E4A679-BDF3-4541-A59F-DA4BE21F80ED` (iPhone 17, booted). Never a device *name* in `-destination`. Use `-parallel-testing-enabled NO` if launch hangs.
- **Branch.** Implement on `fix/294-tap-to-stop-validation` off `origin/main`. Do **not** fold into `#286`.
- **No amend/force-push.** Revert temporary probes with normal commits.
- **PR wording.** Plan PR titled **"plans the fix for #294"** (not a closing keyword).
- **#294 blocks #286** (its two-device sync checklist can't run until create-time sync works) and is top of the queue.

---

## File Structure

- Modify: `Foqos/CloudKit/ProfileSyncManager.swift`
  - Add `requestSync()` after a successful enqueue in each enqueue facade verb (`enqueueProfileSave/Delete`, `enqueueLocationSave/Delete`, `enqueueEmergencySettingsSave`).
  - Add `deferredProfileSaveIds: Set<UUID>`; record on `.notAttached` in `enqueueProfileSave`; drain in `attachEngine` after `startupTask`.
- Modify (tests): `FoqosTests/SyncEngineFacadeTests.swift`
  - Update `testGivenController_WhenFacadeVerbsCalled_ThenTheyForward` for the new `requestSyncCount`; add send-on-enqueue and deferred-retry tests.
- Optional temporary probe (reverted before merge): `Foqos/CloudKit/SyncEngine/MutationFunnel.swift`, `Foqos/CloudKit/SyncEngine/CKSyncEngineDriver.swift` — one log line at enqueue and one at `sendChanges` (with caller) for device baseline/acceptance.

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

## Phase 1: Send-on-Enqueue + Deferred-Retry Fix (TDD)

### Task 1.1: Send-on-enqueue for the profile-save facade

**Files:**
- Modify: `Foqos/CloudKit/ProfileSyncManager.swift`
- Test: `FoqosTests/SyncEngineFacadeTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `SyncEngineFacadeTests`:

```swift
func testGivenAttachedController_WhenEnqueueProfileSave_ThenRequestSyncIsScheduled() throws {
  let id = UUID()
  try manager.enqueueProfileSave(id)

  XCTAssertEqual(mock.enqueuedProfileSaves, [id], "the save is forwarded to the engine")
  XCTAssertEqual(
    mock.requestSyncCount, 1,
    "a user-initiated profile save must trigger a prompt send, not wait for the next foreground")
}
```

- [ ] **Step 2: Run it red**

```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -destination 'platform=iOS Simulator,id=B9E4A679-BDF3-4541-A59F-DA4BE21F80ED' \
  -parallel-testing-enabled NO \
  -only-testing:FoqosTests/SyncEngineFacadeTests/testGivenAttachedController_WhenEnqueueProfileSave_ThenRequestSyncIsScheduled | xcpretty
```

Expected: FAIL — `requestSyncCount` is 0 (enqueue does not currently send).

- [ ] **Step 3: Implement send-on-enqueue in the facade**

In `ProfileSyncManager.swift`, replace `enqueueProfileSave` (`:213-216`):

```swift
  func enqueueProfileSave(_ id: UUID) throws {
    guard let engineController else { throw SyncEngineControllingError.notAttached }
    try engineController.enqueueProfileSave(id)
    engineController.requestSync()
  }
```

(`requestSync()` runs only after a successful enqueue, so a throwing enqueue — including `.notAttached` — never reaches it.)

- [ ] **Step 4: Run it green**

Rerun the Step 2 command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git commit -am "fix(#294): flush profile save to CloudKit immediately after enqueue"
```

### Task 1.2: Extend send-on-enqueue to delete/location/emergency and fix the existing forward test

**Files:**
- Modify: `Foqos/CloudKit/ProfileSyncManager.swift`
- Test: `FoqosTests/SyncEngineFacadeTests.swift`

- [ ] **Step 1: Update the existing forward test to the new contract**

`testGivenController_WhenFacadeVerbsCalled_ThenTheyForward` currently asserts `mock.requestSyncCount == 1` (from `syncNow` alone). With send-on-enqueue on all five enqueue verbs, the five enqueue calls each add one. Change the assertion (`SyncEngineFacadeTests.swift:62`):

```swift
    XCTAssertEqual(
      mock.requestSyncCount, 6,
      "syncNow (1) + five enqueue verbs each flush once (5)")
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

In `ProfileSyncManager.swift`, apply the same pattern to `enqueueProfileDelete` (`:217-220`), `enqueueLocationSave` (`:221-224`), `enqueueLocationDelete` (`:225-228`), and `enqueueEmergencySettingsSave` (`:229-…`): after the `try engineController.enqueue…(…)` line, add `engineController.requestSync()`. Example for delete:

```swift
  func enqueueProfileDelete(_ id: UUID) throws {
    guard let engineController else { throw SyncEngineControllingError.notAttached }
    try engineController.enqueueProfileDelete(id)
    engineController.requestSync()
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

### Task 1.3: Deferred re-enqueue so a `.notAttached` create is not lost

**Files:**
- Modify: `Foqos/CloudKit/ProfileSyncManager.swift`
- Test: `FoqosTests/SyncEngineFacadeTests.swift`

- [ ] **Step 1: Write the failing test**

The mock's `errorToThrow` makes enqueue throw. Simulate a create hitting `.notAttached`, then attach and drain:

```swift
func testGivenNotAttached_WhenEnqueueProfileSave_ThenIdIsDeferredAndReEnqueuedOnAttach() throws {
  let id = UUID()
  manager.engineController = nil                      // pre-attach window

  XCTAssertThrowsError(try manager.enqueueProfileSave(id)) { error in
    XCTAssertEqual(error as? SyncEngineControllingError, .notAttached)
  }

  // Engine attaches; the deferred save must be re-enqueued and flushed.
  let attached = MockSyncEngineControlling()
  manager.engineController = attached
  manager.drainDeferredProfileSaves()

  XCTAssertEqual(attached.enqueuedProfileSaves, [id], "the dropped save is retried on attach")
  XCTAssertEqual(attached.requestSyncCount, 1, "the retried save is flushed")
  XCTAssertTrue(
    manager.hasNoDeferredProfileSaves, "the deferred set is cleared after draining")
}
```

- [ ] **Step 2: Run it red**

```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -destination 'platform=iOS Simulator,id=B9E4A679-BDF3-4541-A59F-DA4BE21F80ED' \
  -parallel-testing-enabled NO \
  -only-testing:FoqosTests/SyncEngineFacadeTests/testGivenNotAttached_WhenEnqueueProfileSave_ThenIdIsDeferredAndReEnqueuedOnAttach | xcpretty
```

Expected: compile failure — `drainDeferredProfileSaves` / `hasNoDeferredProfileSaves` do not exist, and the deferred set isn't recorded yet.

- [ ] **Step 3: Implement the deferred-retry set**

In `ProfileSyncManager.swift`, add a stored property near `engineController`:

```swift
  /// Profile-save ids that could not be enqueued because the engine was not attached yet
  /// (#294). Drained on `attachEngine` so a create in the pre-attach window is retried
  /// instead of silently lost.
  private var deferredProfileSaveIds: Set<UUID> = []

  /// Test seam: true when nothing is pending re-enqueue.
  var hasNoDeferredProfileSaves: Bool { deferredProfileSaveIds.isEmpty }
```

Update `enqueueProfileSave` (from Task 1.1) to record on `.notAttached`:

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
    engineController.requestSync()
  }
```

Add the drain method:

```swift
  /// Re-enqueue and flush any profile saves that were deferred while the engine was
  /// unattached (#294). Safe to call repeatedly; ids whose profile no longer exists throw
  /// `entityNotFound` inside the funnel and are dropped.
  func drainDeferredProfileSaves() {
    guard let engineController, !deferredProfileSaveIds.isEmpty else { return }
    let ids = deferredProfileSaveIds
    deferredProfileSaveIds.removeAll()
    for id in ids {
      do { try engineController.enqueueProfileSave(id) } catch {
        Log.warning(
          "Deferred profile re-enqueue failed for \(id): \(error.localizedDescription)",
          category: .sync)
      }
    }
    engineController.requestSync()
  }
```

- [ ] **Step 4: Drain on attach**

In `attachEngine(...)`, inside the `if isEnabled { … }` block after `await controller.startupTask?.value` (`ProfileSyncManager.swift:170-177`), add:

```swift
      drainDeferredProfileSaves()
```

- [ ] **Step 5: Run it green**

Rerun Step 2. Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git commit -am "fix(#294): defer and retry profile saves dropped in the pre-attach window"
```

### Task 1.4: Full verification

**Files:** none.

- [ ] **Step 1: Full suite + guards + format**

```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -destination 'platform=iOS Simulator,id=B9E4A679-BDF3-4541-A59F-DA4BE21F80ED' \
  -parallel-testing-enabled NO | xcpretty
swift-format lint --recursive .
scripts/check-sync-guards.sh
```

Expected: full `FoqosTests` suite passes, 0 failures; lint clean; sync guards pass (I2/I5 unaffected — `requestSync` is not a new enqueue site).

- [ ] **Step 2: Revert the Phase 0 probe (if added)**

```bash
git revert --no-edit "$(git log --format=%H --grep='refs #294: add temporary enqueue/send probe' -n 1)"
rg -n "\[#294 PROBE\]" . ; echo "rg-exit=$?"
```

Expected: `rg-exit=1` (no matches).

### Task 1.5: Two-device physical acceptance (authoritative)

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

- **Chattiness on bulk reorder.** `BlockedProfileListView` reorder enqueues each remaining profile in a loop; each now calls `requestSync()`. CKSyncEngine coalesces concurrent `sendChanges()`, so this is functionally correct but issues multiple send cycles. If it proves noisy in practice, a single post-loop flush is a clean follow-up (out of scope here).
- **Deferred-retry scope.** Task 1.3 covers profile **saves** (the reported symptom). Location/emergency mutations get send-on-enqueue (promptness) but not deferred-retry; they are far less likely to hit the pre-attach window and are not the reported bug. Extending the same pattern to them is a trivial follow-up if desired.
- **`requestSync()` also fetches.** It runs `fetchChanges()` then `sendChanges()`; fetching on enqueue is harmless (it just also pulls remote changes) and keeps the fix to a single existing verb rather than adding a send-only method to the protocol.
- **Not a #286 change.** This fix is independent of reset poisoning; it does not alter `beginReset`/T1/AB-4 behavior.

---

## Self-Review

- **Spec coverage:** send-on-enqueue added to every enqueue facade verb (Tasks 1.1–1.2); the `.notAttached` silent-drop closed with a deferred-retry set drained on attach (Task 1.3); the existing forward test updated to the new `requestSyncCount` contract; two-device acceptance proves prompt propagation without starting or relaunching (Task 1.5). The validation/trigger UI is untouched (established as a red herring).
- **Placeholder scan:** no `TBD`/`TODO`/"handle edge cases"; every code step shows complete code and exact assertions.
- **Type/citation consistency:** `enqueueProfileSave/Delete`, `enqueueLocationSave/Delete`, `enqueueEmergencySettingsSave`, `requestSync()`, `deferredProfileSaveIds`, `drainDeferredProfileSaves()`, `hasNoDeferredProfileSaves`, `MockSyncEngineControlling.requestSyncCount`/`enqueuedProfileSaves`/`errorToThrow`, and `attachEngine`/`startupTask` are used consistently and match the current code.
- **Device rigor:** the two-device acceptance is authoritative; unit tests assert the send is scheduled and the drop is retried, but the propagation claim is proven on hardware.
- **Process integrity:** probes reverted with normal commits (no amend/force-push); PR titled "plans the fix for #294"; scoped to `fix/294-tap-to-stop-validation`, not folded into `#286`.
