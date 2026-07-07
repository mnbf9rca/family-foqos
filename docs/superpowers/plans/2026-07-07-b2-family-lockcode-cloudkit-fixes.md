# B2 Bundle — Family Lock-Code & CloudKit Sync Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix (or lock in) five epic-#263 defects in the child/parent lock-code and CloudKit-sharing surfaces — #241 (fail-safe participant deletion), #232 (transition-keyed permission-lost notification), #230 (process parent commands on child foreground), #231 (await the real authorization result), and #208 (already fixed by #271 — add a regression guard).

**Architecture:** iOS/SwiftUI app, SwiftData models with a **custom** CloudKit sync layer (SwiftData auto-CloudKit is disabled, `cloudKitDatabase: .none`). Lock codes and parent→child commands sync via `FamilyCommand`/`FamilyLockCode` records in the **shared** CloudKit database; profiles sync via `CKSyncEngine` in the **private** DB. Managers (`LockCodeManager`, `HeartbeatManager`, `CloudKitManager`, `RequestAuthorizer`, `AuthorizationVerifier`) are hard singletons/`ObservableObject`s with **no dependency-injection seam for network I/O** — so, per the pattern PR #271 established, every fix extracts its decision logic into a `nonisolated static`/pure helper and unit-tests that, rather than mocking CloudKit.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, CloudKit (`CKShare`, shared/private DB), FamilyControls (`AuthorizationCenter`), UserNotifications, XCTest.

## Global Constraints

Copied verbatim from AGENTS.md — every task's requirements implicitly include these:

- Work on a feature branch off `main`. **NEVER** amend or force-push; new commits only. Request code review before merging.
- swift-format is enforced by a pre-commit hook: **2-space indent, ~100–120 col**. Run `swift-format --in-place --recursive .` before committing.
- Views must use `@SafeQuery` (never raw `@Query`); non-query model arrays must be filtered with `.valid`.
- Lock-code restriction checks must use `appModeManager.currentMode == .child` — the pattern `!= .parent` is **forbidden** (it wrongly blocks Individual mode).
- Use `Log.<level>(_, category:)` instead of `print()`. **Never** log lock codes or personal identifiers. Profile names / UUIDs / timestamps are acceptable.
- Tests: name `testGivenX_WhenY_ThenZ()`. **Pin time** — capture one `let now = Date()` per test and derive/inject all other dates via `now:` parameters.
- Run tests against an **already-booted** simulator by **UUID** (never device name):
  `xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' | xcpretty`
- Single implementation stream per machine (no parallel builds/tests). Implement one task, review, commit, next.
- **Swift 6 / `SWIFT_STRICT_CONCURRENCY = complete`** on every target. Any protocol seam that is stored on a `@MainActor` type and awaited from a `@MainActor` method must itself be declared `@MainActor` (otherwise the non-Sendable existential is "sent" across isolation domains and fails to compile). This governs Task 4's `AuthorizationRequesting`.

---

## Re-verification Summary (handovers were dated 2026-07-02; re-grounded against `main` @ `4307654` on 2026-07-07)

**Why this section exists:** the five handovers predate B1/PR #271 (commit `ef8a0a9`), which reworked every lock-code surface. Each claim was re-traced against current code before this plan was written. Line numbers below are **current**.

| Issue | Handover claim status on current `main` | Plan decision |
|---|---|---|
| **#208** — two divergent lock-code caches | **STALE — already fixed by #271.** `fetchSharedLockCodes()` was renamed to the single-writer `refreshSharedLockCodesForVerification()` (`LockCodeManager.swift:179`); `ChildDashboardView` refresh/onAppear (`ChildDashboardView.swift:168`) and share-acceptance (`FoqosApp.swift:541`) all route through it, so a runtime refresh now updates the **verification** cache. A changed PIN is accepted after a pull-to-refresh. | **Task 5 — regression test only.** No production change. Lock in the fix so it can't regress. |
| **#230** — parent commands only at launch | **Partially stale — defect persists.** Commands now process on dashboard `onAppear`, pull-to-refresh, mode-change, and share-accept (via `refreshSharedLockCodesForVerification` → `processPendingCommands`). But **not** on plain foreground of an already-open dashboard (`FoqosApp.swift:135` scenePhase `.active` handler skips lock-code refresh) and **not** on push (no shared-DB `CKSubscription`). | **Task 3 — fix (pure-code foreground path).** Push subscription is a **maintainer decision** (see below). |
| **#232** — duplicate permission-lost notification | **Confirmed, unchanged.** `scheduleNotification(for:)` fires the immediate alert unconditionally whenever `device.isAuthRevoked` (`HeartbeatManager.swift:140–145`). `MonitoredDevice` is a **local-only** `Codable` struct (UserDefaults), not a CloudKit record — no schema impact. | **Task 2 — fix (transition-keyed dedupe).** |
| **#241** — participant deleted on unresolved `userRecordID` | **Confirmed verbatim.** `currentParticipantRecordNames` compactMaps away nil-`userRecordID` participants (`+Sharing.swift:199–201`); the removal loop (`:226–240`) then deletes their still-valid `FamilyMember`. No schema impact. | **Task 1 — fix (fail-safe keep-don't-delete).** |
| **#231** — mode committed after fixed 1s timer | **Confirmed; line numbers still accurate.** `continueWithSelectedMode()` fires an unawaited request then reads `isAuthorized` after `DispatchQueue.main.asyncAfter(1.0)` (`ModeSelectionView.swift:121,124`). `isAuthorized` is seeded from a possibly-stale pre-existing approval. No schema impact. | **Task 4 — fix (await the real result).** |

## Binding Principles (from the #203 and #261 maintainer decisions — do not violate)

1. **Gate at the initiation device; never re-gate replicated authorized operations.** #230 processes a `FamilyCommand` that a *parent* already created (an authorized operation on the parent's device). The child *applying* it is **replication**, not initiation — it is **not** re-gated, and no origin-trust metadata is added. This is the same model as the #203 delete and #261 stop decisions.
2. **Parents manage child settings physically on the child's device; the lock-code/command channel is the *existing, by-design* parent→child path** (shared-DB `FamilyCommand`). #230 fixes the *delivery latency* of an already-shipped feature — it does **not** add any new remote-management capability, gate, or trust field.
3. **No new CloudKit record types or schema without a maintainer decision.** Verified: only #230's *optional* push path would add CloudKit server config (see below). All shipped fixes are schema-neutral.

## Maintainer Decisions Surfaced

