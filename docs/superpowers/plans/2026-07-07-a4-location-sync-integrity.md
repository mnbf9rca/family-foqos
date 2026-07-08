# A4′ — Location Sync Integrity Implementation Plan (#215, #216, #220)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax. This plan is **self-contained** — it assumes no prior Claude session/project memory (the implementer may be Codex). Read `AGENTS.md` at the repo root first; it overrides everything here.

**Goal:** Deleting a saved location — locally or via sync — must repair every profile whose geofence rule referenced it, replicate that repair to peers, and never leave a profile unstoppable; and the geofence evaluator must stay robust even if a dangling reference slips through.

**Architecture:** All three items are grounded in the S0 CKSyncEngine sync layer (PR #269, merged; follow-ups #277/#289 merged). A saved-location delete is an **explicit deletion event** at two seams: locally through `MutationFunnel.enqueueDelete(locationId:)` (I2), and remotely through `SyncApplyService.deleteLocalLocation` (the engine's `fetchedRecordZoneChanges.deletions`). One shared cleanup helper rides both seams; repaired profiles re-push through the funnel (local) / the `pendingReenqueues` I2-exception (remote). #215 also hardens the pure-local geofence evaluator as a safety net. #220 is **obsolete** under S0 (documented, with a regression guard).

**Tech Stack:** Swift 6, SwiftData (`cloudKitDatabase: .none`), CloudKit `CKSyncEngine`, `FoqosShared` package (`ProfileGeofenceRule`), XCTest. Xcode 26.6.

**Base commit:** `4307654` (latest `main` — includes S0 #269 + #277/#289). Re-triage recorded as issue comments (2026-07-07): #215 still-present, #216 still-present, #220 obsolete.

---

## Global Constraints

Every task's requirements implicitly include this section.

- **The S0 contract is INVIOLABLE.** All locally-originated mutations of a synced entity flow through `MutationFunnel` (I2). Inbound applies push ONLY via `pendingReenqueues → drainReenqueues`. **Deletion-event cleanup rides the engine's EXPLICIT deletion events — never orphan inference / proactive scanning.** Each task carries an **S0 conformance note**.
- Geofence rules live on `BlockedProfiles.geofenceRule: ProfileGeofenceRule?`. `ProfileGeofenceRule` (`Packages/FoqosShared/Sources/FoqosShared/GeofenceRule.swift:62`) is a value type: `ruleType`, `locationReferences: [ProfileLocationReference]`, `allowEmergencyOverride`. `ProfileLocationReference.savedLocationId: UUID` (`:47`). `hasLocations` = `!locationReferences.isEmpty` (`:78`).
- Views use `@SafeQuery` (never raw `@Query`); non-query model arrays filtered with `.valid`.
- Lock checks use `appModeManager.currentMode == .child` — never `!= .parent`.
- `Log.<level>(_, category:)` (never `print()`); no PII/lock codes in logs.
- swift-format enforced (2-space indent, ~100–120 col).
- Tests: `testGivenX_WhenY_ThenZ()`; **pin time** (one `let now = Date()` per test); run by simulator **UUID**, never device name.
- NEVER amend/force-push; new commits only. Request code review before merging.

---

## Task 0: Citation refresh (MANDATORY — do this first, no code)

- [ ] **Step 1: Confirm base + the seams exist**
```bash
git log --oneline -1                        # 4307654 or a descendant
sed -n '101,167p' Foqos/Utils/LocationManager.swift          # #215 checkGeofenceRule
sed -n '155,173p' Foqos/CloudKit/SyncEngine/MutationFunnel.swift   # local delete seam
sed -n '175,195p' Foqos/CloudKit/SyncEngine/SyncApplyService.swift # remote delete seam (deleteLocalLocation)
sed -n '312,343p' Foqos/CloudKit/SyncEngine/SyncEngineController.swift  # fetch dispatch + drain
sed -n '194,247p' Foqos/Views/SavedLocationsView.swift       # local delete UI path
sed -n '300,320p' Foqos/Models/BlockedProfiles.swift         # fetchProfiles/findProfile
```
Expected: `.outside` compares `unsatisfiedLocations.count == rule.locationReferences.count` (`LocationManager.swift:160`); `deleteLocalLocation` has zero profile repair; the fetch dispatch drains reenqueues after modifications (line ~334) but **not** after the deletions loop (~337-342); `SavedLocationsView.deleteLocation` calls `removeLocationFromProfiles` then routes the delete through the funnel.

- [ ] **Step 2: Re-grep symbols**
> **grep portability (PR #292 review N3):** multi-pattern greps below use `grep -nF -e … -e …` (fixed strings) rather than BRE `\|` alternation — portable across BSD/macOS and GNU `grep`, and `.`/`(` are never treated as regex metacharacters.
```bash
grep -nF -e 'func checkGeofenceRule' -e 'unsatisfiedLocations' -e 'satisfiedLocations' -e 'locationReferences.count' Foqos/Utils/LocationManager.swift
grep -nF -e 'func enqueueDelete(locationId' -e 'func enqueueSave(profileId' -e 'private var zoneID' Foqos/CloudKit/SyncEngine/MutationFunnel.swift
grep -nF -e 'func deleteLocalLocation' -e 'pendingReenqueues' -e 'func commit' -e 'clearDeletionBookkeeping' Foqos/CloudKit/SyncEngine/SyncApplyService.swift
grep -nF -e 'drainReenqueues' -e 'for (recordID, recordType) in deletions' -e 'func retryFailedApplies' -e 'case .delete' Foqos/CloudKit/SyncEngine/SyncEngineController.swift
grep -nF -e 'func removeLocationFromProfiles' -e 'func deleteLocation' -e 'enqueueLocationDelete' -e 'func fetchProfiles' -e 'func removeLocationReference' Foqos/Views/SavedLocationsView.swift Foqos/Models/BlockedProfiles.swift
```

- [ ] **Step 3: Boot the test simulator once** (per AGENTS.md; reuse the UUID for every task).

---

## Task 1: #215 — geofence evaluator counts only resolvable references

**Why:** `checkGeofenceRule` skips references to deleted locations (`continue`, `LocationManager.swift:128-130`) but the `.outside` branch requires `unsatisfiedLocations.count == rule.locationReferences.count` — a count that still includes the skipped dangling refs — so an `.outside` rule with any dangling ref is **unsatisfiable everywhere on Earth**, and a `.within` rule whose refs all dangle fails forever with an empty-name message. Every stop path routes through this, so the session becomes unstoppable. This hardening is the safety net; Tasks 2–4 remove the dangling refs at the source.

**Files:**
- Modify: `Foqos/Utils/LocationManager.swift:147-166` (the rule-type switch in `checkGeofenceRule(rule:savedLocations:)`).
- Test: `FoqosTests/GeofenceDanglingReferenceTests.swift` (create).

**Interfaces:**
- Consumes: `func checkGeofenceRule(rule: ProfileGeofenceRule, savedLocations: [SavedLocation]) async -> GeofenceCheckResult` (`:101`); `GeofenceCheckResult.satisfied()/.failed(message:)`.
- Produces: no new symbol; behavior change (dangling-only rules ⇒ satisfied; `.outside` counted against resolvable refs).

- [ ] **Step 1: Write the failing tests**

Create `FoqosTests/GeofenceDanglingReferenceTests.swift`:
```swift
import FoqosShared
import XCTest

@testable import FamilyFoqos

@MainActor
final class GeofenceDanglingReferenceTests: XCTestCase {

  private func rule(_ type: GeofenceRuleType, refs: [UUID]) -> ProfileGeofenceRule {
    ProfileGeofenceRule(
      ruleType: type,
      locationReferences: refs.map { ProfileLocationReference(savedLocationId: $0) },
      allowEmergencyOverride: true)
  }

  func testGivenOutsideRuleWithOnlyDanglingRef_WhenEvaluated_ThenSatisfied() async {
    // No SavedLocation matches the reference ⇒ the rule has no live constraint ⇒ stoppable.
    let result = await LocationManager.shared.checkGeofenceRule(
      rule: rule(.outside, refs: [UUID()]), savedLocations: [])
    XCTAssertTrue(result.isSatisfied, "an all-dangling .outside rule must not be unsatisfiable")
  }

  func testGivenWithinRuleWithOnlyDanglingRef_WhenEvaluated_ThenSatisfied() async {
    let result = await LocationManager.shared.checkGeofenceRule(
      rule: rule(.within, refs: [UUID()]), savedLocations: [])
    XCTAssertTrue(result.isSatisfied, "an all-dangling .within rule must not fail forever")
  }
}
```
> `checkGeofenceRule` calls `getCurrentLocation()` internally, which needs location services. If the evaluator reaches the location fetch for these all-dangling cases the test may be environment-dependent — the fix places the all-unresolvable guard AFTER the reference loop but the current-location fetch happens BEFORE it. During Task 0, confirm whether `getCurrentLocation()` returns deterministically in the test host; if it does not, move the guard: add an **early** `resolvableCount`-style check that runs before `getCurrentLocation()` by pre-resolving references against `savedLocations` at the top of the method (see Step 3 note). Prefer the early guard so the test needs no location permission.

- [ ] **Step 2: Run — expect FAIL** (`.outside`/`.within` all-dangling return `.failed`).

- [ ] **Step 3: Apply the resolvable-count fix**

Preferred (early, permission-free) form — insert right after the `guard rule.hasLocations else { return .satisfied() }` at `LocationManager.swift:106`:
```swift
    // #215: references to deleted locations are skipped below; if NONE of the rule's references
    // resolve to a live SavedLocation, the rule has no enforceable constraint — treat it as
    // satisfied so the profile stays stoppable (belt for the deletion-cleanup fix in A4′).
    let resolvableIds = Set(savedLocations.map { $0.id })
    let hasResolvableReference = rule.locationReferences.contains {
      resolvableIds.contains($0.savedLocationId)
    }
    guard hasResolvableReference else {
      return .satisfied()
    }
```
And change the `.outside` comparison (line 160) to count resolvable refs, not raw `locationReferences.count`:
```swift
    case .outside:
      // #215: compare against RESOLVABLE references only — dangling refs are skipped above and
      // must never make the rule unsatisfiable.
      let resolvableCount = satisfiedLocations.count + unsatisfiedLocations.count
      if unsatisfiedLocations.count == resolvableCount {
        return .satisfied()
      } else {
        let locationNames = satisfiedLocations.prefix(2).joined(separator: " and ")
        return .failed(message: "You must leave \(locationNames) to stop this profile.")
      }
```
(`.within` needs no change beyond the early guard: `!satisfiedLocations.isEmpty` is already correct once all-dangling is handled.)

- [ ] **Step 4: Run — expect PASS.**

**S0 conformance note:** pure local evaluation change; no sync/funnel involvement. It is defense-in-depth so a transient dangling reference (before the cleanup replicates) can never wedge a session.

- [ ] **Step 5: Commit**
```bash
git add Foqos/Utils/LocationManager.swift FoqosTests/GeofenceDanglingReferenceTests.swift
git commit -m "fix(#215): geofence evaluator counts only resolvable references (dangling ⇒ satisfied)"
```

---

## Task 2: shared cleanup helper `BlockedProfiles.removeLocationReference`

**Why:** #215 and #216 both need to strip a deleted location from every profile's geofence rule. One helper, invoked from both the local and remote deletion seams, prevents divergent copies.

**Files:**
- Modify: `Foqos/Models/BlockedProfiles.swift` (add the static helper near `fetchProfiles`).
- Test: `FoqosTests/RemoveLocationReferenceTests.swift` (create).

**Interfaces:**
- Consumes: `BlockedProfiles.fetchProfiles(in:)` (`:304`); `geofenceRule` (`:42`).
- Produces: `@discardableResult static func removeLocationReference(_ locationId: UUID, in context: ModelContext) throws -> [UUID]` — returns the ids of changed profiles.

- [ ] **Step 1: Write the failing test**

Create `FoqosTests/RemoveLocationReferenceTests.swift`:
```swift
import FoqosShared
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class RemoveLocationReferenceTests: XCTestCase {

  private func profile(_ context: ModelContext, name: String, rule: ProfileGeofenceRule?) throws -> BlockedProfiles {
    let p = BlockedProfiles(id: UUID(), name: name)
    p.geofenceRule = rule
    context.insert(p)
    try context.save()
    return p
  }

  func testGivenProfilesReferencingLocation_WhenRemoved_ThenStrippedAndChangedIdsReturned() throws {
    let container = try TestModelContainer.create()
    let context = ModelContext(container)
    let locId = UUID()
    let ruleWith = ProfileGeofenceRule(
      ruleType: .outside,
      locationReferences: [ProfileLocationReference(savedLocationId: locId)],
      allowEmergencyOverride: true)
    let referencing = try profile(context, name: "Ref", rule: ruleWith)
    _ = try profile(context, name: "Unrelated", rule: nil)

    let changed = try BlockedProfiles.removeLocationReference(locId, in: context)
    try context.save()  // helper does not save; the caller owns the commit

    XCTAssertEqual(changed, [referencing.id])
    let reread = try XCTUnwrap(BlockedProfiles.findProfile(byID: referencing.id, in: context))
    XCTAssertNil(reread.geofenceRule, "rule with only that reference is nulled when it empties")
  }

  func testGivenMultiRefRule_WhenOneRemoved_ThenOthersKept() throws {
    let container = try TestModelContainer.create()
    let context = ModelContext(container)
    let locId = UUID(); let keepId = UUID()
    let rule = ProfileGeofenceRule(
      ruleType: .within,
      locationReferences: [
        ProfileLocationReference(savedLocationId: locId),
        ProfileLocationReference(savedLocationId: keepId),
      ],
      allowEmergencyOverride: true)
    let p = try profile(context, name: "Multi", rule: rule)

    let changed = try BlockedProfiles.removeLocationReference(locId, in: context)
    try context.save()  // helper does not save; the caller owns the commit

    XCTAssertEqual(changed, [p.id])
    let reread = try XCTUnwrap(BlockedProfiles.findProfile(byID: p.id, in: context))
    XCTAssertEqual(reread.geofenceRule?.locationReferences.map { $0.savedLocationId }, [keepId])
  }

  func testGivenNoReferences_WhenRemoved_ThenNoChange() throws {
    let container = try TestModelContainer.create()
    let context = ModelContext(container)
    _ = try profile(context, name: "None", rule: nil)
    let changed = try BlockedProfiles.removeLocationReference(UUID(), in: context)
    XCTAssertTrue(changed.isEmpty)
  }
}
```

- [ ] **Step 2: Run — expect compile FAIL.**

- [ ] **Step 3: Implement** (in `BlockedProfiles.swift`, next to `fetchProfiles`)
```swift
  /// Strip a deleted location from every profile's geofence rule (nulling the rule when it
  /// empties) and return the ids of profiles that changed. #215/#216: the single cleanup invoked
  /// from both the local funnel delete and the inbound apply delete — it rides the explicit
  /// deletion event; it never scans for or infers orphans. **Does NOT save** — the caller owns the
  /// single commit so the strip is atomic with the location delete on the same context (a rolled-
  /// back delete rolls back the strip too).
  @discardableResult
  static func removeLocationReference(_ locationId: UUID, in context: ModelContext) throws -> [UUID] {
    let profiles = try fetchProfiles(in: context)
    var changed: [UUID] = []
    for profile in profiles {
      guard var rule = profile.geofenceRule,
        rule.locationReferences.contains(where: { $0.savedLocationId == locationId })
      else { continue }
      rule.locationReferences.removeAll { $0.savedLocationId == locationId }
      profile.geofenceRule = rule.locationReferences.isEmpty ? nil : rule
      changed.append(profile.id)
    }
    return changed
  }
```
> The helper mutates in place and does not `save()`. Callers commit exactly once (Task 3: `SavedLocation.delete`'s own save covers the strip; Task 4: an explicit `commit()`).

- [ ] **Step 4: Run — expect PASS.**

**S0 conformance note:** pure model helper — no push of its own. Callers (Tasks 3/4) attach the push through the funnel / `pendingReenqueues`. It acts only on an id handed to it by an explicit deletion event.

- [ ] **Step 5: Commit**
```bash
git add Foqos/Models/BlockedProfiles.swift FoqosTests/RemoveLocationReferenceTests.swift
git commit -m "feat(#215/#216): shared BlockedProfiles.removeLocationReference cleanup helper"
```

---

## Task 3: #216 (local seam) — funnel-owned repair that replicates

**Why:** the local delete path currently strips profiles via `SavedLocationsView.removeLocationFromProfiles` with a bare `context.save()` — **never pushing** the repaired profiles — so peers keep the stale reference. Fold the repair into `MutationFunnel.enqueueDelete(locationId:)` so it is unbypassable AND replicated, and drop the view's un-pushed copy.

**Files:**
- Modify: `Foqos/CloudKit/SyncEngine/MutationFunnel.swift:157-173` (`enqueueDelete(locationId:)`).
- Modify: `Foqos/Views/SavedLocationsView.swift:194-246` (`deleteLocation` fallbacks; remove `removeLocationFromProfiles`).
- Test: extend `FoqosTests/MutationFunnelTests.swift`.

**Interfaces:**
- Consumes: `BlockedProfiles.removeLocationReference(_:in:)` (Task 2); `MutationFunnel.enqueueSave(profileId:)` (`:50`); `MutationFunnel.modelContext`/`zoneID`.
- Produces: `enqueueDelete(locationId:)` now also enqueues one `.saveRecord` per repaired profile.

- [ ] **Step 1: Write the failing funnel test** (append to `MutationFunnelTests.swift`)
```swift
  func testGivenLocationReferencedByProfile_WhenEnqueueDelete_ThenRepairsAndPushesProfile() throws {
    let container = try TestModelContainer.create()
    let context = ModelContext(container)
    let locationId = UUID()
    let profileId = UUID()

    let location = SavedLocation(id: locationId, name: "Library", latitude: 1, longitude: 2)
    context.insert(location)
    let profile = BlockedProfiles(id: profileId, name: "Homework", syncVersion: 4)
    profile.geofenceRule = ProfileGeofenceRule(
      ruleType: .outside,
      locationReferences: [ProfileLocationReference(savedLocationId: locationId)],
      allowEmergencyOverride: true)
    context.insert(profile)
    try context.save()

    let store = makeStore()
    let driver = MockSyncEngineDriver()
    let funnel = MutationFunnel(
      modelContext: context, store: store, driver: driver, deviceId: "device-A")

    try funnel.enqueueDelete(locationId: locationId)

    // Location gone, profile repaired + version bumped...
    XCTAssertNil(try SavedLocation.find(byID: locationId, in: context))
    let reread = try XCTUnwrap(BlockedProfiles.findProfile(byID: profileId, in: context))
    XCTAssertNil(reread.geofenceRule, "dangling rule is cleaned up")
    XCTAssertEqual(reread.syncVersion, 5, "repaired profile bumps for replication")
    // ...and BOTH the location delete and the profile save were enqueued.
    XCTAssertTrue(
      driver.pendingRecordZoneChanges.contains(.deleteRecord(recordID(locationId.uuidString))))
    XCTAssertTrue(
      driver.pendingRecordZoneChanges.contains(.saveRecord(recordID(profileId.uuidString))))
  }
```

- [ ] **Step 2: Run — expect FAIL** (no profile save enqueued; version stays 4).

- [ ] **Step 3: Fold repair into `enqueueDelete(locationId:)`**

Replace the body (lines 157-173):
```swift
  func enqueueDelete(locationId: UUID) throws {
    let recordName = locationId.uuidString
    let changeTag = Self.changeTag(fromSystemFields: store.systemFields(for: recordName))
    store.setTombstone(recordName: recordName, changeTag: changeTag)
    let repaired: [UUID]
    do {
      guard let location = try SavedLocation.find(byID: locationId, in: modelContext) else {
        throw MutationFunnelError.entityNotFound
      }
      // #216: strip the location from referencing profiles (pending — the helper does NOT save),
      // then let SavedLocation.delete's own save commit the strip AND the delete together, so a
      // failure BEFORE this point rolls the pending strip back (genuinely atomic on this context).
      repaired = try BlockedProfiles.removeLocationReference(locationId, in: modelContext)
      try SavedLocation.delete(location, in: modelContext)  // one save commits strip + delete
    } catch {
      store.clearTombstone(recordName: recordName)
      modelContext.rollback()
      throw error
    }
    // Point of no return: the location delete is committed and cannot be rolled back. Enqueue its
    // .deleteRecord (keeping the tombstone) BEFORE the fallible profile re-pushes, so a repaired-
    // profile save failure can never orphan the location delete (clear its tombstone / skip its
    // .deleteRecord, leaving it deleted-locally-but-unreplicated and open to resurrection).
    let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
    driver.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
    // #216: re-push each repaired profile so peers converge — BEST-EFFORT. A failure here leaves
    // that profile's (already-persisted) strip un-replicated until its next edit; the Task 1 #215
    // evaluator net keeps sessions stoppable meanwhile. It must NOT abort the location delete.
    for profileId in repaired {
      do {
        try enqueueSave(profileId: profileId)  // bump syncVersion + persist + enqueue .saveRecord
      } catch {
        Log.warning(
          "Location-delete profile repair re-push failed for \(profileId): "
            + error.localizedDescription, category: .sync)
      }
    }
  }
```

- [ ] **Step 4: Simplify the view** (`SavedLocationsView.deleteLocation`)

Remove the unconditional `removeLocationFromProfiles(locationId)` at line 199 (the funnel now owns repair on the sync path). In the two **fallback** branches — the `catch SyncEngineControllingError.notAttached` (line 212-218) and the `else` sync-disabled branch (219-223) — call the shared helper locally before the local delete so those paths still repair (no push, because sync is off/not-ready):
```swift
        } catch SyncEngineControllingError.notAttached {
          try BlockedProfiles.removeLocationReference(locationId, in: context)
          try SavedLocation.delete(location, in: context)
        }
      } else {
        try BlockedProfiles.removeLocationReference(locationId, in: context)
        try SavedLocation.delete(location, in: context)
      }
```
Then delete the now-unused `removeLocationFromProfiles(_:)` method (lines 229-246).

- [ ] **Step 5: Run funnel tests + the location-delete regression guards — expect PASS**
`xcodebuild test ... -only-testing:FoqosTests/MutationFunnelTests | xcpretty`
(The existing `testGivenSyncedLocation_WhenEnqueueDeleteAloneOnSharedContext_...` guard must still pass — the repair is a no-op when no profile references the location.)

**S0 conformance note:** repair rides the explicit local deletion event (the funnel delete). Repaired profiles push ONLY via `enqueueSave(profileId:)` (I2). No scan/inference. The view's fallback repair (sync off/not-ready) is local-only, consistent with those paths already deleting locally without a push.

- [ ] **Step 6: Commit**
```bash
git add Foqos/CloudKit/SyncEngine/MutationFunnel.swift Foqos/Views/SavedLocationsView.swift FoqosTests/MutationFunnelTests.swift
git commit -m "fix(#216): funnel-owned geofence repair on local location delete (replicates to peers)"
```

---

## Task 4: #216 (remote seam) — repair + re-push on inbound location deletion

**Why:** a remote location delete arrives as `applyFetchedDeletion → deleteLocalLocation`, which removes the `SavedLocation` with **zero** profile repair — leaving the peer's profiles dangling. Repair there too, and re-push the repaired profiles via the `pendingReenqueues` I2-exception. The controller currently drains reenqueues only after the *modifications* loop, so a deletion-triggered reenqueue must get its own drain.

**Files:**
- Modify: `Foqos/CloudKit/SyncEngine/SyncApplyService.swift` (`deleteLocalLocation` `:175`; add a private `zoneID`).
- Modify: `Foqos/CloudKit/SyncEngine/SyncEngineController.swift` (drain after the deletions loop `:342`; drain after the `retryFailedApplies` loop `~717`).
- Test: add a deletion-repair method inside `FoqosTests/SyncApplyServiceTests.swift` (reuses its `makeService()`/`zoneID`/`context`).

**Interfaces:**
- Consumes: `BlockedProfiles.removeLocationReference(_:in:)` (Task 2); `SyncApplyService.pendingReenqueues`/`drainReenqueues()` (`:25`/`:50`); `commit()` (`:493`); `BlockedProfiles.findProfile(byID:in:)`.
- Produces: `deleteLocalLocation` appends repaired-profile `CKRecord.ID`s to `pendingReenqueues`; controller drains them.

- [ ] **Step 1: Write the failing apply test**

Add this method **inside `FoqosTests/SyncApplyServiceTests.swift`** — it already has `context`, `store`, `zoneID`, and a `private makeService()`, and already tests location deletion (lines ~496/521), so reuse them rather than replicating the setUp in a new file that cannot reach the `private` helper. Add `import FoqosShared` to that file if not already present (needed for `ProfileGeofenceRule`):
```swift
  func testGivenReferencingProfile_WhenLocationDeletionApplied_ThenRepairedAndReenqueued() throws {
    let apply = makeService()
    let locId = UUID()
    let pid = UUID()
    let location = SavedLocation(id: locId, name: "Library", latitude: 1, longitude: 2)
    context.insert(location)
    let profile = BlockedProfiles(id: pid, name: "Homework", syncVersion: 4)
    profile.geofenceRule = ProfileGeofenceRule(
      ruleType: .outside,
      locationReferences: [ProfileLocationReference(savedLocationId: locId)],
      allowEmergencyOverride: true)
    context.insert(profile)
    try context.save()

    let outcome = apply.applyFetchedDeletion(
      recordID: CKRecord.ID(recordName: locId.uuidString, zoneID: zoneID),
      recordType: SyncedLocation.recordType)

    XCTAssertEqual(outcome, .deleted)
    XCTAssertNil(try SavedLocation.find(byID: locId, in: context))
    let reread = try XCTUnwrap(BlockedProfiles.findProfile(byID: pid, in: context))
    XCTAssertNil(reread.geofenceRule, "dangling rule repaired on the peer")
    XCTAssertEqual(reread.syncVersion, 5, "bumped so the peer accepts the repaired payload")
    XCTAssertEqual(
      apply.drainReenqueues(), [CKRecord.ID(recordName: pid.uuidString, zoneID: zoneID)],
      "repaired profile queued for re-push via the I2 exception")
  }

  // Copilot review comment #2: the deletion event is authoritative — a dangling reference must be
  // repaired even when the SavedLocation row is already gone (local-delete-first / retry window).
  func testGivenDanglingProfileButLocationAlreadyAbsent_WhenDeletionApplied_ThenStillRepairs() throws {
    let apply = makeService()
    let locId = UUID()  // no SavedLocation row inserted — it is already absent
    let pid = UUID()
    let profile = BlockedProfiles(id: pid, name: "Homework", syncVersion: 4)
    profile.geofenceRule = ProfileGeofenceRule(
      ruleType: .outside,
      locationReferences: [ProfileLocationReference(savedLocationId: locId)],
      allowEmergencyOverride: true)
    context.insert(profile)
    try context.save()

    let outcome = apply.applyFetchedDeletion(
      recordID: CKRecord.ID(recordName: locId.uuidString, zoneID: zoneID),
      recordType: SyncedLocation.recordType)

    XCTAssertEqual(outcome, .deleted, "repaired a dangling ref ⇒ not a no-op")
    let reread = try XCTUnwrap(BlockedProfiles.findProfile(byID: pid, in: context))
    XCTAssertNil(reread.geofenceRule, "dangling ref repaired even though the row was already gone")
    XCTAssertEqual(reread.syncVersion, 5)
    XCTAssertEqual(
      apply.drainReenqueues(), [CKRecord.ID(recordName: pid.uuidString, zoneID: zoneID)])
  }
```
> `zoneID` is the test class's existing stored property (`SyncApplyServiceTests.swift:18`); do not redeclare it.

- [ ] **Step 2: Run — expect FAIL** (no repair, `drainReenqueues()` empty).

- [ ] **Step 3: Add a `zoneID` to `SyncApplyService`** (near the other stored props)
```swift
  private var zoneID: CKRecordZone.ID {
    CKRecordZone.ID(zoneName: CloudKitConstants.syncZoneName, ownerName: CKCurrentUserDefaultName)
  }
```

- [ ] **Step 4: Repair inside `deleteLocalLocation`**

Replace the success arm (lines 178-184):
```swift
      guard let location = try SavedLocation.find(byID: id, in: modelContext) else {
        clearDeletionBookkeeping(recordName: recordName)
        return .notPresent
      }
      try SavedLocation.delete(location, in: modelContext)  // saves internally
      clearDeletionBookkeeping(recordName: recordName)
      return .deleted
```
with:
```swift
      // #216: the deletion event is AUTHORITATIVE, so repair referencing profiles whether or not
      // the location row is still present. A dangling reference can outlive the row (local-delete-
      // first, or a prior apply whose location delete committed but whose repair commit then
      // failed and was retried) — repairing only in the present case would re-skip that window.
      let location = try SavedLocation.find(byID: id, in: modelContext)
      if let location {
        try SavedLocation.delete(location, in: modelContext)  // saves internally
      }
      // Strip the deleted location from referencing profiles and re-push them so peers converge.
      // Re-push rides the pendingReenqueues I2 exception (inbound apply never pushes directly);
      // rides the explicit deletion event; no orphan inference.
      let repaired = try BlockedProfiles.removeLocationReference(id, in: modelContext)
      for profileId in repaired {
        guard let profile = try BlockedProfiles.findProfile(byID: profileId, in: modelContext)
        else { continue }
        profile.syncVersion += 1
        pendingReenqueues.append(CKRecord.ID(recordName: profileId.uuidString, zoneID: zoneID))
      }
      if !repaired.isEmpty { try commit() }  // SavedLocation.delete already saved any row removal
      clearDeletionBookkeeping(recordName: recordName)
      // .deleted if anything was actually removed/repaired; .notPresent only when the row was
      // already gone AND no profile still referenced it (a genuine no-op).
      return (location == nil && repaired.isEmpty) ? .notPresent : .deleted
```
> The helper leaves the strip pending; the single `commit()` here persists the strips **and** the `syncVersion += 1` bumps together (the bump makes the re-push a genuine advance the peer accepts, `synced.version > local`). **Delete-then-repair-fail window (now closed):** `SavedLocation.delete` commits the location deletion *before* the repair commit, so if `commit()` throws the location is gone but the profiles are momentarily un-repaired (the outer `catch` records a `FailedApply(.delete)`). Because this method now repairs referencing profiles **even when the location row is already absent** (Copilot review comment #2), the `retryFailedApplies` re-entry finds the row gone and *still* strips + re-pushes the dangling references — so the window self-heals on the next retry cycle rather than relying on the Task 1 #215 net. The #215 evaluator net remains as belt-and-suspenders for the brief pre-retry interval.

- [ ] **Step 5: Drain reenqueues after the deletions loop AND after the retry loop** (`SyncEngineController.swift`)

After the deletions loop (currently ends at line 342), add:
```swift
    for recordID in apply.drainReenqueues() {  // #216: re-push profiles repaired by a deletion
      driver.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
    }
```
And after the `for entry in ...` loop inside `retryFailedApplies` (the `.delete` branch at lines 700-716 can now also repair), add the same drain immediately after that loop closes (~line 717):
```swift
    for recordID in apply.drainReenqueues() {
      driver.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
    }
```

- [ ] **Step 6: Run — expect PASS.** Then run the engine suite to confirm no regression:
`xcodebuild test ... -only-testing:FoqosTests/SyncApplyServiceTests -only-testing:FoqosTests/RecordProviderTests -only-testing:FoqosTests/MutationFunnelTests | xcpretty`

**S0 conformance note:** repair rides the engine's EXPLICIT `fetchedRecordZoneChanges.deletions` event (and its retry equivalent). Inbound apply still performs no direct push — repaired profiles reach the driver only through the existing `pendingReenqueues → drainReenqueues` I2 exception, now drained on the deletion path too. No inference.

- [ ] **Step 7: Commit**
```bash
git add Foqos/CloudKit/SyncEngine/SyncApplyService.swift Foqos/CloudKit/SyncEngine/SyncEngineController.swift FoqosTests/SyncApplyServiceTests.swift
git commit -m "fix(#216): repair + re-push profiles on inbound location deletion (drain on deletion path)"
```

---

## Task 5: #220 — document obsolescence + regression guard

**Why:** the location-sync ping-pong required the pre-S0 `pushLocalData` bulk re-push after every sync. Under S0 the inbound location apply (`applyLocationModification`) performs a pure N6 client-clock merge and **never pushes** (it makes no `driver.add` call and never appends to `pendingReenqueues`; only the profile branches at `:255`/`:278` do). The only location push origin is `MutationFunnel.enqueueSave(locationId:)` on a genuine local edit. The loop cannot form. This task adds a guard so it stays gone; no production change.

**Files:**
- Test: add two guard methods inside `FoqosTests/SyncApplyServiceTests.swift` (reuses `context`/`store`/`zoneID`/`makeService()`).

- [ ] **Step 1: Write the guard tests** (add inside `SyncApplyServiceTests`; `SyncedLocation(locationId:name:latitude:longitude:defaultRadiusMeters:isLocked:lastModified:)` is the real init at `SyncModels.swift:426` — no `syncVersion`/`originDeviceId`, N6 client-clock merge):
```swift
  func testGivenNewerRemoteLocation_WhenApplied_ThenNothingReenqueued() throws {
    let now = Date()
    let apply = makeService()
    let locId = UUID()
    let location = SavedLocation(
      id: locId, name: "Home", latitude: 1, longitude: 2, updatedAt: now.addingTimeInterval(-3600))
    context.insert(location)
    try context.save()

    let synced = SyncedLocation(  // newer than local ⇒ apply branch fires
      locationId: locId, name: "Renamed", latitude: 1, longitude: 2,
      defaultRadiusMeters: 500, isLocked: false, lastModified: now)
    _ = apply.applyFetchedModification(
      synced.toCKRecord(in: zoneID), isPendingDeleteOrTombstoned: { _ in false })

    XCTAssertTrue(apply.drainReenqueues().isEmpty, "applying a location must never trigger a push")
  }

  func testGivenOlderRemoteLocation_WhenApplied_ThenNoOpAndNothingReenqueued() throws {
    let now = Date()
    let apply = makeService()
    let locId = UUID()
    let location = SavedLocation(
      id: locId, name: "Home", latitude: 1, longitude: 2, updatedAt: now)  // local is FUTURE vs remote
    context.insert(location)
    try context.save()

    let synced = SyncedLocation(  // older than local ⇒ N6 else-branch no-op
      locationId: locId, name: "Stale", latitude: 9, longitude: 9,
      defaultRadiusMeters: 500, isLocked: false, lastModified: now.addingTimeInterval(-3600))
    _ = apply.applyFetchedModification(
      synced.toCKRecord(in: zoneID), isPendingDeleteOrTombstoned: { _ in false })

    XCTAssertTrue(apply.drainReenqueues().isEmpty, "the N6 no-op branch must not push either")
  }
```

- [ ] **Step 2: Run — expect PASS immediately** (this is a characterization/guard test; it documents the fixed behavior — it should be green with no production change). If it is NOT green, STOP: a location-apply push path exists and #220 is not actually obsolete — re-open the investigation before proceeding.

- [ ] **Step 3: Commit**
```bash
git add FoqosTests/SyncApplyServiceTests.swift
git commit -m "test(#220): guard that inbound location apply never re-enqueues a push (obsolete under S0)"
```

- [ ] **Step 4:** Recommend closing #220 as obsolete in the PR description (the re-triage comment already documents why). Do not change production code for #220.

---

## Skeptic Pass — review-hardening provenance (PR #292)

For provenance parity, the adversarial findings folded into this plan during review are recorded here (not only in the PR threads), so a future reader sees WHY the deletion seams are shaped this way:

- **Two-agent skeptic pass (pre-merge):** confirmed the S0 contract holds on all three items and the citations are accurate; all findings were in test-code precision (nonexistent memberwise inits, placeholder test bodies, `SyncApplyServiceTests` private-helper reuse, helper-save atomicity) and were fixed before commit.
- **Copilot review #1 → Task 3 (local delete seam):** a throw from `enqueueSave(profileId:)` after `SavedLocation.delete` had committed would clear the tombstone + skip the `.deleteRecord`, orphaning the delete (deleted-locally-but-unreplicated, resurrection-prone). **Folded:** the location `.deleteRecord` is now enqueued at the point-of-no-return (right after the delete commits, tombstone kept) and the profile re-pushes are best-effort — see Task 3 Step 3.
- **Copilot review #2 → Task 4 (remote delete seam):** returning `.notPresent` when the `SavedLocation` row was already absent skipped profile repair and re-skipped it on retry. **Folded:** `deleteLocalLocation` repairs referencing profiles whether or not the row is present (the deletion event is authoritative), closing the delete-then-repair-fail window — see Task 4 Step 4 and the regression test `testGivenDanglingProfileButLocationAlreadyAbsent_…`.

---

## Final verification (whole bundle)

- [ ] **Full FoqosTests suite** green against the booted simulator UUID.
- [ ] **Sync-guard CI check:** `./scripts/check-sync-guards.sh` passes (no raw `@Query`, no funnel bypass).
- [ ] **swift-format lint clean:** `swift-format lint --recursive . && echo OK`
- [ ] **Two-device manual check** (if hardware available): delete a referenced location on device A; confirm device B's referencing profile loses the reference and remains stoppable (this is the real-world proof of #216 replication). Reference `docs/sync-engine-two-device-checklist.md`.
- [ ] **Request code review before merging.** PR description notes #220 is closed as obsolete with the guard test as evidence.

## Self-review checklist (planner ran this)

- Spec coverage: #215 evaluator hardening (Task 1) + it shares the cleanup helper (Task 2); #216 local seam (Task 3) + remote seam (Task 4); #220 obsolete guard (Task 5). The shared helper (Task 2) is consumed by Tasks 3 and 4.
- No placeholders in code steps; every code step shows complete code.
- Type consistency: `removeLocationReference` returns `[UUID]`; callers use `enqueueSave(profileId:)` (local) and `pendingReenqueues` + a private `zoneID` (remote); the controller drains after both the deletions loop and the retry loop.
- Every mutating task carries an S0 conformance note (rides explicit deletion events, no inference); every task ends with a commit.
- Ordering: Task 1 (pure) and Task 2 (helper) first; Tasks 3/4 depend on Task 2; Task 5 is independent.
