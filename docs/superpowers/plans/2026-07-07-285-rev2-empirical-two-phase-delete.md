# #285 Rev 2 — Empirical Probe + Two-Phase Delete Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Recover from the rev 1 falsification by proving the actual SwiftUI re-render mechanism on device, then either implement a tested two-phase profile deletion path or stop for a maintainer decision with evidence.

**Architecture:** Keep the rev 1 central predicate work on `fix/285-safemodelview-post-save-delete`; it is correct defense-in-depth but insufficient on device. Phase 0 adds temporary device probes to prove whether an already-realized `BlockedProfileCard.body` is re-evaluated directly after model deletion without re-entering `SafeModelView`, and whether deferring the delete `context.save()` by one main-actor turn eliminates the crash. Phase 1 proceeds only if Phase 0 confirms the two-phase mechanism and the durability/sync tradeoff is acceptable.

**Tech Stack:** Swift 6, SwiftData, SwiftUI, XCTest, physical-device verification on iOS 27.0 beta, Family Foqos sync funnel (`MutationFunnel`), custom durable `Log`.

---

## Binding Context

- Base branch: `fix/285-safemodelview-post-save-delete`.
- Keep the existing rev 1 commits:
  - `refs #285: add isPersistentModelValid guarding the post-save delete window`
  - `refs #285: route .valid through isPersistentModelValid`
  - `refs #285: route SafeModelView render guard through isPersistentModelValid`
- Device falsification evidence:
  - Crash report: `docs/plans/FamilyFoqos-2026-07-07-203840.ips`
  - Exception: `EXC_BREAKPOINT` / `SIGTRAP`
  - Faulting getter: `BlockedProfiles.domains.getter`
  - Call path: `BlockedProfileCard.body.getter`
  - Existing source already has `profiles.valid` and `SafeModelView(profile)` in `BlockedProfileCarousel`.
- Working hypothesis: SwiftUI / `@Observable` invalidation can re-run an already-realized `BlockedProfileCard.body` directly on model mutation without re-evaluating the guarding ancestor. If true, no ancestor-only guard can be the complete fix.

## Global Constraints

- **Phase 0 is required.** Do not implement a structural fix before collecting device evidence.
- **No guessing after falsification.** If Phase 0 does not prove the two-phase mechanism, stop for a maintainer decision.
- **No per-view patch as a silent fallback.** `BlockedProfileCard` instrumentation is allowed in Phase 0. Shipping a card snapshot/per-view guard is a maintainer decision, not an implementer improvisation.
- **Preserve rev 1 predicate work.** The central predicate remains in the branch and final PR as defense-in-depth.
- **Temporary probe code must not ship.** Commit probes normally if useful, then remove them with a normal follow-up commit or `git revert`. Never amend or force-push.
- **TDD remains binding for Phase 1.** If implementing two-phase deletion, write the failing tests first.
- **Physical-device verification is authoritative.** In-memory `TestModelContainer` hit rev 1 Contingency Mode C and cannot reproduce the exact post-save device window.
- **Single build/test stream.** Use simulator UUID `B9E4A679-BDF3-4541-A59F-DA4BE21F80ED`; use `-parallel-testing-enabled NO` if test launch hangs.
- **PR wording:** use `Fixes #285` in the PR body per maintainer instruction, even though rev 1 plan avoided GitHub closing keywords.

---

## File Structure

### Phase 0 temporary probe files

- Modify temporarily: `Foqos/Utils/Extensions.swift`
  - Add a temporary `debugPersistentModelStateFor285` metadata-only property.
- Modify temporarily: `Foqos/Utils/SafeModelView.swift`
  - Log every guard evaluation and whether content is allowed or suppressed.
- Modify temporarily: `Foqos/Components/BlockedProfileCards/BlockedProfileCarousel.swift`
  - Log `validProfiles` inputs/outputs and each `ForEach` child creation.
- Modify temporarily: `Foqos/Components/BlockedProfileCards/BlockedProfileCard.swift`
  - Log at the very top of `body`, before any stored-attribute read.
- Modify temporarily: `Foqos/CloudKit/SyncEngine/MutationFunnel.swift`
  - Temporarily replace the immediate profile-delete save with a one-runloop deferred save probe.