- **MD-B2-1 (#230): true push delivery via a shared-DB `CKSubscription`.** The app has **zero** shared-DB subscriptions today (the only push is the `CKSyncEngine` private-DB database subscription for profiles). Delivering `FamilyCommand`s the instant the parent taps a button — rather than on the child's next foreground/refresh — would require a **new `CKQuerySubscription`/`CKDatabaseSubscription` on the shared database** plus notification plumbing. That is CloudKit server-side config and new push infrastructure. **This plan does NOT implement it.** Task 3 ships the pure-code foreground path (no schema, no server config), which closes the reported "silently fails" gap for the realistic case (child re-foregrounds the app). If the maintainer wants zero-latency push, MD-B2-1 is a follow-up. **Recorded, not decided.**

There are **no other** maintainer decisions: #232's dedupe field lives on a local-only struct (no schema), and #241/#231/#208 add no persistence.

## File Structure

**Task 1 (#241):**
- Modify: `Foqos/CloudKit/CloudKitNetworkService+Sharing.swift` — add a `nonisolated static` pure removal-decision helper; route the removal loop through it with a fail-safe short-circuit.
- Test: `FoqosTests/ParticipantRemovalDecisionTests.swift` (new) — pure-function tests.

**Task 2 (#232):**
- Modify: `Foqos/Models/MonitoredDevice.swift` — add `authRevokedNotifiedAt` field + two pure helpers.
- Modify: `Foqos/Utils/HeartbeatManager.swift` — carry the marker across updates; gate the immediate alert on a fresh transition.
- Test: `FoqosTests/MonitoredDeviceTests.swift` (extend) — new pure-function + backward-compat cases.

**Task 3 (#230):**
- Modify: `Foqos/Utils/LockCodeManager.swift` — split `processCommand` into a testable `applyCommand`; widen `processPendingCommands` visibility to `internal`.
- Modify: `Foqos/FoqosApp.swift` — process pending commands on child foreground (scenePhase `.active`).
- Test: `FoqosTests/FamilyCommandApplyTests.swift` (new) — throttle-reset via the existing `overrideDefaults` seam.

**Task 4 (#231):**
- Create: `Foqos/Utils/AuthorizationRequesting.swift` — a one-method protocol seam + `AuthorizationCenter` conformance.
- Modify: `Foqos/Utils/RequestAuthorizer.swift` — inject the seam; make `requestAuthorization(for:)` `async -> Bool` returning the real outcome; update the no-arg overload.
- Modify: `Foqos/Views/ModeSelectionView.swift` — await the result; drop the 1s timer.
- Modify: `Foqos/Views/HomeView.swift` — wrap the fire-and-forget caller in a `Task`.
- Test: `FoqosTests/RequestAuthorizerTests.swift` (new) + `FoqosTests/Mocks/MockAuthorizationRequesting.swift` (new).

**Task 5 (#208 — regression guard, no production change):**
- Test: `FoqosTests/LockCodeChangedPinRegressionTests.swift` (new) — asserts a connected refresh adopts a changed PIN and drops the old one.

Tasks are independent and ordered by ascending risk. Each ends with an independently reviewable, testable deliverable.

---

### Task 1: #241 — Fail-safe participant deletion (keep-don't-delete on unresolved `userRecordID`)

**Files:**
- Modify: `Foqos/CloudKit/CloudKitNetworkService+Sharing.swift:195-244`
- Test: `FoqosTests/ParticipantRemovalDecisionTests.swift` (create)

**Interfaces:**
- Produces: `nonisolated static func familyMembersToRemove(from existing: [FamilyMember], acceptedParticipantRecordNames: Set<String>, hasUnresolvedAcceptedParticipant: Bool) -> [FamilyMember]` on `CloudKitNetworkService`. Returns `[]` when `hasUnresolvedAcceptedParticipant == true`; otherwise the members whose `userRecordName` is absent from `acceptedParticipantRecordNames`.
- Consumes: `FamilyMember` (`Foqos/Models/FamilyMember.swift:40`, `init(id:userRecordName:displayName:role:enrolledAt:isActive:)`), `FamilyRole` (`.parent`/`.child`).

**Context — current defect (verbatim, `+Sharing.swift:199-201, 226-240`):** `currentParticipantRecordNames` is a `Set` built by `compactMap { $0.userIdentity.userRecordID?.recordName }`, so an **accepted** participant whose `userRecordID` is transiently nil is dropped from the set. The removal loop then treats that participant's existing `FamilyMember` as "left the share" and deletes it (`try await privateDatabase.deleteRecord`). The same nil-`userRecordID` participant is *simultaneously* routed to `pending` at `:211-212` — an internal contradiction. Fail-safe fix: **skip all removals whenever any accepted participant is unresolved** (never delete on ambiguous data; legitimate cleanup defers to a sync pass where every accepted participant resolves).

- [ ] **Step 1: Write the failing test**

Create `FoqosTests/ParticipantRemovalDecisionTests.swift`:

```swift
import XCTest

@testable import FamilyFoqos

final class ParticipantRemovalDecisionTests: XCTestCase {

  private func member(_ recordName: String, _ displayName: String) -> FamilyMember {
    FamilyMember(userRecordName: recordName, displayName: displayName, role: .child)
  }

  func testGivenAllResolved_WhenMemberAbsentFromParticipants_ThenMemberRemoved() {
    let existing = [member("rec-A", "Emma"), member("rec-B", "Liam")]
    let accepted: Set<String> = ["rec-A"]  // B genuinely left the share

    let toRemove = CloudKitNetworkService.familyMembersToRemove(
      from: existing,
      acceptedParticipantRecordNames: accepted,
      hasUnresolvedAcceptedParticipant: false
    )

    XCTAssertEqual(toRemove.map { $0.userRecordName }, ["rec-B"])
  }

  func testGivenUnresolvedParticipant_WhenMemberAbsentFromParticipants_ThenNothingRemoved() {
    let existing = [member("rec-A", "Emma"), member("rec-B", "Liam")]
    let accepted: Set<String> = ["rec-A"]  // B is absent ONLY because its userRecordID is unresolved

    let toRemove = CloudKitNetworkService.familyMembersToRemove(
      from: existing,
      acceptedParticipantRecordNames: accepted,
      hasUnresolvedAcceptedParticipant: true
    )

    XCTAssertTrue(toRemove.isEmpty, "Must not delete any member while any accepted participant is unresolved")
  }

  func testGivenAllResolvedAndAllPresent_WhenNoDepartures_ThenNothingRemoved() {
    let existing = [member("rec-A", "Emma"), member("rec-B", "Liam")]
    let accepted: Set<String> = ["rec-A", "rec-B"]

    let toRemove = CloudKitNetworkService.familyMembersToRemove(
      from: existing,
      acceptedParticipantRecordNames: accepted,
      hasUnresolvedAcceptedParticipant: false
    )

    XCTAssertTrue(toRemove.isEmpty)
  }

  func testGivenNoExistingMembers_ThenNothingRemoved() {
    let toRemove = CloudKitNetworkService.familyMembersToRemove(
      from: [],
      acceptedParticipantRecordNames: [],
      hasUnresolvedAcceptedParticipant: false
    )

    XCTAssertTrue(toRemove.isEmpty)
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/ParticipantRemovalDecisionTests | xcpretty`
Expected: **FAIL** to compile — `familyMembersToRemove` does not exist yet.

- [ ] **Step 3: Add the pure decision helper**

In `Foqos/CloudKit/CloudKitNetworkService+Sharing.swift`, add near the top of the extension (above `syncShareParticipantsToFamilyMembers`, keeping it in the same file so it lives with its caller):

```swift
  /// Decide which existing FamilyMembers to remove after a share-participant sync.
  ///
  /// FAIL-SAFE (#241): when ANY accepted participant has an unresolved userRecordID,
  /// `acceptedParticipantRecordNames` is incomplete, so a still-enrolled member could look
  /// "departed". In that case we remove NOTHING and let a later sync — where every accepted
  /// participant has resolved — perform legitimate cleanup. We never delete on ambiguous data.
  nonisolated static func familyMembersToRemove(
    from existing: [FamilyMember],
    acceptedParticipantRecordNames: Set<String>,
    hasUnresolvedAcceptedParticipant: Bool
  ) -> [FamilyMember] {
    guard !hasUnresolvedAcceptedParticipant else { return [] }
    return existing.filter { !acceptedParticipantRecordNames.contains($0.userRecordName) }
  }
```

- [ ] **Step 4: Route the removal loop through the helper**

In `syncShareParticipantsToFamilyMembers`, replace the removal loop (current `:225-240`) so it consults the fail-safe helper. Edit from:

```swift
    // Remove FamilyMembers who are no longer accepted participants
    for member in familyMembers {
      let userRecordName = member.userRecordName

      if !currentParticipantRecordNames.contains(userRecordName) {
        do {
          let recordID = CKRecord.ID(recordName: member.id.uuidString, zoneID: policyZoneID)
          try await privateDatabase.deleteRecord(withID: recordID)
          familyMembers.removeAll { $0.id == member.id }
          Log.info(
            "Removed FamilyMember who left share: \(member.displayName)", category: .cloudKit)
        } catch {
          Log.error("Failed to remove stale FamilyMember: \(error)", category: .cloudKit)
        }
      }
    }
```

to:

```swift
    // Remove FamilyMembers who are no longer accepted participants.
    // FAIL-SAFE (#241): skip ALL removals when any accepted participant is unresolved, so a
    // transient nil userRecordID can't delete a still-enrolled child.
    let hasUnresolvedAcceptedParticipant = acceptedParticipants.contains {
      $0.userIdentity.userRecordID == nil
    }
    if hasUnresolvedAcceptedParticipant {
      Log.info(
        "Skipping FamilyMember cleanup: an accepted participant has an unresolved identity",
        category: .cloudKit)
    }
    let membersToRemove = Self.familyMembersToRemove(
      from: familyMembers,
      acceptedParticipantRecordNames: currentParticipantRecordNames,
      hasUnresolvedAcceptedParticipant: hasUnresolvedAcceptedParticipant
    )
    for member in membersToRemove {
      do {
        let recordID = CKRecord.ID(recordName: member.id.uuidString, zoneID: policyZoneID)
        try await privateDatabase.deleteRecord(withID: recordID)
        familyMembers.removeAll { $0.id == member.id }
        Log.info(
          "Removed FamilyMember who left share: \(member.displayName)", category: .cloudKit)
      } catch {
        Log.error("Failed to remove stale FamilyMember: \(error)", category: .cloudKit)
      }
    }
```

(`acceptedParticipants` is already in scope at `:195`; `currentParticipantRecordNames` at `:199`; `policyZoneID`/`privateDatabase` unchanged.)

- [ ] **Step 5: Run the test to verify it passes**

Run: `xcodebuild test ... -only-testing:FoqosTests/ParticipantRemovalDecisionTests | xcpretty`
Expected: **PASS** (4 tests).

- [ ] **Step 6: Format and commit**

```bash
swift-format --in-place Foqos/CloudKit/CloudKitNetworkService+Sharing.swift FoqosTests/ParticipantRemovalDecisionTests.swift
git add Foqos/CloudKit/CloudKitNetworkService+Sharing.swift FoqosTests/ParticipantRemovalDecisionTests.swift
git commit -m "Fix #241: fail-safe FamilyMember removal on unresolved participant identity"
```

---

### Task 2: #232 — Transition-keyed "Screen Time Permissions Lost" notification (dedupe on approved→denied, not on delivery)

**Files:**
- Modify: `Foqos/Models/MonitoredDevice.swift:5-28`
- Modify: `Foqos/Utils/HeartbeatManager.swift:131-204`
- Test: `FoqosTests/MonitoredDeviceTests.swift` (extend)

**Interfaces:**
- Produces on `MonitoredDevice`: stored `var authRevokedNotifiedAt: Date?`; `func shouldScheduleAuthRevokedAlert() -> Bool` (`isAuthRevoked && authRevokedNotifiedAt == nil`); `nonisolated static func carriedAuthRevokedNotifiedAt(previous: Date?, newStatus: String?) -> Date?` (preserve `previous` while `newStatus == "denied"`, else `nil` to re-arm).
- Consumes: existing `isAuthRevoked` (`authorizationStatus == "denied"`), `updateOrCreateDevice(from:)`, `scheduleNotification(for:)`.

**Context — current defect (`HeartbeatManager.swift:140-145`):** the `if device.isAuthRevoked` branch always sets `triggerDate = Date().addingTimeInterval(1)` and adds a fresh `UNNotificationRequest`. `refreshHeartbeats()` runs on every parent-mode CloudKit push (`FoqosApp.swift:384`) and every `ParentDashboardView` `.task`/pull-to-refresh (`ParentDashboardView.swift:802`); `cancelNotification` only clears *pending* requests, so the already-delivered 1-second alert can't be suppressed and re-delivers every refresh. The **only** place the approved→denied transition is observable is `updateOrCreateDevice(from:)` (`:184-204`), which currently overwrites `authorizationStatus` at `:191`. Dedupe must key on that transition: alert once on entry to `denied`, stay silent while `denied`, re-arm when it returns to `approved`.

- [ ] **Step 1: Write the failing tests**

Append to `FoqosTests/MonitoredDeviceTests.swift` (before the closing `}`):

```swift
  // MARK: - #232 auth-revoked notification dedupe (transition-keyed)

  func testShouldScheduleAuthRevokedAlert_trueWhenRevokedAndNeverNotified() {
    let device = MonitoredDevice(
      deviceIdentifier: "dev1", deviceName: "iPhone", childUserRecordName: "child1",
      lastSeenAt: Date(), isSuppressed: false, notificationIdentifier: nil,
      authorizationStatus: "denied", authRevokedNotifiedAt: nil
    )
    XCTAssertTrue(device.shouldScheduleAuthRevokedAlert())
  }

  func testShouldScheduleAuthRevokedAlert_falseWhenAlreadyNotified() {
    let now = Date()
    let device = MonitoredDevice(
      deviceIdentifier: "dev1", deviceName: "iPhone", childUserRecordName: "child1",
      lastSeenAt: now, isSuppressed: false, notificationIdentifier: nil,
      authorizationStatus: "denied", authRevokedNotifiedAt: now
    )
    XCTAssertFalse(device.shouldScheduleAuthRevokedAlert())
  }

  func testShouldScheduleAuthRevokedAlert_falseWhenApproved() {
    let device = MonitoredDevice(
      deviceIdentifier: "dev1", deviceName: "iPhone", childUserRecordName: "child1",
      lastSeenAt: Date(), isSuppressed: false, notificationIdentifier: nil,
      authorizationStatus: "approved", authRevokedNotifiedAt: nil
    )
    XCTAssertFalse(device.shouldScheduleAuthRevokedAlert())
  }

  func testCarriedAuthRevokedNotifiedAt_preservesMarkerWhileStillDenied() {
    let now = Date()
    let carried = MonitoredDevice.carriedAuthRevokedNotifiedAt(previous: now, newStatus: "denied")
    XCTAssertEqual(carried, now)
  }

  func testCarriedAuthRevokedNotifiedAt_clearsMarkerWhenBackToApproved() {
    let now = Date()
    let carried = MonitoredDevice.carriedAuthRevokedNotifiedAt(previous: now, newStatus: "approved")
    XCTAssertNil(carried, "Re-arm so a genuine re-revocation alerts again")
  }

  func testCarriedAuthRevokedNotifiedAt_clearsMarkerWhenStatusNil() {
    let now = Date()
    XCTAssertNil(MonitoredDevice.carriedAuthRevokedNotifiedAt(previous: now, newStatus: nil))
  }

  func testPersistence_backwardsCompatible_missingAuthRevokedNotifiedAt() throws {
    // A device saved before authRevokedNotifiedAt existed must decode with the field nil.
    let json = """
      {"deviceIdentifier":"dev1","deviceName":"iPhone","childUserRecordName":"child1",
       "lastSeenAt":1000000,"isSuppressed":false,"authorizationStatus":"denied"}
      """
    let data = json.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(MonitoredDevice.self, from: data)

    XCTAssertNil(decoded.authRevokedNotifiedAt)
    XCTAssertTrue(decoded.shouldScheduleAuthRevokedAlert(), "Legacy denied device alerts once")
  }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test ... -only-testing:FoqosTests/MonitoredDeviceTests | xcpretty`
Expected: **FAIL** to compile — `authRevokedNotifiedAt`, `shouldScheduleAuthRevokedAlert`, `carriedAuthRevokedNotifiedAt` do not exist.

- [ ] **Step 3: Add the field and pure helpers to `MonitoredDevice`**

Edit `Foqos/Models/MonitoredDevice.swift`. Add the stored property after `authorizationStatus` (`:13`), matching the existing
no-explicit-default style of `authorizationStatus`:

```swift
  var authorizationStatus: String?
  /// #232: timestamp when the parent was alerted about this device's revoked authorization.
  /// nil ⇒ not yet alerted for the current revocation. Cleared when auth returns to approved,
  /// so a genuine re-revocation alerts again. Optional ⇒ backward-compatible decode.
  var authRevokedNotifiedAt: Date?
```

**Memberwise initializer:** no change needed. An optional stored property receives an implicit
`nil` default in Swift's synthesized memberwise initializer (which is why the existing
`MonitoredDeviceTests` constructors already omit `authorizationStatus`). Existing call sites —
including `HeartbeatManager.updateOrCreateDevice`'s new-device branch (`:193-201`) and every
test that omits the field — keep compiling unchanged, and the new tests may still pass
`authRevokedNotifiedAt:` explicitly.

Add the two helpers alongside `isAuthRevoked`/`shouldAlert`:

```swift
  /// #232: alert on the approved→denied TRANSITION only — once per revocation, not per refresh.
  func shouldScheduleAuthRevokedAlert() -> Bool {
    isAuthRevoked && authRevokedNotifiedAt == nil
  }

  /// #232: carry the "already alerted" marker across a heartbeat update. Preserve it while the
  /// device stays denied; clear it (re-arm) the moment it is no longer denied.
  nonisolated static func carriedAuthRevokedNotifiedAt(previous: Date?, newStatus: String?) -> Date? {
    newStatus == "denied" ? previous : nil
  }
```

**Note on the memberwise initializer:** `MonitoredDevice` uses the compiler-synthesized memberwise init. Because `authRevokedNotifiedAt` has a default (`= Date?.none` is not written, so give it a default to keep existing call sites compiling). Change the declaration to:

```swift
  var authRevokedNotifiedAt: Date? = nil
```

so existing constructors (`HeartbeatManager.updateOrCreateDevice` new-device branch, and every `MonitoredDeviceTests` call that omits it) keep working, and the new tests can still pass it explicitly.

- [ ] **Step 4: Carry the marker across updates and gate the alert in `HeartbeatManager`**

Edit `Foqos/Utils/HeartbeatManager.swift`. In `updateOrCreateDevice(from:)` existing-device branch (`:189-191`), compute the carried marker **before** overwriting `authorizationStatus`:

```swift
    if let index = monitoredDevices.firstIndex(where: {
      $0.childUserRecordName == heartbeat.childUserRecordName
        && $0.deviceIdentifier == heartbeat.deviceIdentifier
    }) {
      monitoredDevices[index].lastSeenAt = heartbeat.lastHeartbeatAt
      monitoredDevices[index].deviceName = heartbeat.deviceName
      // #232: re-arm the alert marker if auth is no longer denied; preserve it while still denied.
      monitoredDevices[index].authRevokedNotifiedAt = MonitoredDevice.carriedAuthRevokedNotifiedAt(
        previous: monitoredDevices[index].authRevokedNotifiedAt,
        newStatus: heartbeat.authorizationStatus)
      monitoredDevices[index].authorizationStatus = heartbeat.authorizationStatus
    } else {
      // new-device branch unchanged — authRevokedNotifiedAt defaults to nil, so a brand-new
      // already-denied device alerts once.
      ...
    }
```

In `scheduleNotification(for:)` (`:131-174`), gate the immediate revoked alert on a fresh transition and mark it once scheduled. Replace the `if device.isAuthRevoked { ... }` branch (`:140-145`) and extend the trailing index block (`:167-173`):

```swift
    let triggerDate: Date
    var markAuthRevokedNotified = false

    if device.isAuthRevoked {
      // #232: only alert on the approved→denied transition, not on every refresh.
      guard device.shouldScheduleAuthRevokedAlert() else { return }
      content.title = "Screen Time Permissions Lost"
      content.body =
        "\(device.deviceName) has lost Screen Time permissions. Tap to review."
      triggerDate = Date().addingTimeInterval(1)
      markAuthRevokedNotified = true
    } else {
      content.title = "Device Check-In"
      content.body =
        "We haven't heard from \(device.deviceName) in a while. Tap to check their status."
      triggerDate = device.lastSeenAt.addingTimeInterval(MonitoredDevice.stalenessThreshold)
    }

    guard triggerDate > Date() else { return }
    // ... unchanged trigger/request/add ...

    if let index = monitoredDevices.firstIndex(where: { $0.id == device.id }) {
      monitoredDevices[index].notificationIdentifier = notificationId
      if markAuthRevokedNotified {
        monitoredDevices[index].authRevokedNotifiedAt = Date()
      }
      saveDevices()
    }
```

**Do not change** the staleness branch or `shouldAlert`. `refreshHeartbeats()` still calls `scheduleNotifications()` every invocation — that is fine now, because the `guard device.shouldScheduleAuthRevokedAlert()` early-return makes re-scheduling a no-op after the first alert.

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test ... -only-testing:FoqosTests/MonitoredDeviceTests | xcpretty`
Expected: **PASS** (original 12 + 7 new = 19 tests).

- [ ] **Step 6: Format and commit**

```bash
swift-format --in-place Foqos/Models/MonitoredDevice.swift Foqos/Utils/HeartbeatManager.swift FoqosTests/MonitoredDeviceTests.swift
git add Foqos/Models/MonitoredDevice.swift Foqos/Utils/HeartbeatManager.swift FoqosTests/MonitoredDeviceTests.swift
git commit -m "Fix #232: dedupe permission-lost notification on approved->denied transition"
```

> **Manual/integration verification (record in the PR):** `HeartbeatManager`'s wiring (the
> `guard shouldScheduleAuthRevokedAlert()` gate and the `carriedAuthRevokedNotifiedAt` carry) has
> no unit test because the manager has no CloudKit/notification DI seam — only the pure
> `MonitoredDevice` helpers are unit-tested. On device: with a child reporting `denied`, confirm
> the parent gets the "Screen Time Permissions Lost" banner exactly **once**, that repeated
> dashboard pull-to-refresh and pushes do **not** re-alert, and that a child returning to
> `approved` then `denied` again re-alerts once.

---

### Task 3: #230 — Process pending parent commands on child foreground

**Files:**
- Modify: `Foqos/Utils/LockCodeManager.swift:302-343`
- Modify: `Foqos/FoqosApp.swift:137-145`
- Test: `FoqosTests/FamilyCommandApplyTests.swift` (create)

**Interfaces:**
- Produces on `LockCodeManager`: `func applyCommand(_ command: FamilyCommand)` (internal, `@MainActor`) — applies the local side effect (`resetThrottle()` / `EmergencyUnblockManager.shared.resetEmergencyUnblocks()`) with **no** CloudKit delete; `func processPendingCommands() async` widened from `private` to internal.
- Consumes: existing `resetThrottle()` (`:` throttle seam), `overrideDefaults(_:)`, `recordFailedAttempt(now:)`, `isLockedOut(now:)`, `failedAttempts`; `FamilyCommand(commandType:targetChildId:createdBy:)`.

**Context — corrected current truth:** commands ARE processed on dashboard `onAppear`, pull-to-refresh, mode-change, and share-accept (all via `refreshSharedLockCodesForVerification()` → `processPendingCommands()`, `LockCodeManager.swift:211`). The residual gap: the scenePhase `.active` handler (`FoqosApp.swift:137`) does **not** refresh lock codes, so a parent's "Reset PIN Attempts" tap has no effect while the child app is foregrounded **without re-opening the dashboard**. This task adds a child-guarded command-processing call to that handler. (True push — MD-B2-1 — is out of scope; without a shared-DB subscription the `didReceiveRemoteNotification` handler at `FoqosApp.swift:362` never receives a `FamilyCommand` push, so wiring it there would be dead code.) Applying a parent-authored command on the child is **replication of an authorized operation** (Binding Principle 1) — not re-gated, no trust metadata.

- [ ] **Step 1: Write the failing test**

Create `FoqosTests/FamilyCommandApplyTests.swift`:

```swift
import XCTest

@testable import FamilyFoqos

@MainActor
final class FamilyCommandApplyTests: XCTestCase {

  override func setUp() {
    super.setUp()
    MainActor.assumeIsolated {
      let defaults = UserDefaults(suiteName: "FamilyCommandApplyTests")!
      defaults.removePersistentDomain(forName: "FamilyCommandApplyTests")
      LockCodeManager.shared.overrideDefaults(defaults)
      LockCodeManager.shared.resetThrottle()
    }
  }

  override func tearDown() {
    MainActor.assumeIsolated {
      LockCodeManager.shared.resetThrottle()
      LockCodeManager.shared.overrideDefaults(nil)
    }
    super.tearDown()
  }

  func testGivenLockedOutChild_WhenResetThrottleCommandApplied_ThenThrottleCleared() {
    let now = Date()
    for _ in 0..<10 {
      LockCodeManager.shared.recordFailedAttempt(now: now)
    }
    XCTAssertTrue(LockCodeManager.shared.isLockedOut(now: now))

    let command = FamilyCommand(
      commandType: .resetLockCodeThrottle,
      targetChildId: "child-rec-1",
      createdBy: "parent-rec-1"
    )
    LockCodeManager.shared.applyCommand(command)

    XCTAssertEqual(LockCodeManager.shared.failedAttempts, 0)
    XCTAssertFalse(LockCodeManager.shared.isLockedOut(now: now))
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test ... -only-testing:FoqosTests/FamilyCommandApplyTests | xcpretty`
Expected: **FAIL** to compile — `applyCommand` does not exist.

- [ ] **Step 3: Split `processCommand` into a testable `applyCommand`**

Edit `Foqos/Utils/LockCodeManager.swift`. Replace `processCommand(_:)` (`:325-343`) with a side-effect-only `applyCommand` plus a thin `processCommand` that also deletes remotely:

```swift
  /// Apply a parent command's LOCAL side effect. No CloudKit I/O — unit-testable.
  /// Replication of a parent-authorized operation (#230); not re-gated on the child.
  func applyCommand(_ command: FamilyCommand) {
    Log.info("Applying command: \(command.commandType.rawValue)", category: .cloudKit)
    switch command.commandType {
    case .resetEmergencyCount:
      EmergencyUnblockManager.shared.resetEmergencyUnblocks()
      Log.info("Emergency count reset by parent", category: .cloudKit)
    case .resetLockCodeThrottle:
      resetThrottle()
      Log.info("Lock code throttle reset by parent", category: .cloudKit)
    }
  }

  private func processCommand(_ command: FamilyCommand) async {
    applyCommand(command)

    // Delete the command after processing
    do {
      try await cloudKitManager.deleteCommand(command)
    } catch {
      Log.error("Failed to delete processed command: \(error)", category: .cloudKit)
    }
  }
```

Widen `processPendingCommands` visibility (`:306`) from `private func` to `func` (internal) so `FoqosApp` can call it — the existing `guard appModeManager.currentMode == .child` stays, so it self-guards:

```swift
  /// Check for and process any pending commands from parent.
  /// Called from the child lock-code refresh and on child foreground (#230).
  func processPendingCommands() async {
    guard appModeManager.currentMode == .child else { return }
    ...
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test ... -only-testing:FoqosTests/FamilyCommandApplyTests | xcpretty`
Expected: **PASS** (1 test).

- [ ] **Step 5: Wire child foreground command processing in `FoqosApp`**

Edit `Foqos/FoqosApp.swift`, inside the `if newPhase == .active` block (`:137-145`), extend the first `Task` so a child device drains pending commands on every foreground:

```swift
          if newPhase == .active {
            Task {
              await CloudKitManager.shared.checkAccountStatus()
              await CloudKitManager.shared.verifySelfFamilyMemberRecord()
              verifyChildAuthorizationIfNeeded()
              // #230: process parent commands (reset PIN attempts / emergency count) on child
              // foreground, so a rescue takes effect without re-opening the dashboard.
              if AppModeManager.shared.currentMode == .child {
                await LockCodeManager.shared.processPendingCommands()
              }
            }
            ...
          }
```

(No other call site changes — `refreshSharedLockCodesForVerification()` still calls `processPendingCommands()` internally on dashboard refresh; this is idempotent because processed commands are deleted server-side.)

- [ ] **Step 6: Build to verify the wiring compiles, then commit**

Run: `xcodebuild test ... -only-testing:FoqosTests/FamilyCommandApplyTests | xcpretty` (compiles the app target + runs the unit test).
Expected: **PASS**, build succeeds.

```bash
swift-format --in-place Foqos/Utils/LockCodeManager.swift Foqos/FoqosApp.swift FoqosTests/FamilyCommandApplyTests.swift
git add Foqos/Utils/LockCodeManager.swift Foqos/FoqosApp.swift FoqosTests/FamilyCommandApplyTests.swift
git commit -m "Fix #230: process pending parent commands on child foreground"
```

> **Manual/integration verification (record in the PR):** With a paired parent+child on a device: lock the child out (10 wrong PINs), background the child app *without* leaving the dashboard focus, tap "Reset PIN Attempts" on the parent, then foreground the child — the lockout clears without re-opening the dashboard. (Zero-latency-while-foregrounded push is MD-B2-1, not shipped here.)

---

### Task 4: #231 — Await the real authorization result instead of a fixed 1-second timer

**Files:**
- Create: `Foqos/Utils/AuthorizationRequesting.swift`
- Modify: `Foqos/Utils/RequestAuthorizer.swift:7-71`
- Modify: `Foqos/Views/ModeSelectionView.swift:117-134`
- Modify: `Foqos/Views/HomeView.swift:150-152`
- Create: `FoqosTests/Mocks/MockAuthorizationRequesting.swift`
- Create: `FoqosTests/RequestAuthorizerTests.swift`

**Interfaces:**
- Produces: `protocol AuthorizationRequesting { func requestAuthorization(for member: FamilyControlsMember) async throws }` with `extension AuthorizationCenter: AuthorizationRequesting {}`. `RequestAuthorizer.init(authorizationCenter: AuthorizationRequesting = AuthorizationCenter.shared)`. `func requestAuthorization(for mode: AppMode) async -> Bool` (returns the real outcome, sets `authorizationError` on failure). `func requestAuthorization() async -> Bool` (no-arg overload).
- Consumes: `AppMode` (`.individual`/`.parent`/`.child`), `FamilyControlsMember` (`.individual`/`.child`), `AppModeManager.selectMode(_:)`, `describeAuthorizationError(_:for:)`.

**Context — current defect (`ModeSelectionView.swift:117-134`, `RequestAuthorizer.swift:46-71`):** `requestAuthorization(for:)` wraps the async `AuthorizationCenter` call in an **unawaited** `Task` and returns `Void`; `continueWithSelectedMode()` reads `requestAuthorizer.isAuthorized` after a hard-coded `DispatchQueue.main.asyncAfter(1.0)`. On a fresh device the system consent flow is still up at +1s (neither branch runs — silent no-op); on a device with a stale pre-existing approval, `isAuthorized` was seeded `true` at init (`RequestAuthorizer.swift:15-18`), so `.child` mode commits even when the pending `.child` request later fails. Fix: make the request `async` and **return the current request's outcome**; the caller awaits it and commits mode only on `true`. The returned `Bool` (not re-reading `@Published isAuthorized`) is essential — otherwise the stale-approval race just moves.

- [ ] **Step 1: Write the failing tests**

Create `FoqosTests/Mocks/MockAuthorizationRequesting.swift`:

```swift
import FamilyControls

@testable import FamilyFoqos

/// Test double for the AuthorizationCenter request seam. `@MainActor` to match the
/// `@MainActor` protocol (see Task 4 Step 3) — no `@unchecked Sendable` needed.
@MainActor
final class MockAuthorizationRequesting: AuthorizationRequesting {
  enum Outcome {
    case success
    case failure(Error)
  }

  var outcome: Outcome = .success
  private(set) var requestedMembers: [FamilyControlsMember] = []

  struct StubError: Error {}

  func requestAuthorization(for member: FamilyControlsMember) async throws {
    requestedMembers.append(member)
    if case .failure(let error) = outcome {
      throw error
    }
  }
}
```

Create `FoqosTests/RequestAuthorizerTests.swift`:

```swift
import FamilyControls
import XCTest

@testable import FamilyFoqos

@MainActor
final class RequestAuthorizerTests: XCTestCase {

  func testGivenAuthApproved_WhenRequestingChild_ThenReturnsTrueAndClearsError() async {
    let mock = MockAuthorizationRequesting()
    mock.outcome = .success
    let authorizer = RequestAuthorizer(authorizationCenter: mock)

    let result = await authorizer.requestAuthorization(for: .child)

    XCTAssertTrue(result)
    XCTAssertNil(authorizer.authorizationError)
    XCTAssertEqual(mock.requestedMembers, [.child])
  }

  func testGivenAuthFails_WhenRequestingChild_ThenReturnsFalseAndSetsError() async {
    let mock = MockAuthorizationRequesting()
    mock.outcome = .failure(MockAuthorizationRequesting.StubError())
    let authorizer = RequestAuthorizer(authorizationCenter: mock)

    let result = await authorizer.requestAuthorization(for: .child)

    XCTAssertFalse(result, "A failed request must NOT report success (no premature mode commit)")
    XCTAssertNotNil(authorizer.authorizationError)
  }

  func testGivenParentMode_WhenRequesting_ThenUsesIndividualMember() async {
    let mock = MockAuthorizationRequesting()
    let authorizer = RequestAuthorizer(authorizationCenter: mock)

    _ = await authorizer.requestAuthorization(for: .parent)

    XCTAssertEqual(mock.requestedMembers, [.individual])
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test ... -only-testing:FoqosTests/RequestAuthorizerTests | xcpretty`
Expected: **FAIL** to compile — `AuthorizationRequesting`, the injected init, and the `async -> Bool` signature don't exist.

- [ ] **Step 3: Add the protocol seam**

Create `Foqos/Utils/AuthorizationRequesting.swift`:

```swift
import FamilyControls

/// Seam over AuthorizationCenter's async request, so RequestAuthorizer is unit-testable
/// and can await the real outcome instead of polling shared state (#231).
///
/// `@MainActor` is REQUIRED: the project builds with `SWIFT_STRICT_CONCURRENCY = complete`
/// (Swift 6). `RequestAuthorizer` is `@MainActor` and stores this seam as a non-Sendable
/// existential; awaiting a *nonisolated* requirement from a `@MainActor` method would "send"
/// that main-isolated value across isolation domains and fail to compile. Marking the
/// requirement `@MainActor` keeps the call main-isolated. `AuthorizationCenter`'s method is
/// nonisolated `async throws`, and a nonisolated witness legally satisfies a `@MainActor`
/// requirement, so the empty conformance below still compiles with no stubs and the actual
/// request work still runs off the main actor exactly as today.
@MainActor
protocol AuthorizationRequesting {
  func requestAuthorization(for member: FamilyControlsMember) async throws
}

extension AuthorizationCenter: AuthorizationRequesting {}
```

- [ ] **Step 4: Inject the seam and make the request async-returning-Bool**

Edit `Foqos/Utils/RequestAuthorizer.swift`. Add the stored dependency and initializer parameter (keep the live Combine binding on the real `AuthorizationCenter.shared`, which drives UI state):

```swift
  private var cancellable: AnyCancellable?
  private let authorizationCenter: AuthorizationRequesting

  init(authorizationCenter: AuthorizationRequesting = AuthorizationCenter.shared) {
    self.authorizationCenter = authorizationCenter
    let status = AuthorizationCenter.shared.authorizationStatus
    ...  // rest of init unchanged
  }
```

Replace both `requestAuthorization` methods (`:40-71`):

```swift
  /// Request authorization for the current app mode. Returns true iff the request succeeded.
  @discardableResult
  func requestAuthorization() async -> Bool {
    await requestAuthorization(for: AppModeManager.shared.currentMode)
  }

  /// Request authorization for a specific app mode and AWAIT the real result (#231).
  /// Returns true on success; on failure returns false and publishes authorizationError.
  @discardableResult
  func requestAuthorization(for mode: AppMode) async -> Bool {
    let member: FamilyControlsMember = (mode == .child) ? .child : .individual
    do {
      try await authorizationCenter.requestAuthorization(for: member)
      Log.info("Authorization successful for mode: \(mode)", category: .authorization)
      self.isAuthorized = true
      self.authorizationError = nil
      return true
    } catch {
      Log.info("Error requesting authorization: \(error)", category: .authorization)
      self.isAuthorized = false
      self.authorizationError = self.describeAuthorizationError(error, for: mode)
      return false
    }
  }
```

(`isAuthorized`/`authorizationStatus` are `@Published private(set)`; the class is `@MainActor`, so these assignments are already main-isolated. `describeAuthorizationError` is unchanged.)

- [ ] **Step 5: Await the result in `ModeSelectionView`; drop the 1s timer**

Edit `Foqos/Views/ModeSelectionView.swift`. Replace `continueWithSelectedMode()` (`:117-134`):

```swift
  private func continueWithSelectedMode() {
    isAuthorizing = true
    Task {
      let authorized = await requestAuthorizer.requestAuthorization(for: selectedMode)
      if authorized {
        appModeManager.selectMode(selectedMode)
        onModeSelected(selectedMode)
      } else if let error = requestAuthorizer.authorizationError {
        errorMessage = error
        showError = true
      }
      isAuthorizing = false
    }
  }
```

(The `Button(action: continueWithSelectedMode)` at `:61` stays synchronous — it now spawns the awaiting `Task`. `isAuthorizing` gates the button `.disabled(isAuthorizing)` at `:77`.)

- [ ] **Step 6: Update the remaining caller in `HomeView`**

Edit `Foqos/Views/HomeView.swift:150-152`. The no-arg overload is now `async`; wrap the fire-and-forget call:

```swift
          onAuthorizationHandler: {
            Task { await requestAuthorizer.requestAuthorization() }
          }
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `xcodebuild test ... -only-testing:FoqosTests/RequestAuthorizerTests | xcpretty`
Expected: **PASS** (3 tests).

- [ ] **Step 8: Format and commit**

```bash
swift-format --in-place Foqos/Utils/AuthorizationRequesting.swift Foqos/Utils/RequestAuthorizer.swift Foqos/Views/ModeSelectionView.swift Foqos/Views/HomeView.swift FoqosTests/Mocks/MockAuthorizationRequesting.swift FoqosTests/RequestAuthorizerTests.swift
git add Foqos/Utils/AuthorizationRequesting.swift Foqos/Utils/RequestAuthorizer.swift Foqos/Views/ModeSelectionView.swift Foqos/Views/HomeView.swift FoqosTests/Mocks/MockAuthorizationRequesting.swift FoqosTests/RequestAuthorizerTests.swift
git commit -m "Fix #231: await real authorization result before committing app mode"
```

---

### Task 5: #208 — Regression guard (already fixed by #271; lock it in)

**Files:**
- Test: `FoqosTests/LockCodeChangedPinRegressionTests.swift` (create)

**Interfaces:**
- Consumes: `LockCodeManager.resolveLockCodes(fetched:isConnected:persisted:)` (`:226`), `LockCodeManager.verifyCode(_:forChildId:mode:authorizationType:codes:)` (`:236`), `FamilyLockCode(code:scope:)`.

**Context:** #208 (child keeps accepting the old PIN after a parent change) was closed by #271, which made `refreshSharedLockCodesForVerification()` the single writer of the verification cache and routed all runtime refresh paths through it. The mechanism that guarantees a changed PIN is adopted on a **connected** refresh is the pure `resolveLockCodes` resolver: a connected fetch replaces both the cache and the persisted store (even when the fetched set changed). This task adds a regression test that encodes the #208 contract at that pure seam — no production change. (The deliberate #197 offline behavior — a disconnected fetch keeps the last-synced codes — is *correct*, not the #208 bug, and is asserted here so a future change can't conflate the two.)

- [ ] **Step 1: Write the regression test**

Create `FoqosTests/LockCodeChangedPinRegressionTests.swift`:

```swift
import XCTest

@testable import FamilyFoqos

@MainActor
final class LockCodeChangedPinRegressionTests: XCTestCase {

  private let oldPin = "1234"
  private let newPin = "5678"
  private let childId = "child-device-001"

  private func code(_ pin: String) -> FamilyLockCode {
    FamilyLockCode(code: pin, scope: .allChildren)
  }

  /// #208: on a CONNECTED refresh, a parent's changed PIN replaces the child's verification
  /// cache — the old PIN must stop verifying and the new PIN must start verifying.
  func testGivenConnectedRefreshWithChangedPin_ThenNewCodeAdoptedAndOldDropped() {
    let resolved = LockCodeManager.resolveLockCodes(
      fetched: [code(newPin)],
      isConnected: true,
      persisted: [code(oldPin)]
    )

    XCTAssertTrue(
      LockCodeManager.verifyCode(
        newPin, forChildId: childId, mode: .child,
        authorizationType: .child, codes: resolved.cache),
      "New PIN must verify after a connected refresh")
    XCTAssertFalse(
      LockCodeManager.verifyCode(
        oldPin, forChildId: childId, mode: .child,
        authorizationType: .child, codes: resolved.cache),
      "Revoked old PIN must NOT verify after a connected refresh")
  }

  /// #197 (deliberate, NOT the #208 bug): a DISCONNECTED refresh keeps the last-synced codes,
  /// so the child can still verify offline. A changed PIN only propagates once connected.
  func testGivenDisconnectedRefresh_ThenLastSyncedCodesRetained() {
    let resolved = LockCodeManager.resolveLockCodes(
      fetched: [],
      isConnected: false,
      persisted: [code(oldPin)]
    )

    XCTAssertTrue(
      LockCodeManager.verifyCode(
        oldPin, forChildId: childId, mode: .child,
        authorizationType: .child, codes: resolved.cache),
      "Offline, the last-synced PIN must still verify (fail-closed-with-cache)")
  }
}
```

- [ ] **Step 2: Run the test to verify it passes immediately (no production change needed)**

Run: `xcodebuild test ... -only-testing:FoqosTests/LockCodeChangedPinRegressionTests | xcpretty`
Expected: **PASS** (2 tests) — confirming #208 is already fixed and now guarded.

- [ ] **Step 3: Commit**

```bash
swift-format --in-place FoqosTests/LockCodeChangedPinRegressionTests.swift
git add FoqosTests/LockCodeChangedPinRegressionTests.swift
git commit -m "Test #208: regression guard for changed-PIN adoption on connected refresh"
```

---

## Final Verification (run once, after all tasks)

- [ ] Boot the simulator **once** by UUID; run the full suite:
  `xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' | xcpretty`
  Expected: all pre-existing tests plus the new ones green (0 failures).
- [ ] `swift-format lint --recursive .` — clean.
- [ ] Request code review before merge (AGENTS.md requirement).

## Self-Review (performed against the five handovers + re-grounding, 2026-07-07)

1. **Spec coverage:** #241 → Task 1; #232 → Task 2; #230 → Task 3; #231 → Task 4; #208 → Task 5. All five bundle issues have a task. MD-B2-1 (push subscription) is explicitly recorded as out-of-scope maintainer follow-up.
2. **Placeholder scan:** no `TBD`/`handle edge cases`/`add validation`/`similar to Task N` — every code and test step carries complete, current-signature code.
3. **Type consistency:** `familyMembersToRemove` (Task 1), `authRevokedNotifiedAt`/`shouldScheduleAuthRevokedAlert`/`carriedAuthRevokedNotifiedAt` (Task 2), `applyCommand`/`processPendingCommands` (Task 3), `AuthorizationRequesting`/`requestAuthorization(for:) async -> Bool` (Task 4), `resolveLockCodes`/static `verifyCode` (Task 5) — names and signatures match their definitions and every call site. `FamilyMember`, `FamilyCommand`, `FamilyLockCode`, `MonitoredDevice`, `FamilyControlsMember` initializers/cases verified against current `main`.
4. **Binding-principle compliance:** no new gate, trust field, or remote-management surface. #230 replicates an already-authorized parent command on the child; the fix is delivery-latency only.
5. **Schema neutrality:** only #230's *optional* push path (MD-B2-1) would touch CloudKit config, and it is not implemented. All shipped changes are local/pure.

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-07-07-b2-family-lockcode-cloudkit-fixes.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — execute tasks in this session using executing-plans, batch execution with checkpoints.

**Which approach?** (Implementation is a separate session per project convention — this PR is plan-only.)