- Modify temporarily: `Foqos/Views/BlockedProfileListView.swift`
  - Log local/sync delete path selection and reorder save timing.
- Modify temporarily: `Foqos/Views/BlockedProfileView.swift`
  - Log editor delete path selection and dismissal timing.

### Phase 1 candidate production files

Only if Phase 0 proves the deferred-save mechanism and maintainer accepts the tradeoff:

- Modify: `Foqos/Models/BlockedProfiles.swift`
  - Keep `deleteProfile` as the single model deletion seam.
  - Add a helper for committing the already-marked deletion after one main-actor turn.
- Modify: `Foqos/CloudKit/SyncEngine/MutationFunnel.swift`
  - Route profile deletes through two phases: tombstone + `deleteProfile` now, `context.save()` + `.deleteRecord` enqueue after view invalidation.
- Modify: `Foqos/Views/BlockedProfileListView.swift`
  - Ensure reorder/save does not collapse the deferred-delete window.
- Modify: `Foqos/Views/BlockedProfileView.swift`
  - Ensure editor delete uses the same delete seam and save deferral behavior.
- Test: `FoqosTests/MutationFunnelTests.swift`
  - Add deterministic tests for tombstone, deferred save, pending delete enqueue, and crash-between-delete-and-save behavior.
- Test: `FoqosTests/SafeModelViewTests.swift`
  - Keep rev 1 tests; add no card-specific behavior unless maintainer chooses the snapshot/per-view option.

---

## Phase 0: Empirical Device Probes

### Task 0.1: Add durable render-order instrumentation

**Files:**
- Modify temporarily: `Foqos/Utils/Extensions.swift`
- Modify temporarily: `Foqos/Utils/SafeModelView.swift`
- Modify temporarily: `Foqos/Components/BlockedProfileCards/BlockedProfileCarousel.swift`
- Modify temporarily: `Foqos/Components/BlockedProfileCards/BlockedProfileCard.swift`

- [ ] **Step 1: Add metadata-only debug state**

In `Foqos/Utils/Extensions.swift`, add below `isPersistentModelValid`:

```swift
  var debugPersistentModelStateFor285: String {
    guard let context = modelContext else {
      return "persistentModelID=\(persistentModelID) context=false isDeleted=\(isDeleted) registered=nil valid=false"
    }
    let registered: Self? = context.registeredModel(for: persistentModelID)
    return
      "persistentModelID=\(persistentModelID) context=true isDeleted=\(isDeleted) registered=\(registered != nil) valid=\(isPersistentModelValid)"
  }
```

This must read only SwiftData metadata. Do not read `id`, `name`, `domains`, `selectedActivity`, `sessions`, or any other stored attribute in probe logging.

- [ ] **Step 2: Log `SafeModelView` guard evaluation**

Temporarily replace `SafeModelView.body` with:

```swift
  var body: some View {
    let state = model.debugPersistentModelStateFor285
    Log.debug("[#285 PROBE] SafeModelView.body evaluate \(state)", category: .ui)
    if model.isPersistentModelValid {
      Log.debug("[#285 PROBE] SafeModelView.body allow content \(state)", category: .ui)
      content(model)
    } else {
      Log.debug("[#285 PROBE] SafeModelView.body suppress content \(state)", category: .ui)
    }
  }
```

- [ ] **Step 3: Log carousel filtering and child construction**

Temporarily replace `validProfiles` in `Foqos/Components/BlockedProfileCards/BlockedProfileCarousel.swift` with:

```swift
  private var validProfiles: [BlockedProfiles] {
    let result = profiles.valid
    Log.debug(
      "[#285 PROBE] Carousel.validProfiles input=\(profiles.count) output=\(result.count)",
      category: .ui
    )
    for profile in profiles {
      Log.debug("[#285 PROBE] Carousel.input \(profile.debugPersistentModelStateFor285)", category: .ui)
    }
    for profile in result {
      Log.debug("[#285 PROBE] Carousel.output \(profile.debugPersistentModelStateFor285)", category: .ui)
    }
    return result
  }
```

Inside the `ForEach(validProfiles) { profile in` closure, add this line before `SafeModelView(profile)`:

```swift
              let _ = Log.debug(
                "[#285 PROBE] Carousel.ForEach child \(profile.debugPersistentModelStateFor285)",
                category: .ui
              )
```

- [ ] **Step 4: Log direct card body re-evaluation before stored attributes**

At the very top of `BlockedProfileCard.body`, before `ZStack`, add:

```swift
    let _ = Log.debug(
      "[#285 PROBE] BlockedProfileCard.body begin \(profile.debugPersistentModelStateFor285)",
      category: .ui
    )
```

Do not log `profile.name`, `profile.id`, `profile.domains`, or any other stored attribute here.

- [ ] **Step 5: Verify probes compile**

Run:

```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -destination 'platform=iOS Simulator,id=B9E4A679-BDF3-4541-A59F-DA4BE21F80ED' \
  -parallel-testing-enabled NO \
  -only-testing:FoqosTests/SafeModelViewTests | xcpretty
```

Expected: `SafeModelViewTests` pass. If this fails because probe code reads a stored attribute, fix the probe before continuing. If it fails for unrelated simulator launch friction, rerun with the same UUID and `-parallel-testing-enabled NO`.

- [ ] **Step 6: Commit the temporary probe**

```bash
git add Foqos/Utils/Extensions.swift \
  Foqos/Utils/SafeModelView.swift \
  Foqos/Components/BlockedProfileCards/BlockedProfileCarousel.swift \
  Foqos/Components/BlockedProfileCards/BlockedProfileCard.swift
git commit -m "refs #285: add temporary render-order probe"
```

### Task 0.2: Probe baseline device crash with render instrumentation

**Files:** no additional changes.

- [ ] **Step 1: Build and install on the paired device**

Use the physical device UUID discovered by:

```bash
xcrun devicectl list devices
```

For Rob's iPhone from the falsification session:

```bash
xcodebuild -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -destination 'platform=iOS,id=162460F5-F9B6-515A-8BC1-0DCCC6918C03' \
  -configuration Debug build | xcpretty

xcrun devicectl device install app \
  --device 162460F5-F9B6-515A-8BC1-0DCCC6918C03 \
  /Users/rob/Library/Developer/Xcode/DerivedData/FamilyFoqos-bgpfiobqxpakjsesqogugdbsqpzi/Build/Products/Debug-iphoneos/FamilyFoqos.app

xcrun devicectl device process launch \
  --device 162460F5-F9B6-515A-8BC1-0DCCC6918C03 \
  com.cynexia.family-foqos
```

If DerivedData path changes, get it with:

```bash
xcodebuild -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -destination 'platform=iOS,id=162460F5-F9B6-515A-8BC1-0DCCC6918C03' \
  -configuration Debug -showBuildSettings | rg -n "BUILT_PRODUCTS_DIR|FULL_PRODUCT_NAME|PRODUCT_BUNDLE_IDENTIFIER"
```

- [ ] **Step 2: Reproduce the crash**

On the physical device:

1. Delete the app.
2. Install and launch the probe build.
3. Create one new profile.
4. Return to Home with the carousel visible and the card centered.
5. Delete that profile through a path that leaves the carousel hierarchy alive.
6. Collect the `.ips` crash report and export app logs if possible through Settings -> Diagnostics -> Debug Mode -> Export Logs, or Home version footer debug path when available.

- [ ] **Step 3: Analyze probe logs**

Expected confirmation pattern for the working hypothesis:

```text
[#285 PROBE] SafeModelView.body allow content persistentModelID=... valid=true
[#285 PROBE] BlockedProfileCard.body begin persistentModelID=... valid=true
... delete starts ...
[#285 PROBE] BlockedProfileCard.body begin persistentModelID=... context=true isDeleted=false registered=false valid=false
CRASH_LINE: BlockedProfiles.domains/name/selectedActivity getter
```

The key signal is a `BlockedProfileCard.body begin ... valid=false` line with no immediately preceding `SafeModelView.body suppress content` line for the same `persistentModelID`. That proves SwiftUI is re-evaluating the child view directly and the ancestor guard is not a complete protection boundary.

If logs instead show `SafeModelView.body allow content ... valid=true` immediately before the crash for the same `persistentModelID`, the central predicate is false-negative on device. STOP and investigate `registeredModel(for:)` on the physical store before touching delete timing.

If no probe logs survive the crash, add one more probe run using Xcode's live device console. Do not move to Phase 1 without evidence.

### Task 0.3: Probe one-runloop deferred profile delete save

**Files:**
- Modify temporarily: `Foqos/CloudKit/SyncEngine/MutationFunnel.swift`
- Modify temporarily: `Foqos/Views/BlockedProfileListView.swift`
- Modify temporarily: `Foqos/Views/BlockedProfileView.swift`

- [ ] **Step 1: Add delete path timing logs**

In `MutationFunnel.enqueueDelete(profileId:)`, add the following logs around the profile delete:

```swift
      Log.debug("[#285 PROBE] Funnel profile delete begin recordName=\(recordName)", category: .sync)
      try BlockedProfiles.deleteProfile(profile, in: modelContext)
      Log.debug("[#285 PROBE] Funnel profile delete marked; save pending recordName=\(recordName)", category: .sync)
```

In `BlockedProfileListView.deleteProfiles(at:)`, add:

```swift
        Log.debug("[#285 PROBE] List delete selected profileId=\(profileId)", category: .ui)
```

Immediately before `try BlockedProfiles.reorderProfiles(remainingProfiles, in: context)`, add:

```swift
      Log.debug("[#285 PROBE] List delete reorder save about to run", category: .ui)
```

In `BlockedProfileView`'s delete alert action, after `let profileId = profileToDelete.id`, add:

```swift
                  Log.debug("[#285 PROBE] Editor delete selected profileId=\(profileId)", category: .ui)
```

- [ ] **Step 2: Temporarily defer the funnel save by one main-actor turn**

In `MutationFunnel.enqueueDelete(profileId:)`, temporarily replace:

```swift
      try BlockedProfiles.deleteProfile(profile, in: modelContext)
      try modelContext.save()
```

with:

```swift
      try BlockedProfiles.deleteProfile(profile, in: modelContext)
      Log.debug("[#285 PROBE] Funnel profile delete marked; scheduling deferred save recordName=\(recordName)", category: .sync)
      let deleteZoneID = zoneID
      Task { @MainActor [modelContext, driver, recordName, deleteZoneID] in
        await Task.yield()
        do {
          Log.debug("[#285 PROBE] Funnel deferred save begin recordName=\(recordName)", category: .sync)
          try modelContext.save()
          let recordID = CKRecord.ID(recordName: recordName, zoneID: deleteZoneID)
          driver.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
          Log.debug("[#285 PROBE] Funnel deferred save + enqueue complete recordName=\(recordName)", category: .sync)
        } catch {
          Log.error(
            "[#285 PROBE] Funnel deferred save failed recordName=\(recordName): \(error.localizedDescription)",
            category: .sync
          )
        }
      }
      return
```

Then remove or comment out the original immediate enqueue after the `do/catch` block for this probe run:

```swift
    let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
    driver.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
```

This is intentionally not final production code: it changes error propagation and enqueue timing. It is only an empirical probe.

- [ ] **Step 3: Compile the deferred-save probe**

Run:

```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -destination 'platform=iOS Simulator,id=B9E4A679-BDF3-4541-A59F-DA4BE21F80ED' \
  -parallel-testing-enabled NO \
  -only-testing:FoqosTests/SafeModelViewTests | xcpretty
```

Expected: compile succeeds and `SafeModelViewTests` pass. Do not run the full suite for the temporary probe; existing funnel tests are expected to need redesign if this becomes production.

- [ ] **Step 4: Commit the temporary deferred-save probe**

```bash
git add Foqos/CloudKit/SyncEngine/MutationFunnel.swift \
  Foqos/Views/BlockedProfileListView.swift \
  Foqos/Views/BlockedProfileView.swift
git commit -m "refs #285: probe one-runloop deferred profile delete save"
```

- [ ] **Step 5: Run the same physical-device repro**

Build/install/launch on the physical device with the commands from Task 0.2.

On the physical device:

1. Delete the app.
2. Install and launch the deferred-save probe build.
3. Create one new profile.
4. Return to Home with the carousel visible and the card centered.
5. Delete that profile through the same path used for the falsification.

Expected if the two-phase approach is viable: no crash; logs show `delete marked`, the UI stops rendering the deleted card, then `deferred save + enqueue complete`.

Expected if the two-phase approach is killed: the app still crashes before the deferred save log, or crashes after deferred save with the same `BlockedProfileCard.body` path.

### Task 0.4: Phase 0 decision gate

**Files:** no changes.

- [ ] **Step 1: Write a short evidence note**

Create or update a local note in the plan thread, not a repo doc, with these exact fields:

```markdown
## #285 Rev 2 Phase 0 Evidence

- Baseline probe crash: yes/no
- Baseline faulting getter:
- Baseline key probe pattern:
- Deferred-save probe crash: yes/no
- Deferred-save probe delete path: funnel/list/editor
- Deferred-save probe logs:
- Conclusion:
```

- [ ] **Step 2: Apply the correct decision**

Proceed to Phase 1 only if all are true:

- Baseline probe proves direct `BlockedProfileCard.body` re-evaluation without ancestor guard protection.
- Deferred-save probe eliminates the crash on physical device.
- Logs show the deferred `context.save()` and `.deleteRecord` enqueue complete.
- Maintainer accepts the one-runloop crash window tradeoff documented below.

STOP for maintainer decision if any are true:

- Baseline proves `registeredModel(for:)` false-negatives on device.
- Deferred-save probe still crashes.
- Deferred-save prevents the crash but produces product-visible delay, stuck card, missing delete propagation, or unacceptable error handling.
- The only viable fix appears to be per-view snapshotting or a schema-level pending-delete state.

### Task 0.5: Remove temporary probe code before production implementation

**Files:** all Phase 0 temporary files.

- [ ] **Step 1: Remove or revert probe commits**

If the probe commits are the last commits on the branch, use normal revert commits:

```bash
git revert --no-edit HEAD
git revert --no-edit HEAD
```

If additional commits exist above them, revert each probe commit by SHA:

```bash
git revert --no-edit "$(git log --format=%H --grep='refs #285: probe one-runloop deferred profile delete save' -n 1)"
git revert --no-edit "$(git log --format=%H --grep='refs #285: add temporary render-order probe' -n 1)"
```

Never amend and never force-push.

- [ ] **Step 2: Verify final diff is back to rev 1**

Run:

```bash
git diff --name-only main...HEAD
```

Expected before Phase 1 implementation:

```text
Foqos/Utils/Extensions.swift
Foqos/Utils/SafeModelView.swift
FoqosTests/SafeModelViewTests.swift
```

---

## Phase 1: Candidate Structural Fix — Two-Phase Profile Deletion

Proceed only if Phase 0 passes the decision gate.

### Tradeoff analysis that must be accepted before implementation

Two-phase deletion changes the profile delete from:

```text
tombstone -> context.delete(profile) -> context.save() -> enqueue .deleteRecord -> return
```

to:

```text
tombstone -> context.delete(profile) -> return to main actor once -> context.save() -> enqueue .deleteRecord
```

Benefits:

- Gives SwiftUI one main-actor turn to invalidate the carousel while `isDeleted == true`.
- Avoids immediately entering the device-only post-save window where `isDeleted == false`, `modelContext` remains non-nil, and stored getters trap.
- Keeps rev 1 central predicate as defense-in-depth for all `.valid` and `SafeModelView` callers.

Risks:

- A crash or force-quit between `context.delete(profile)` and deferred `context.save()` means the profile delete was not persisted.
- In the sync-enabled path, the tombstone may be durable before the model delete save. Existing I12 recovery behavior should see "entity present" and clear/abort the tombstone, preserving the live profile rather than killing it remotely. The user-visible outcome is that the delete may be undone after a crash in the one-runloop window.
- Save errors become asynchronous unless the API is changed to `async throws`, which would touch `ProfileSyncManager`, `SyncEngineControlling`, `MutationFunnel`, and both delete call sites. That is broader but preserves error reporting.

Maintainer must choose one before implementation:

1. **Accept one-runloop async save tradeoff.** Implement minimal two-phase delete; save failures are logged and surfaced through existing diagnostics, not synchronously through the delete button.
2. **Require `async throws` delete.** Broaden the sync protocol and UI delete flows so the deferred save can still report failure to the user.
3. **Reject timing-based fix.** Use a snapshot/pending-delete design instead; write a new plan because it is no longer the two-phase delete approach.

### Task 1.1: TDD for deferred profile-delete commit in the sync funnel

**Files:**
- Modify: `Foqos/CloudKit/SyncEngine/MutationFunnel.swift`
- Test: `FoqosTests/MutationFunnelTests.swift`

- [ ] **Step 1: Write the failing deterministic scheduler test**

Add this helper inside `MutationFunnelTests`:

```swift
@MainActor
private final class ManualProfileDeleteCommitScheduler {
  private(set) var scheduledOperations: [@MainActor () -> Void] = []

  func schedule(_ operation: @escaping @MainActor () -> Void) {
    scheduledOperations.append(operation)
  }

  func runNext() {
    let operation = scheduledOperations.removeFirst()
    operation()
  }
}
```

Add this test:

```swift
func testGivenSyncedProfile_WhenEnqueueDelete_ThenDeleteIsMarkedBeforeDeferredSaveAndEnqueuedAfterCommit()
  throws
{
  let profileId = UUID()
  let recordName = profileId.uuidString
  let container = try TestModelContainer.create()
  let context = ModelContext(container)
  try insertProfile(in: context, id: profileId, name: "Homework", syncVersion: 2)

  let store = makeStore()
  let driver = MockSyncEngineDriver()
  let scheduler = ManualProfileDeleteCommitScheduler()
  let funnel = MutationFunnel(
    modelContext: context,
    store: store,
    driver: driver,
    deviceId: "device-A",
    scheduleProfileDeleteCommit: scheduler.schedule
  )

  try funnel.enqueueDelete(profileId: profileId)

  XCTAssertTrue(store.deleteTombstones.keys.contains(recordName), "tombstone is durable immediately")
  XCTAssertEqual(scheduler.scheduledOperations.count, 1, "save is deferred one turn")
  XCTAssertTrue(driver.pendingRecordZoneChanges.isEmpty, "deleteRecord is not enqueued before save")
  XCTAssertNil(
    try BlockedProfiles.findProfile(byID: profileId, in: context),
    "same context excludes the pending-deleted profile before save")

  let verifyBeforeSave = ModelContext(container)
  XCTAssertNotNil(
    try BlockedProfiles.findProfile(byID: profileId, in: verifyBeforeSave),
    "delete is not persisted until the deferred commit runs")

  scheduler.runNext()

  let verifyAfterSave = ModelContext(container)
  XCTAssertNil(try BlockedProfiles.findProfile(byID: profileId, in: verifyAfterSave))
  XCTAssertEqual(driver.pendingRecordZoneChanges, [.deleteRecord(recordID(recordName))])
}
```

- [ ] **Step 2: Run the test red**

```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -destination 'platform=iOS Simulator,id=B9E4A679-BDF3-4541-A59F-DA4BE21F80ED' \
  -parallel-testing-enabled NO \
  -only-testing:FoqosTests/MutationFunnelTests/testGivenSyncedProfile_WhenEnqueueDelete_ThenDeleteIsMarkedBeforeDeferredSaveAndEnqueuedAfterCommit | xcpretty
```

Expected: compile failure because `MutationFunnel.init` has no `scheduleProfileDeleteCommit:` parameter.

- [ ] **Step 3: Implement minimal scheduler injection**

In `MutationFunnel`, add:

```swift
  private let scheduleProfileDeleteCommit: (@escaping @MainActor () -> Void) -> Void
```

Change the initializer signature to:

```swift
    deviceId: String,
    scheduleProfileDeleteCommit: @escaping (@escaping @MainActor () -> Void) -> Void = { operation in
      Task { @MainActor in
        await Task.yield()
        operation()
      }
    }
```

Assign it:

```swift
    self.scheduleProfileDeleteCommit = scheduleProfileDeleteCommit
```

In `enqueueDelete(profileId:)`, replace the immediate save/enqueue block with:

```swift
      try BlockedProfiles.deleteProfile(profile, in: modelContext)
      let deleteZoneID = zoneID
      scheduleProfileDeleteCommit { [modelContext, driver, store, deleteZoneID] in
        do {
          try modelContext.save()
          let recordID = CKRecord.ID(recordName: recordName, zoneID: deleteZoneID)
          driver.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
        } catch {
          store.clearTombstone(recordName: recordName)
          modelContext.rollback()
          Log.error(
            "Deferred profile delete save failed for \(recordName): \(error.localizedDescription)",
            category: .sync
          )
        }
      }
      return
```

Remove the original immediate `modelContext.save()` and immediate `.deleteRecord` enqueue for profile deletes only. Do not change location deletes.

- [ ] **Step 4: Run the test green**

Run the command from Step 2 again.

Expected: test passes.

### Task 1.2: TDD crash-between-delete-and-save behavior

**Files:**
- Test: `FoqosTests/MutationFunnelTests.swift`

- [ ] **Step 1: Write the failing/passing documentation test**

Add:

```swift
func testGivenDeleteScheduledButCommitNotRun_WhenStoreReloads_ThenTombstoneSurvivesAndEntityStillExists()
  throws
{
  let profileId = UUID()
  let recordName = profileId.uuidString
  let container = try TestModelContainer.create()
  let context = ModelContext(container)
  try insertProfile(in: context, id: profileId, name: "Homework", syncVersion: 2)

  let store = makeStore()
  let driver = MockSyncEngineDriver()
  let scheduler = ManualProfileDeleteCommitScheduler()
  let funnel = MutationFunnel(
    modelContext: context,
    store: store,
    driver: driver,
    deviceId: "device-A",
    scheduleProfileDeleteCommit: scheduler.schedule
  )

  try funnel.enqueueDelete(profileId: profileId)

  let reloadedStore = makeStore()
  XCTAssertTrue(
    reloadedStore.deleteTombstones.keys.contains(recordName),
    "the tombstone is durable before the deferred save runs")

  let verifyContext = ModelContext(container)
  XCTAssertNotNil(
    try BlockedProfiles.findProfile(byID: profileId, in: verifyContext),
    "a process death before deferred save leaves the profile present")
  XCTAssertTrue(driver.pendingRecordZoneChanges.isEmpty)
}
```

- [ ] **Step 2: Run the test**

```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -destination 'platform=iOS Simulator,id=B9E4A679-BDF3-4541-A59F-DA4BE21F80ED' \
  -parallel-testing-enabled NO \
  -only-testing:FoqosTests/MutationFunnelTests/testGivenDeleteScheduledButCommitNotRun_WhenStoreReloads_ThenTombstoneSurvivesAndEntityStillExists | xcpretty
```

Expected: passes after Task 1.1 implementation. This is a risk-documentation test, not a red-first behavior change. If it fails, stop and inspect store/tombstone persistence before continuing.

### Task 1.3: Prevent list reorder from collapsing the delete window

**Files:**
- Modify: `Foqos/Views/BlockedProfileListView.swift`
- Test: existing `MutationFunnelTests` plus device verification.

- [ ] **Step 1: Inspect whether list delete path was used in Phase 0**

Use Phase 0 logs:

```text
[#285 PROBE] List delete selected profileId=...
[#285 PROBE] Funnel profile delete marked; scheduling deferred save recordName=...
[#285 PROBE] List delete reorder save about to run
```

If `List delete reorder save about to run` appears before the deferred funnel save, the reorder path is collapsing the two-phase window. Continue this task.

If editor delete path was used and list logs do not appear, do not modify list reorder yet; record that the editor path is the first production target.

- [ ] **Step 2: If list path collapses the window, defer reorder save**

Replace the immediate reorder block after the delete loop with a one-turn task:

```swift
      Task { @MainActor in
        await Task.yield()
        do {
          let remainingProfiles = try BlockedProfiles.fetchProfiles(in: context)
          try BlockedProfiles.reorderProfiles(remainingProfiles, in: context)
          for profile in remainingProfiles {
            do {
              try profileSyncManager.enqueueProfileSave(profile.id)
            } catch SyncEngineControllingError.notAttached {
              Log.warning("Profile reorder saved locally; sync engine not attached yet", category: .sync)
            }
          }
        } catch {
          Log.error("Failed to reorder profiles after deferred delete: \(error)", category: .ui)
          deleteError = .deleteFailed
        }
      }
```

Remove the old immediate reorder block. This is product-visible because reorder errors become asynchronous; if the maintainer did not accept async error handling in the decision gate, do not implement this.

- [ ] **Step 3: Run focused tests**

```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -destination 'platform=iOS Simulator,id=B9E4A679-BDF3-4541-A59F-DA4BE21F80ED' \
  -parallel-testing-enabled NO \
  -only-testing:FoqosTests/MutationFunnelTests | xcpretty
```

Expected: all `MutationFunnelTests` pass after updating any synchronous-delete expectations to use the manual scheduler.

### Task 1.4: Full verification and physical-device repro

**Files:** no additional changes.

- [ ] **Step 1: Run focused tests**

```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -destination 'platform=iOS Simulator,id=B9E4A679-BDF3-4541-A59F-DA4BE21F80ED' \
  -parallel-testing-enabled NO \
  -only-testing:FoqosTests/SafeModelViewTests \
  -only-testing:FoqosTests/MutationFunnelTests | xcpretty
```

Expected: all selected tests pass.

- [ ] **Step 2: Run full suite**

```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -destination 'platform=iOS Simulator,id=B9E4A679-BDF3-4541-A59F-DA4BE21F80ED' \
  -parallel-testing-enabled NO | xcpretty
```

Expected: full `FoqosTests` suite passes (820+ tests, 0 failures).

- [ ] **Step 3: Run format and guards**

```bash
swift-format lint --recursive .
scripts/check-sync-guards.sh
scripts/check-c2-guards.sh
```

Expected: all pass.

- [ ] **Step 4: Run physical-device delete repro**

On the paired iPhone:

1. Delete the app.
2. Install and launch the production (non-probe) build.
3. Create one new profile.
4. Return to Home with the carousel visible and the card centered.
5. Delete the profile through the same path as the falsification.
6. Repeat once with the deleted card centered/scrolled-to.

Expected: no crash; deleted card disappears cleanly; sync delete enqueue logs show completion.

- [ ] **Step 5: Confirm final scope**

```bash
git diff --name-only main...HEAD
```

Expected final production files include rev 1 predicate files plus only the Phase 1 files actually required by the accepted decision. No temporary `[#285 PROBE]` strings may remain:

```bash
rg -n "\[#285 PROBE\]" .
```

Expected: no matches.

---

## Maintainer Decision Options if Phase 0 Kills Two-Phase Delete

If deferring save does not eliminate the crash, stop with these options:

1. **Snapshot card input at the carousel boundary.**
   - Convert `BlockedProfileCard` to accept a value snapshot containing all displayed fields (`name`, indicators, strategy id, schedule display inputs, selected activity count, session count, domains count, app-selection flags).
   - Build the snapshot while the model is known valid in `BlockedProfileCarousel`.
   - Pros: child body never touches SwiftData after creation.
   - Cons: broader UI refactor; must keep actions keyed by `profile.id` or a safe captured id; may require separate edit/start closures that re-fetch by id.

2. **Add a persisted `isPendingDeletion` attribute.**
   - Save `isPendingDeletion = true`, filter it from UI, then perform actual delete later.
   - Pros: avoids SwiftData deleted-object traps because the row remains readable while UI removes it.
   - Cons: schema/migration change; sync semantics for pending delete must be designed; product-visible if app dies after pending flag.

3. **Add local deletion state outside SwiftData.**
   - Track `pendingDeletedProfileIds` in a deletion coordinator/environment object and filter carousel/list before touching SwiftData delete.
   - Pros: no schema change.
   - Cons: in-memory only; existing realized child views may still re-evaluate unless combined with snapshots; more moving parts.

Do not choose among these as an implementer. Present Phase 0 evidence and ask the maintainer to select a direction.

---

## Self-Review

- **Spec coverage:** Phase 0 proves or kills the child body re-evaluation mechanism and the one-runloop deferred save hypothesis. Phase 1 plans two-phase deletion through the existing `deleteProfile` seam and `MutationFunnel`, with explicit sync funnel and crash-between-delete-and-save analysis. Maintainer-decision options are listed if the probe kills the approach or exposes product-visible tradeoffs.
- **Placeholder scan:** No `TBD`, `TODO`, or "handle edge cases" placeholders remain. Conditional branches specify exact stop/proceed criteria.
- **Type consistency:** `isPersistentModelValid`, `debugPersistentModelStateFor285`, `MutationFunnel.enqueueDelete(profileId:)`, `BlockedProfiles.deleteProfile(_:in:)`, and `scheduleProfileDeleteCommit` are used consistently.
- **Rev 1 preservation:** The central predicate work remains the base and is not reverted.
- **Device rigor:** The physical-device repro remains the authoritative acceptance test; in-memory unit tests are not treated as proof for the device-only SwiftData window.
