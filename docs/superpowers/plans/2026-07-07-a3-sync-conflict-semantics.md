# A3′ — Sync Conflict Semantics Implementation Plan (#218, #221, #265, #222)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. This plan is **self-contained** — it assumes no prior Claude session/project memory (the implementer may be Codex). Read `AGENTS.md` at the repo root first; it overrides everything here.

**Goal:** Make the post-S0 CKSyncEngine sync layer converge and stay crash-safe under concurrent edits: deterministic profile tie-breaking (#218), a lost-update-proof emergency-unblock count (#221), a crash-proof inbound reminder decode (#265), and an idempotent family-command send (#222).

**Architecture:** All four fixes ride the S0 sync engine that shipped in PR #269 (merged; follow-ups #277/#289 also merged). Profiles/locations/emergency-settings sync through the single `MutationFunnel` (I2) into the `DeviceSync` CloudKit zone; inbound records apply through `SyncApplyService`; `FamilyCommand` is a **separate** path in the `FamilyPolicies` zone and is deliberately NOT an engine entity. Two fixes are pure local hardening (#265 decode, #222 command save); one refines an existing merge branch (#218); one replaces an LWW scalar with a union-of-events ledger (#221).

**Tech Stack:** Swift 6, SwiftData (`cloudKitDatabase: .none` — manual sync), CloudKit `CKSyncEngine`, XCTest. Xcode 26.6.

**Base commit:** `4307654` (latest `main` at planning time — includes S0 #269 + follow-ups #277/#289). Re-triage of all four issues against this commit is recorded as issue comments (2026-07-07); status: #218 partially-fixed, #221 still-present, #265 still-present, #222 still-present.

---

## Global Constraints

Every task's requirements implicitly include this section.

- **The S0 contract is INVIOLABLE.** All locally-originated create/update/delete of a *synced entity* (profile, location, emergency state) MUST flow through `MutationFunnel` (I2). Inbound applies MUST NOT push except via the existing `pendingReenqueues → drainReenqueues` I2-exception channel. Never infer orphans/state — act only on the engine's explicit events. Each task below carries an **S0 conformance note** stating how it satisfies this.
- **`FamilyCommand` is exempt from the funnel by design** — it is a non-engine entity in the `FamilyPolicies` zone (shared/private DB). #222 stays local to `CloudKitNetworkService.sendCommand`; do NOT route it through `MutationFunnel`.
- Views use `@SafeQuery` (never raw `@Query`); non-query model arrays are filtered with `.valid`.
- Lock-code restriction checks use `appModeManager.currentMode == .child` — never `!= .parent`.
- `Log.<level>(_, category:)` for logging (never `print()`); never log lock codes or PII. `Log` is globally available (no import beyond `Foundation`).
- swift-format enforced by pre-commit hook (2-space indent, ~100–120 col). Run `swift-format --in-place --recursive .` before committing if unsure.
- Tests: name `testGivenX_WhenY_ThenZ()`. **Pin time** — capture one `let now = Date()` per test and derive/inject all other dates from it. Run against an already-booted simulator by **UUID** (never device name):
  `xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' | xcpretty`
- NEVER amend/force-push; new commits only. Request code review before merging.

---

## Task 0: Citation refresh (MANDATORY — do this first, no code)

Line numbers below were captured at `4307654`. Before writing any code, re-anchor every citation this plan depends on. This costs five minutes and prevents editing the wrong lines.

- [ ] **Step 1: Confirm the base and the engine surface exist**

Run and eyeball:
```bash
git log --oneline -1                       # expect 4307654 or a descendant
ls Foqos/CloudKit/SyncEngine/              # MutationFunnel, SyncApplyService, RecordProvider, ...
sed -n '236,286p' Foqos/CloudKit/SyncEngine/SyncApplyService.swift   # #218 four-way version gate
sed -n '443,459p' Foqos/CloudKit/SyncEngine/SyncApplyService.swift   # #221 emergency LWW branch
sed -n '196,205p' Foqos/CloudKit/SyncModels.swift                    # #265 reminder decode
sed -n '8,23p'   Foqos/CloudKit/CloudKitNetworkService+Commands.swift # #222 sendCommand
```
Expected: the four-way version gate (`>`, `==` tie, older); the emergency LWW `guard remote.version > ...`; the unchecked `UInt32(reminderInt)`; the bare `try await privateDatabase.save(record)`.

- [ ] **Step 2: Re-grep the symbols each task touches** (if a line moved, update the task's `Files:` before editing)

```bash
grep -n 'func applyDecodedProfile\|synced.version == existing.syncVersion\|pendingReenqueues.append' Foqos/CloudKit/SyncEngine/SyncApplyService.swift
grep -n 'func applyEmergencyModification\|emergencySettingsVersion\|applyRemoteEmergencySettings\|performEmergencyUnblock\|emergencyUnblocksRemaining' Foqos/Utils/EmergencyUnblockManager.swift Foqos/CloudKit/SyncEngine/SyncApplyService.swift
grep -n 'reminderTimeInSeconds\|UInt8(exactly:' Foqos/CloudKit/SyncModels.swift
grep -n 'func sendCommand\|serverRecordChanged' Foqos/CloudKit/CloudKitNetworkService+Commands.swift Foqos/CloudKit/SessionSyncService.swift
```

- [ ] **Step 3: Boot the test simulator once** (per AGENTS.md — reuse it for every task)

```bash
xcrun simctl list devices available | grep "iPhone 17"   # pick the UUID
xcrun simctl boot <UUID>
```

---

## Maintainer decisions in this bundle

Two tasks encode a policy the maintainer must ratify at plan-review time. Each task implements the **recommended** option; if the maintainer picks another, adjust only that task.

- **#218 tie-break policy** (Task 3): **Option B — deterministic winner (recommended)**. Options A/B/C are laid out in Task 3.
- **#221 count semantics** (Task 4): **Option C — union of usage-event records (recommended, per the bundle steer)**. Options A/B/C are laid out in Task 4. Option B (CAS delta-retry counter arithmetic) is explicitly *flagged, not chosen*.

---

## Task 1: #265 — range-check the inbound `reminderTimeInSeconds` decode

**Why:** `SyncedProfile.init?(from:)` does `reminderTimeInSeconds = UInt32(reminderInt)`, which **traps** (crashes) on a negative or `> UInt32.max` value. The decoder runs on the CKSyncEngine inbound path (`SyncApplyService.applyProfileModification`), *before* any version/schema gate, so one poison record crash-loops every device that fetches the zone. This is the warm-up task.

**Files:**
- Modify: `Foqos/CloudKit/SyncModels.swift:199-203` (the `reminderTimeInSeconds` decode block inside `SyncedProfile.init?(from:)`)
- Test: `FoqosTests/SyncedProfileDecodeBoundsTests.swift` (create)

**Interfaces:**
- Consumes: `SyncedProfile.init?(from record: CKRecord)` (`SyncModels.swift:177`); property `var reminderTimeInSeconds: UInt32?` (`SyncModels.swift:30`).
- Produces: no new public symbol; behavior change only (out-of-range ⇒ `nil`).

- [ ] **Step 1: Write the failing test**

Create `FoqosTests/SyncedProfileDecodeBoundsTests.swift`:
```swift
import CloudKit
import XCTest

@testable import FamilyFoqos

@MainActor
final class SyncedProfileDecodeBoundsTests: XCTestCase {

  /// Builds a minimally-valid SyncedProfile CKRecord (all required fields present) so the
  /// decode initializer reaches the optional-field assignments.
  private func minimalProfileRecord(now: Date, reminder: Int?) -> CKRecord {
    let zoneID = CKRecordZone.ID(zoneName: CloudKitConstants.syncZoneName, ownerName: CKCurrentUserDefaultName)
    let record = CKRecord(
      recordType: SyncedProfile.recordType,
      recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID))
    record["profileId"] = UUID().uuidString
    record["name"] = "Focus"
    record["createdAt"] = now
    record["updatedAt"] = now
    record["lastModified"] = now
    record["originDeviceId"] = "device-A"
    record["version"] = 1
    if let reminder { record["reminderTimeInSeconds"] = reminder }
    return record
  }

  func testGivenNegativeReminder_WhenDecoding_ThenDegradesToNilWithoutTrapping() {
    let now = Date()
    let record = minimalProfileRecord(now: now, reminder: -1)
    let synced = SyncedProfile(from: record)
    XCTAssertNotNil(synced, "an out-of-range reminder must not fail the whole decode")
    XCTAssertNil(synced?.reminderTimeInSeconds, "negative reminder degrades to no-reminder")
  }

  func testGivenOverflowingReminder_WhenDecoding_ThenDegradesToNilWithoutTrapping() {
    let now = Date()
    let record = minimalProfileRecord(now: now, reminder: Int(UInt32.max) + 1)
    let synced = SyncedProfile(from: record)
    XCTAssertNotNil(synced)
    XCTAssertNil(synced?.reminderTimeInSeconds, "overflowing reminder degrades to no-reminder")
  }

  func testGivenInRangeReminder_WhenDecoding_ThenPreservesValue() {
    let now = Date()
    let record = minimalProfileRecord(now: now, reminder: 3600)
    let synced = SyncedProfile(from: record)
    XCTAssertEqual(synced?.reminderTimeInSeconds, 3600)
  }
}
```

- [ ] **Step 2: Run it — expect the negative/overflow tests to CRASH (trap), not just fail**

Run: `xcodebuild test ... -only-testing:FoqosTests/SyncedProfileDecodeBoundsTests | xcpretty`
Expected: `testGivenNegativeReminder…` and `testGivenOverflowingReminder…` fail via a fatal `UInt32(reminderInt)` overflow trap (the in-range test passes). This reproduces the crash.

- [ ] **Step 3: Apply the range-checked cast**

In `SyncModels.swift`, replace lines 199-203:
```swift
    if let reminderInt = record[FieldKey.reminderTimeInSeconds.rawValue] as? Int {
      reminderTimeInSeconds = UInt32(reminderInt)
    } else {
      reminderTimeInSeconds = nil
    }
```
with:
```swift
    if let reminderInt = record[FieldKey.reminderTimeInSeconds.rawValue] as? Int {
      // #265: range-check the narrowing cast (same defensive-decode discipline as the
      // `UInt8(exactly:)` sibling ~16 lines below, and as the C1/#275 clamp for out-of-domain
      // values). An out-of-range CloudKit value degrades to "no reminder" instead of trapping
      // the whole inbound apply and crash-looping every device that fetches the poison record.
      if let bounded = UInt32(exactly: reminderInt) {
        reminderTimeInSeconds = bounded
      } else {
        Log.warning(
          "Ignoring out-of-range reminderTimeInSeconds \(reminderInt) from synced profile",
          category: .sync)
        reminderTimeInSeconds = nil
      }
    } else {
      reminderTimeInSeconds = nil
    }
```

- [ ] **Step 4: Run tests — expect PASS**

Run: `xcodebuild test ... -only-testing:FoqosTests/SyncedProfileDecodeBoundsTests | xcpretty`
Expected: all three pass; no trap.

- [ ] **Step 5: Audit the sibling decoders (grep only, no edit expected)**

Run: `grep -n 'UInt8(\|UInt16(\|UInt32(\|Int8(\|Int16(' Foqos/CloudKit/SyncModels.swift`
Expected: the only narrowing casts are now guarded (`UInt32(exactly:)`, `UInt8(exactly:)`). If a new unguarded one appears in `SyncedLocation`/`SyncedEmergencySettings`/`SyncResetRequest`, note it — do not fix here (out of scope), file a follow-up.

**S0 conformance note:** Read-only inbound-decode hardening. Touches no local mutation, does not flow through `MutationFunnel`, and changes no merge/conflict/version semantics — it only makes the existing inbound apply crash-proof.

- [ ] **Step 6: Commit**
```bash
git add Foqos/CloudKit/SyncModels.swift FoqosTests/SyncedProfileDecodeBoundsTests.swift
git commit -m "fix(#265): range-check inbound reminderTimeInSeconds decode (no trap on poison record)"
```

---

## Task 2: #222 — idempotent `sendCommand` on `serverRecordChanged`

**Why:** `sendCommand` saves a fresh `CKRecord` with a **deterministic** recordName (`<type>-<childId>-<parentId>`) under the default `.ifServerRecordUnchanged` policy. If a command of that type is still pending (child offline, younger than the 7-day GC), the save fails with `CKError.serverRecordChanged`, which surfaces to the parent as a cryptic "Failed to save: Server Record Changed" alert — for what is, by design, an idempotent no-op. The codebase already handles `serverRecordChanged` in `SessionSyncService.swift:202-210` and `ResetController.handleCommandSaveResult`.

**Files:**
- Modify: `Foqos/CloudKit/CloudKitNetworkService+Commands.swift:8-23` (`sendCommand`)
- Test: `FoqosTests/FamilyCommandSaveOutcomeTests.swift` (create)

**Interfaces:**
- Consumes: `func sendCommand(_ command: FamilyCommand) async throws` (`+Commands.swift:8`); `CloudKitError.saveFailed(Error)` (`CloudKitManager.swift`).
- Produces: `enum CommandSaveOutcome { case sent, alreadyPending, failed }` and `static func classifyCommandSave(error: Error?) -> CommandSaveOutcome` on `CloudKitNetworkService` — a pure, unit-testable classifier.

**Decision (idempotent-success vs refetch-refresh):** an identical pending command *is* already queued, so treat the collision as success. This is the boring correct policy — there is no version/clock to merge. (A fuller "refetch the record, refresh `createdAt` to reset the 7-day GC clock, re-save" variant is possible but adds a network round-trip for no behavioral gain; note it in the PR description as a rejected alternative.)

- [ ] **Step 1: Write the failing test** (pure classifier — testable at unit level, no CKDatabase needed)

Create `FoqosTests/FamilyCommandSaveOutcomeTests.swift`:
```swift
import CloudKit
import XCTest

@testable import FamilyFoqos

@MainActor
final class FamilyCommandSaveOutcomeTests: XCTestCase {

  func testGivenNoError_WhenClassifying_ThenSent() {
    XCTAssertEqual(CloudKitNetworkService.classifyCommandSave(error: nil), .sent)
  }

  func testGivenServerRecordChanged_WhenClassifying_ThenAlreadyPending() {
    let error = CKError(.serverRecordChanged)
    XCTAssertEqual(CloudKitNetworkService.classifyCommandSave(error: error), .alreadyPending)
  }

  func testGivenOtherCKError_WhenClassifying_ThenFailed() {
    let error = CKError(.networkUnavailable)
    XCTAssertEqual(CloudKitNetworkService.classifyCommandSave(error: error), .failed)
  }

  func testGivenNonCKError_WhenClassifying_ThenFailed() {
    struct Boom: Error {}
    XCTAssertEqual(CloudKitNetworkService.classifyCommandSave(error: Boom()), .failed)
  }
}
```

- [ ] **Step 2: Run it — expect FAIL to compile** (`classifyCommandSave` / `CommandSaveOutcome` do not exist)

Run: `xcodebuild test ... -only-testing:FoqosTests/FamilyCommandSaveOutcomeTests | xcpretty`
Expected: compile failure "type 'CloudKitNetworkService' has no member 'classifyCommandSave'".

- [ ] **Step 3: Add the classifier and wire `sendCommand` to use it**

In `CloudKitNetworkService+Commands.swift`, add above `sendCommand` (inside the `extension CloudKitNetworkService`):
```swift
  /// Outcome of attempting to save a FamilyCommand. `.alreadyPending` means the deterministic
  /// recordName collided with a still-pending identical command — an idempotent no-op, treated
  /// as success (#222). Mirrors the serverRecordChanged handling at SessionSyncService.swift:202
  /// and ResetController.handleCommandSaveResult.
  enum CommandSaveOutcome: Equatable { case sent, alreadyPending, failed }

  static func classifyCommandSave(error: Error?) -> CommandSaveOutcome {
    guard let error else { return .sent }
    if let ckError = error as? CKError, ckError.code == .serverRecordChanged {
      return .alreadyPending
    }
    return .failed
  }
```
Then replace the `do { ... } catch { ... }` body of `sendCommand` (lines 16-22):
```swift
    do {
      _ = try await privateDatabase.save(record)
      Log.info("Command sent successfully", category: .cloudKit)
    } catch {
      switch Self.classifyCommandSave(error: error) {
      case .sent:
        break
      case .alreadyPending:
        // #222: deterministic-recordName collision ⇒ an identical command is already queued
        // for this child. The operation is idempotent, so this is success, not a failure.
        Log.info(
          "Command already pending (serverRecordChanged) — idempotent success", category: .cloudKit)
      case .failed:
        Log.error("Failed to send command: \(error)", category: .cloudKit)
        throw CloudKitError.saveFailed(error)
      }
    }
```

- [ ] **Step 4: Run tests — expect PASS**

Run: `xcodebuild test ... -only-testing:FoqosTests/FamilyCommandSaveOutcomeTests | xcpretty`
Expected: all four pass.

- [ ] **Step 5: Confirm the parent no longer sees a failure alert on a re-tap (code inspection)**

Confirm `ParentDashboardView.resetEmergencyCount()` (`ParentDashboardView.swift:~1096`) and `resetLockCodeThrottle()` (`~1136`) call `CloudKitManager.shared.sendCommand(...)` inside a `do/catch` that only sets `resetErrorMessage` on a thrown error. With `.alreadyPending` no longer throwing, a second tap now completes silently (success). No view change required.

**S0 conformance note:** `FamilyCommand` is deliberately outside `MutationFunnel` (a `FamilyPolicies`-zone non-engine entity). The fix stays entirely inside `sendCommand`; it does not touch the DeviceSync engine, the funnel, or any synced entity — honoring the contract's zone separation.

- [ ] **Step 6: Commit**
```bash
git add Foqos/CloudKit/CloudKitNetworkService+Commands.swift FoqosTests/FamilyCommandSaveOutcomeTests.swift
git commit -m "fix(#222): treat serverRecordChanged as idempotent success in sendCommand"
```

---

## Task 3: #218 — deterministic profile tie-break + accurate conflict copy

**Why:** S0 already surfaces same-version divergence (the equal-version branch in `applyDecodedProfile` bumps `syncVersion+1`, re-enqueues the local payload, and raises a conflict banner). Two residuals remain: (1) the tie-break is *local-always-wins*, which does not deterministically converge — because each device re-broadcasts its own payload at the bumped version, two genuinely divergent devices can ping-pong/escalate `syncVersion` with the banner stuck on both; (2) the banner reuses the schema-version wording ("edited on an older app version"), which is wrong for a same-version concurrent edit.

### MAINTAINER DECISION — tie-break policy (implementing Option B)

- **Option A — local-always-wins (current).** No data silently lost, surfaced via banner, but non-converging (version escalation risk). *Rejected: doesn't converge.*
- **Option B — deterministic winner (RECOMMENDED, implemented below).** On a payload-differing tie, both devices pick the SAME winner from a total order already carried in `SyncedProfile`: newer `updatedAt` wins; ties broken by lexicographically-lower `originDeviceId`. Winner keeps+bumps+re-enqueues; loser *adopts* the winner's payload. Both converge to identical data in ≤2 sync rounds; one concurrent edit is dropped but surfaced via a banner. *Chosen.*
- **Option C — field-level 3-way merge.** High complexity, needs per-field base tracking. *Rejected: out of scope.*

If the maintainer prefers A, implement only the copy fix (Steps 5-7) and skip Steps 1-4's comparator adoption.

**Files:**
- Modify: `Foqos/CloudKit/SyncEngine/SyncApplyService.swift:270-281` (equal-version branch) and add a private `remoteWinsProfileTie(...)` helper.
- Modify: `Foqos/Models/SyncConflictManager.swift` (add a `divergenceProfiles` category + message + `addDivergenceConflict`, wire into `clearConflict`/`clearAll`/`dismissBanner`).
- Modify: `Foqos/Components/SyncConflictBanner.swift` (display the divergence message).
- Test: `FoqosTests/ProfileTieBreakApplyTests.swift` (create), `FoqosTests/SyncConflictManagerDivergenceTests.swift` (create).

**Interfaces:**
- Consumes: `applyDecodedProfile(_:record:)` (`SyncApplyService.swift:236`); `updateLocalProfile(_:from:)` (`:290`, adopts remote payload + sets `syncVersion = synced.version`); `pendingReenqueues`/`drainReenqueues()` (`:25`/`:50`); `SyncPayloadEquality.profilesPayloadEqual` (`:7`, includes `updatedAt`); `storeSystemFields(_:)` (`:502`); `SyncedProfile.init(from:originDeviceId:)` (`SyncModels.swift:250`, captures `updatedAt`).
- Produces: `static func remoteWinsProfileTie(remote: SyncedProfile, local: SyncedProfile) -> Bool` (pure, unit-testable); `SyncConflictManager.addDivergenceConflict(profileId:profileName:)` + `var divergenceMessage: String` + `var shouldShowDivergenceBanner: Bool`.

- [ ] **Step 1: Write the failing comparator test**

Create `FoqosTests/ProfileTieBreakApplyTests.swift`:
```swift
import CloudKit
import XCTest

@testable import FamilyFoqos

@MainActor
final class ProfileTieBreakApplyTests: XCTestCase {

  // SyncedProfile has NO synthesized memberwise init (it defines `init?(from:)` and
  // `init(from:originDeviceId:)`), so build it the way the existing apply tests do
  // (SyncApplyServiceTests.makeProfileRecord): from a BlockedProfiles source. The comparator
  // reads only `updatedAt` + `originDeviceId`, so `version` is irrelevant here.
  private func synced(name: String, updatedAt: Date, device: String) -> SyncedProfile {
    let source = BlockedProfiles(id: UUID(), name: name, updatedAt: updatedAt)
    return SyncedProfile(from: source, originDeviceId: device)
  }

  func testGivenTie_WhenRemoteHasNewerUpdatedAt_ThenRemoteWins() {
    let now = Date()
    let remote = synced(name: "R", updatedAt: now, device: "A")
    let local = synced(name: "L", updatedAt: now.addingTimeInterval(-10), device: "B")
    XCTAssertTrue(SyncApplyService.remoteWinsProfileTie(remote: remote, local: local))
  }

  func testGivenTie_WhenLocalHasNewerUpdatedAt_ThenLocalWins() {
    let now = Date()
    let remote = synced(name: "R", updatedAt: now.addingTimeInterval(-10), device: "A")
    let local = synced(name: "L", updatedAt: now, device: "B")
    XCTAssertFalse(SyncApplyService.remoteWinsProfileTie(remote: remote, local: local))
  }

  func testGivenEqualUpdatedAt_WhenBreaking_ThenLowerOriginDeviceIdWins() {
    let now = Date()
    let remote = synced(name: "R", updatedAt: now, device: "A")  // "A" < "B"
    let local = synced(name: "L", updatedAt: now, device: "B")
    XCTAssertTrue(SyncApplyService.remoteWinsProfileTie(remote: remote, local: local))
    // Symmetric: from the other device's vantage, the same payload (device "A") still wins.
    XCTAssertFalse(SyncApplyService.remoteWinsProfileTie(remote: local, local: remote))
  }
}
```
> `@MainActor final class ProfileTieBreakApplyTests: XCTestCase` — add the class scaffold and imports (`CloudKit`, `XCTest`, `@testable import FamilyFoqos`) as shown for the other new test files.

- [ ] **Step 2: Run it — expect compile FAIL** (`remoteWinsProfileTie` undefined)

- [ ] **Step 3: Add the comparator and rewrite the equal-version branch**

In `SyncApplyService.swift`, add the pure helper (place it near the profile-apply section):
```swift
  /// #218 deterministic tie-break: on an equal-version payload-differing conflict, both devices
  /// must pick the SAME winner. Newer `updatedAt` wins; ties broken by the lexicographically
  /// lower `originDeviceId` (total order ⇒ symmetric-consistent across devices).
  static func remoteWinsProfileTie(remote: SyncedProfile, local: SyncedProfile) -> Bool {
    if remote.updatedAt != local.updatedAt {
      return remote.updatedAt > local.updatedAt
    }
    return remote.originDeviceId < local.originDeviceId
  }
```
Replace the equal-version branch (lines 270-281):
```swift
    } else if synced.version == existing.syncVersion {
      // Equal-version divergence (§5.1): payload-differing ⇒ conflict now.
      let localSynced = SyncedProfile(from: existing, originDeviceId: deviceId)
      if SyncPayloadEquality.profilesPayloadEqual(synced, localSynced) {
        return .applied  // payload-equal echo ⇒ no-op
      }
      existing.syncVersion += 1
      try commit()
      pendingReenqueues.append(record.recordID)
      SyncConflictManager.shared.addConflict(
        profileId: existing.id, profileName: existing.name)
      return .applied
    } else {
```
with:
```swift
    } else if synced.version == existing.syncVersion {
      // Equal-version divergence (§5.1): payload-differing ⇒ deterministic tie-break (#218).
      let localSynced = SyncedProfile(from: existing, originDeviceId: deviceId)
      if SyncPayloadEquality.profilesPayloadEqual(synced, localSynced) {
        return .applied  // payload-equal echo ⇒ no-op
      }
      if Self.remoteWinsProfileTie(remote: synced, local: localSynced) {
        // Remote wins: adopt its payload (sets syncVersion = synced.version) so both devices
        // converge to identical data. No re-enqueue — we took the peer's already-published copy.
        updateLocalProfile(existing, from: synced)
        try commit()
        storeSystemFields(record)
        SyncConflictManager.shared.addDivergenceConflict(
          profileId: existing.id, profileName: existing.name)
        return .applied
      } else {
        // Local wins: keep local, bump above the tie so the peer's next fetch sees a strictly
        // greater version and adopts ours (converges without escalation), and re-enqueue.
        existing.syncVersion += 1
        try commit()
        pendingReenqueues.append(record.recordID)
        SyncConflictManager.shared.addDivergenceConflict(
          profileId: existing.id, profileName: existing.name)
        return .applied
      }
    } else {
```

- [ ] **Step 4: Run the comparator test — expect PASS**

Run: `xcodebuild test ... -only-testing:FoqosTests/ProfileTieBreakApplyTests | xcpretty`

- [ ] **Step 5: Write the failing conflict-copy test**

Create `FoqosTests/SyncConflictManagerDivergenceTests.swift`:
```swift
import XCTest

@testable import FamilyFoqos

@MainActor
final class SyncConflictManagerDivergenceTests: XCTestCase {

  override func tearDown() {
    SyncConflictManager.shared.clearAll()
    super.tearDown()
  }

  func testGivenDivergence_WhenAdded_ThenBannerShownWithDedicatedCopy() {
    let manager = SyncConflictManager.shared
    manager.clearAll()
    manager.addDivergenceConflict(profileId: UUID(), profileName: "Homework")
    XCTAssertTrue(manager.showConflictBanner)
    XCTAssertTrue(manager.shouldShowDivergenceBanner)
    XCTAssertTrue(manager.divergenceMessage.contains("Homework"))
    XCTAssertFalse(
      manager.divergenceMessage.lowercased().contains("older app version"),
      "a same-version concurrent edit must NOT claim an app-version mismatch")
  }

  func testGivenDivergence_WhenCleared_ThenBannerHides() {
    let manager = SyncConflictManager.shared
    manager.clearAll()
    let id = UUID()
    manager.addDivergenceConflict(profileId: id, profileName: "Homework")
    manager.clearConflict(profileId: id)
    XCTAssertFalse(manager.showConflictBanner)
  }
}
```

- [ ] **Step 6: Run it — expect compile FAIL, then add the divergence category**

In `SyncConflictManager.swift`:
- Add the published store (next to `conflictedProfiles`):
```swift
  @Published var divergenceProfiles: [UUID: String] = [:]  // ID → name (same-version concurrent edit)
```
- Add the mutator (next to `addConflict`):
```swift
  /// A same-version concurrent edit was resolved by the deterministic tie-break (#218) — distinct
  /// from a schema-version mismatch, so it gets its own copy.
  func addDivergenceConflict(profileId: UUID, profileName: String) {
    divergenceProfiles[profileId] = profileName
    showConflictBanner = true
  }
```
- Extend `clearConflict(profileId:)`, `clearAll()`, and `dismissBanner()` to include `divergenceProfiles` (mirror the existing `conflictedProfiles` handling — `clearConflict` removes the key and hides the banner when *all three* dictionaries are empty; `clearAll`/`dismissBanner` also clear `divergenceProfiles`).
- Add the display accessors:
```swift
  var shouldShowDivergenceBanner: Bool {
    !divergenceProfiles.isEmpty && showConflictBanner
  }

  var divergenceMessage: String {
    if divergenceProfiles.count == 1, let name = divergenceProfiles.values.first {
      return "\"\(name)\" was changed on another device. Keeping the most recently edited copy."
    } else {
      return "Several profiles were changed on more than one device. Keeping the most recently edited copies."
    }
  }
```

- [ ] **Step 7: Wire the banner** (`Foqos/Components/SyncConflictBanner.swift`)

Add a branch that renders `SyncConflictManager.shared.divergenceMessage` when `shouldShowDivergenceBanner` is true, mirroring the existing older/newer-version branches (same layout, dismiss action calls `dismissBanner()`). Read the file first to match its exact SwiftUI structure; do not restyle.

- [ ] **Step 8: Run all three new test classes + the sync suite — expect PASS**

Run: `xcodebuild test ... -only-testing:FoqosTests/ProfileTieBreakApplyTests -only-testing:FoqosTests/SyncConflictManagerDivergenceTests | xcpretty`
Then run the existing apply/engine tests to confirm no regression:
`xcodebuild test ... -only-testing:FoqosTests/RecordProviderTests -only-testing:FoqosTests/MutationFunnelTests | xcpretty`

**S0 conformance note:** The tie-break stays entirely inside the existing inbound-apply merge. The winner-keeps path re-pushes ONLY via the existing `pendingReenqueues → drainReenqueues` I2 exception (unchanged wiring); the loser-adopts path performs no push (it took the peer's already-published record). No new push origin, no funnel bypass, no orphan inference. `storeSystemFields` on adopt keeps the change-tag cache correct (§5.1).

- [ ] **Step 9: Commit**
```bash
git add Foqos/CloudKit/SyncEngine/SyncApplyService.swift Foqos/Models/SyncConflictManager.swift Foqos/Components/SyncConflictBanner.swift FoqosTests/ProfileTieBreakApplyTests.swift FoqosTests/SyncConflictManagerDivergenceTests.swift
git commit -m "fix(#218): deterministic profile tie-break + dedicated divergence conflict copy"
```

---

## Task 4: #221 — emergency-unblock count as a union of usage events

**Why:** the emergency-unblock count is a single scalar (`emergencyUnblocksRemaining`) synced by versioned last-write-wins (`applyEmergencyModification`). Two devices each consuming an unblock from the same base both push the absolute value `remaining−1` at `version+1`; the LWW gate cannot distinguish the two writes, so one decrement is lost and the safety limit is under-counted.

### MAINTAINER DECISION — count semantics (implementing Option C)

- **Option A — keep versioned LWW (status quo).** Loses concurrent decrements. *Rejected: the defect.*
- **Option B — CAS delta-retry counter arithmetic** (refetch server value, apply the decrement as a delta, re-save on `serverRecordChanged`, like `SessionSyncService`). Converges, but is *clever counter arithmetic* over a single mutable cell — fragile under three-way races and hard to reason about. *Flagged, not chosen (per the bundle steer).*
- **Option C — union of immutable usage-event records (RECOMMENDED, implemented below).** Each consumed unblock is a write-once record with a unique recordName; concurrent unblocks create distinct records that CKSyncEngine unions with no conflict. `remaining` becomes *derived*: `max(0, allowance − count(events in current reset epoch))`. Boring, convergent, no counter arithmetic. *Chosen.*

**Design.** Model consumption events like sessions (a recordName-prefixed non-SwiftData entity — **no ModelContainer schema change**), stored in `EmergencyUnblockManager` (co-located with the state they replace):
- Record type `EmergencyUnblockEvent`, recordName `EmergencyUnblock_<uuid>`, fields `deviceId: String`, `consumedAt: Date`, `resetEpoch: Int`.
- The event ledger is a persisted `[EmergencyUnblockEvent]` (UserDefaults JSON, like the existing counters). Union on apply = insert-if-absent by `id` (a G-Set).
- `resetEpoch` is a monotonic Int on the existing `SyncedEmergencySettings` (config, synced by LWW as today). `remaining = max(0, allowance − |events where resetEpoch == currentEpoch|)`, `allowance = 3`.
- A reset advances `resetEpoch` (config LWW propagates it); old-epoch events stop counting and are GC'd (funnel delete path) in Step 4d.
- All mutations ride `MutationFunnel`: consuming an unblock enqueues an event save; GC enqueues an event delete.

This is a multi-part task; each sub-task (4a–4e) is independently testable.

**Interfaces produced (used across sub-tasks):**
- `struct SyncedEmergencyUnblockEvent: Codable, Equatable` in `SyncModels.swift` — `id: UUID`, `deviceId: String`, `consumedAt: Date`, `resetEpoch: Int`; `static let recordType = "EmergencyUnblockEvent"`, `static let recordNamePrefix = "EmergencyUnblock_"`, `var recordName: String { Self.recordNamePrefix + id.uuidString }`; `toCKRecord(in:)` / `updateCKRecord(_:)` / `init?(from:)`.
- `EmergencyUnblockManager`: `func consumeUnblockEvent(now: Date) -> SyncedEmergencyUnblockEvent` (creates+persists a local event at the current epoch, returns it); `func mergeRemoteUnblockEvent(_:)` (union insert); `func eventRecord(forRecordName:) -> SyncedEmergencyUnblockEvent?`; `var currentResetEpoch: Int`; derived `getRemainingEmergencyUnblocks()`.
- `MutationFunnel.enqueueEmergencyUnblockEvent(_ event: SyncedEmergencyUnblockEvent)` + facades on `SyncEngineControlling` / `SyncEngineController+Cutover` / `ProfileSyncManager` mirroring `enqueueEmergencySettingsSave`.

---

### Task 4a: the event model + derived count + epoch (no sync wiring yet)

**Files:**
- Modify: `Foqos/CloudKit/SyncModels.swift` (add `SyncedEmergencyUnblockEvent`; add `resetEpoch` to `SyncedEmergencySettings`).
- Modify: `Foqos/Utils/EmergencyUnblockManager.swift` (event ledger storage, epoch, derived count).
- Test: `FoqosTests/EmergencyUnblockEventLedgerTests.swift` (create).

- [ ] **Step 1: Write the failing derived-count test**

Create `FoqosTests/EmergencyUnblockEventLedgerTests.swift`:
```swift
import XCTest

@testable import FamilyFoqos

@MainActor
final class EmergencyUnblockEventLedgerTests: XCTestCase {

  private var suiteName: String!
  private var defaults: UserDefaults!

  override func setUp() {
    super.setUp()
    suiteName = "EmergencyLedger-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)!
  }
  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    super.tearDown()
  }

  func testGivenThreeAllowance_WhenTwoEventsInEpoch_ThenRemainingIsOne() {
    let now = Date()
    let manager = EmergencyUnblockManager(defaults: defaults)  // test seam (Step 3)
    manager.seedForTesting(allowance: 3, epoch: 1)
    _ = manager.consumeUnblockEvent(now: now)
    _ = manager.consumeUnblockEvent(now: now)
    XCTAssertEqual(manager.getRemainingEmergencyUnblocks(), 1)
  }

  func testGivenConcurrentEventsFromTwoDevices_WhenMerged_ThenBothCount() {
    let now = Date()
    let manager = EmergencyUnblockManager(defaults: defaults)
    manager.seedForTesting(allowance: 3, epoch: 1)
    let localEvent = manager.consumeUnblockEvent(now: now)          // this device
    let remoteEvent = SyncedEmergencyUnblockEvent(
      id: UUID(), deviceId: "other", consumedAt: now, resetEpoch: 1)  // peer, same base
    manager.mergeRemoteUnblockEvent(remoteEvent)
    XCTAssertEqual(manager.getRemainingEmergencyUnblocks(), 1, "two distinct events both count")
    XCTAssertNotEqual(localEvent.id, remoteEvent.id)
  }

  func testGivenReDeliveredEvent_WhenMergedTwice_ThenCountsOnce() {
    let now = Date()
    let manager = EmergencyUnblockManager(defaults: defaults)
    manager.seedForTesting(allowance: 3, epoch: 1)
    let e = SyncedEmergencyUnblockEvent(id: UUID(), deviceId: "x", consumedAt: now, resetEpoch: 1)
    manager.mergeRemoteUnblockEvent(e)
    manager.mergeRemoteUnblockEvent(e)  // idempotent union
    XCTAssertEqual(manager.getRemainingEmergencyUnblocks(), 2)
  }

  func testGivenOldEpochEvents_WhenEpochAdvances_ThenTheyStopCounting() {
    let now = Date()
    let manager = EmergencyUnblockManager(defaults: defaults)
    manager.seedForTesting(allowance: 3, epoch: 1)
    _ = manager.consumeUnblockEvent(now: now)
    _ = manager.consumeUnblockEvent(now: now)
    manager.advanceResetEpochForTesting()  // epoch 1 → 2
    XCTAssertEqual(manager.getRemainingEmergencyUnblocks(), 3, "prior-epoch events don't count")
  }

  func testRemainingClampsAtZero() {
    let now = Date()
    let manager = EmergencyUnblockManager(defaults: defaults)
    manager.seedForTesting(allowance: 3, epoch: 1)
    for _ in 0..<5 { _ = manager.consumeUnblockEvent(now: now) }
    XCTAssertEqual(manager.getRemainingEmergencyUnblocks(), 0, "never negative")
  }
}
```

- [ ] **Step 2: Run it — expect compile FAIL** (new symbols undefined)

- [ ] **Step 3: Add the model and the ledger**

In `SyncModels.swift`, add `resetEpoch` to `SyncedEmergencySettings`: a new `var resetEpoch: Int` field, a `FieldKey` case, a line in `updateCKRecord`, `init?(from:)` decoding with `as? Int ?? 0` (back-compat), and `defaults(deviceId:)` → `resetEpoch: 0`. **In the explicit memberwise `init` (`SyncModels.swift:540`), give the new parameter a default: `resetEpoch: Int = 0`.** This is required: `SyncedEmergencySettings` has an all-args memberwise init with ~7 existing construction sites (`SyncApplyServiceTests.swift:316/332/335`, `RecordProviderTests.swift:96`, `EmergencyUnblockManagerSnapshotTests.swift:23`, `SyncPayloadEqualityTests.swift:66/69`, plus the two production sites `SyncModels.swift:490` and `EmergencyUnblockManager.swift:249`); a non-defaulted parameter breaks all of them. With the default, only the sites that need the epoch pass it. Then add the event struct:
```swift
// MARK: - Synced Emergency Unblock Event

/// One immutable record per consumed emergency unblock. Union-merged across devices (write-once,
/// unique recordName), so concurrent unblocks never collide (#221). Count is derived per epoch.
struct SyncedEmergencyUnblockEvent: Codable, Equatable {
  var id: UUID
  var deviceId: String
  var consumedAt: Date
  var resetEpoch: Int

  static let recordType = "EmergencyUnblockEvent"
  static let recordNamePrefix = "EmergencyUnblock_"
  var recordName: String { Self.recordNamePrefix + id.uuidString }

  enum FieldKey: String { case id, deviceId, consumedAt, resetEpoch }

  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let record = CKRecord(
      recordType: Self.recordType,
      recordID: CKRecord.ID(recordName: recordName, zoneID: zoneID))
    updateCKRecord(record)
    return record
  }

  func updateCKRecord(_ record: CKRecord) {
    record[FieldKey.id.rawValue] = id.uuidString
    record[FieldKey.deviceId.rawValue] = deviceId
    record[FieldKey.consumedAt.rawValue] = consumedAt
    record[FieldKey.resetEpoch.rawValue] = resetEpoch
  }

  init(id: UUID, deviceId: String, consumedAt: Date, resetEpoch: Int) {
    self.id = id
    self.deviceId = deviceId
    self.consumedAt = consumedAt
    self.resetEpoch = resetEpoch
  }

  init?(from record: CKRecord) {
    guard record.recordType == Self.recordType,
      let idString = record[FieldKey.id.rawValue] as? String,
      let id = UUID(uuidString: idString),
      let consumedAt = record[FieldKey.consumedAt.rawValue] as? Date,
      let resetEpoch = record[FieldKey.resetEpoch.rawValue] as? Int
    else { return nil }
    self.id = id
    self.deviceId = record[FieldKey.deviceId.rawValue] as? String ?? ""
    self.consumedAt = consumedAt
    self.resetEpoch = resetEpoch
  }
}
```
In `EmergencyUnblockManager.swift`:
- Add a `defaults` injection point: `private let defaults: UserDefaults`, accepted in `init` with default `.standard`, alongside the existing `geofenceEvaluator`/`profileSyncManager` params. **Scope note (Swift init gotcha):** the pre-existing config properties (`emergencyUnblocksResetPeriodInDays`, `lastEmergencyUnblocksResetDateTimestamp`, `emergencySettingsLockedStorage`, `emergencySettingsVersion`) initialize from `UserDefaults.standard` in their *stored-property default expressions*, which cannot see `self`/init params and so always read `.standard` — leave them as-is (config LWW, out of #221's scope). Only the NEW ledger + epoch accessors below are **computed** properties reading `self.defaults`, so they observe the injected instance — that is what isolates the ledger per test. Do NOT try to reroute the config stored-props through `defaults`.
- Add the ledger + epoch storage keys and JSON accessors:
```swift
  private enum LedgerKey {
    static let events = "family_foqos_emergency_unblock_events"
    static let resetEpoch = "family_foqos_emergency_reset_epoch"
    static let allowance = 3
  }

  var currentResetEpoch: Int {
    get { defaults.integer(forKey: LedgerKey.resetEpoch) }
    set { defaults.set(newValue, forKey: LedgerKey.resetEpoch) }
  }

  private var unblockEvents: [SyncedEmergencyUnblockEvent] {
    get {
      guard let data = defaults.data(forKey: LedgerKey.events),
        let events = try? JSONDecoder().decode([SyncedEmergencyUnblockEvent].self, from: data)
      else { return [] }
      return events
    }
    set {
      if let data = try? JSONEncoder().encode(newValue) {
        defaults.set(data, forKey: LedgerKey.events)
      }
    }
  }
```
- Rewrite `getRemainingEmergencyUnblocks()` to derive from the ledger:
```swift
  func getRemainingEmergencyUnblocks() -> Int {
    let consumed = unblockEvents.filter { $0.resetEpoch == currentResetEpoch }.count
    return max(0, LedgerKey.allowance - consumed)
  }
```
- Add the mutators:
```swift
  /// Records a locally-consumed unblock as an immutable event at the current epoch and returns it
  /// for the caller to enqueue through the funnel (I2). Does not push here.
  func consumeUnblockEvent(now: Date) -> SyncedEmergencyUnblockEvent {
    let event = SyncedEmergencyUnblockEvent(
      id: UUID(), deviceId: SharedData.deviceSyncId.uuidString, consumedAt: now,
      resetEpoch: currentResetEpoch)
    var all = unblockEvents
    all.append(event)
    unblockEvents = all
    objectWillChange.send()
    return event
  }

  /// Union insert of a remote event (idempotent by id) — the G-Set merge.
  func mergeRemoteUnblockEvent(_ event: SyncedEmergencyUnblockEvent) {
    var all = unblockEvents
    guard !all.contains(where: { $0.id == event.id }) else { return }
    all.append(event)
    unblockEvents = all
    objectWillChange.send()
  }

  func eventRecord(forRecordName recordName: String) -> SyncedEmergencyUnblockEvent? {
    unblockEvents.first { $0.recordName == recordName }
  }

  #if DEBUG
  func seedForTesting(allowance: Int, epoch: Int) {
    // `allowance` is fixed at 3 in production; the param documents intent in tests.
    currentResetEpoch = epoch
    unblockEvents = []
  }
  func advanceResetEpochForTesting() { currentResetEpoch += 1 }
  #endif
```
> `objectWillChange.send()` keeps the `@Published`-driven UI in sync now that `remaining` is derived rather than a stored `@Published`. Confirm `EmergencyUnblockManager` still conforms to `ObservableObject` (it does).

- [ ] **Step 4: Run the ledger tests — expect PASS**

Run: `xcodebuild test ... -only-testing:FoqosTests/EmergencyUnblockEventLedgerTests | xcpretty`

- [ ] **Step 5: Commit**
```bash
git add Foqos/CloudKit/SyncModels.swift Foqos/Utils/EmergencyUnblockManager.swift FoqosTests/EmergencyUnblockEventLedgerTests.swift
git commit -m "feat(#221): emergency-unblock event ledger + epoch-derived remaining count"
```

---

### Task 4b: funnel + facades for enqueuing an event

**Files:**
- Modify: `Foqos/CloudKit/SyncEngine/MutationFunnel.swift` (add `enqueueEmergencyUnblockEvent`).
- Modify: `Foqos/CloudKit/SyncEngine/SyncEngineControlling.swift` (protocol method).
- Modify: `Foqos/CloudKit/SyncEngine/SyncEngineController+Cutover.swift` (delegate).
- Modify: `Foqos/CloudKit/ProfileSyncManager.swift` (facade).
- Test: extend `FoqosTests/MutationFunnelTests.swift`.

**Interfaces:**
- Consumes: `MockSyncEngineDriver`, `SyncEngineStore`, `TestModelContainer` (existing test harness).
- Produces: `MutationFunnel.enqueueEmergencyUnblockEvent(_ event: SyncedEmergencyUnblockEvent)` — persists the event (already done by `consumeUnblockEvent`) and enqueues one `.saveRecord(eventID)`; `SyncEngineControlling.enqueueEmergencyUnblockEvent(_:) throws`; `ProfileSyncManager.enqueueEmergencyUnblockEvent(_:) throws`.

- [ ] **Step 1: Write the failing funnel test** (append to `MutationFunnelTests.swift`)
```swift
  func testGivenUnblockEvent_WhenEnqueue_ThenEnqueuesOneSaveRecord() throws {
    let now = Date()
    let container = try TestModelContainer.create()
    let syncContext = ModelContext(container)
    let store = makeStore()
    let driver = MockSyncEngineDriver()
    let funnel = MutationFunnel(
      modelContext: syncContext, store: store, driver: driver, deviceId: "device-A")
    let event = SyncedEmergencyUnblockEvent(
      id: UUID(), deviceId: "device-A", consumedAt: now, resetEpoch: 1)

    funnel.enqueueEmergencyUnblockEvent(event)

    XCTAssertEqual(
      driver.pendingRecordZoneChanges, [.saveRecord(recordID(event.recordName))])
  }
```

- [ ] **Step 2: Run it — expect compile FAIL**

- [ ] **Step 3: Add the funnel method** (in `MutationFunnel.swift`, in the "Save paths" section)
```swift
  /// Enqueue a write-once emergency-unblock event (I2, #221). The event is already persisted by
  /// `EmergencyUnblockManager.consumeUnblockEvent`; nothing here can fail (not `throws`), matching
  /// `enqueueEmergencySettingsSave`. The facade layer above throws for "engine not attached".
  func enqueueEmergencyUnblockEvent(_ event: SyncedEmergencyUnblockEvent) {
    let recordID = CKRecord.ID(recordName: event.recordName, zoneID: zoneID)
    driver.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
  }
```

- [ ] **Step 4: Add the facades** (mirror `enqueueEmergencySettingsSave` at all three seams)
- `SyncEngineControlling.swift`: add `func enqueueEmergencyUnblockEvent(_ event: SyncedEmergencyUnblockEvent) throws`
- `SyncEngineController+Cutover.swift`:
```swift
  func enqueueEmergencyUnblockEvent(_ event: SyncedEmergencyUnblockEvent) throws {
    guard let funnel else { throw SyncEngineControllingError.notAttached }
    funnel.enqueueEmergencyUnblockEvent(event)
  }
```
- `ProfileSyncManager.swift`:
```swift
  func enqueueEmergencyUnblockEvent(_ event: SyncedEmergencyUnblockEvent) throws {
    guard let engineController else { throw SyncEngineControllingError.notAttached }
    try engineController.enqueueEmergencyUnblockEvent(event)
  }
```
> **Required:** `FoqosTests/Mocks/MockSyncEngineControlling.swift` conforms to `SyncEngineControlling`, so the new protocol method must be added there or the test target won't compile. Mirror the existing `enqueueEmergencySettingsSave` capture: add `private(set) var enqueuedEmergencyUnblockEvents: [SyncedEmergencyUnblockEvent] = []` and
> ```swift
>   func enqueueEmergencyUnblockEvent(_ event: SyncedEmergencyUnblockEvent) throws {
>     if let errorToThrow { throw errorToThrow }
>     enqueuedEmergencyUnblockEvents.append(event)
>   }
> ```

- [ ] **Step 5: Run funnel tests — expect PASS**

Run: `xcodebuild test ... -only-testing:FoqosTests/MutationFunnelTests | xcpretty`

**S0 conformance note:** the event is a synced entity whose ONLY push origin is this funnel method (I2). Write-once records never need update/tie logic. Facade layering matches every other funnel verb.

- [ ] **Step 6: Commit**
```bash
git add Foqos/CloudKit/SyncEngine/MutationFunnel.swift Foqos/CloudKit/SyncEngine/SyncEngineControlling.swift Foqos/CloudKit/SyncEngine/SyncEngineController+Cutover.swift Foqos/CloudKit/ProfileSyncManager.swift FoqosTests/MutationFunnelTests.swift FoqosTests/Mocks
git commit -m "feat(#221): MutationFunnel + facades for emergency-unblock event enqueue"
```

---

### Task 4c: RecordProvider materialization + inbound union apply

**Files:**
- Modify: `Foqos/CloudKit/SyncEngine/RecordProvider.swift` (materialize event by recordName).
- Modify: `Foqos/CloudKit/SyncEngine/SyncApplyService.swift` (dispatch + `applyUnblockEventModification`).
- Test: extend `FoqosTests/RecordProviderTests.swift`; create `FoqosTests/EmergencyUnblockUnionApplyTests.swift`.

**Interfaces:**
- Consumes: `RecordProvider.record(forRecordName:)` (`:29`); `SyncApplyService.applyFetchedModification` dispatch (`:70`); `emergencyManager` (both hold a reference).
- Produces: an `EmergencyUnblockEvent` case in both dispatchers.

- [ ] **Step 1: Write the failing apply test**

Create `FoqosTests/EmergencyUnblockUnionApplyTests.swift`. Build `SyncApplyService` exactly as `SyncApplyServiceTests.makeService()` does (that helper is `private` to its file, so replicate it here), with an `emergencyManager` on a test `UserDefaults` so the ledger is isolated:
```swift
import CloudKit
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class EmergencyUnblockUnionApplyTests: XCTestCase {

  private var container: ModelContainer!
  private var context: ModelContext!
  private var store: SyncEngineStore!
  private var emergencyManager: EmergencyUnblockManager!
  private var storeDefaults: UserDefaults!
  private var emgDefaults: UserDefaults!
  private var storeSuite: String!
  private var emgSuite: String!
  private let zoneID = CKRecordZone.ID(
    zoneName: CloudKitConstants.syncZoneName, ownerName: CKCurrentUserDefaultName)

  override func setUp() async throws {
    try await super.setUp()
    storeSuite = "UnionApply-store-\(UUID().uuidString)"
    emgSuite = "UnionApply-emg-\(UUID().uuidString)"
    storeDefaults = UserDefaults(suiteName: storeSuite)!
    emgDefaults = UserDefaults(suiteName: emgSuite)!
    SharedData.configure(suite: UserDefaults(suiteName: "UnionApply-shared-\(UUID().uuidString)")!)
    store = SyncEngineStore(userRecordName: "user-1", defaults: storeDefaults)
    container = try TestModelContainer.create()
    context = container.mainContext
    emergencyManager = EmergencyUnblockManager(defaults: emgDefaults)
    emergencyManager.seedForTesting(allowance: 3, epoch: 1)
  }

  override func tearDown() async throws {
    UserDefaults().removePersistentDomain(forName: storeSuite)
    UserDefaults().removePersistentDomain(forName: emgSuite)
    try await super.tearDown()
  }

  private func makeService() -> SyncApplyService {
    SyncApplyService(
      modelContext: context, store: store, sessionController: MockSessionController(),
      emergencyManager: emergencyManager, deviceId: "device-A")
  }

  func testGivenRemoteUnblockEvent_WhenApplied_ThenMergedAndCountDrops() {
    let now = Date()
    let apply = makeService()
    let event = SyncedEmergencyUnblockEvent(id: UUID(), deviceId: "peer", consumedAt: now, resetEpoch: 1)
    let record = event.toCKRecord(in: zoneID)

    _ = apply.applyFetchedModification(record, isPendingDeleteOrTombstoned: { _ in false })
    XCTAssertEqual(emergencyManager.getRemainingEmergencyUnblocks(), 2)

    _ = apply.applyFetchedModification(record, isPendingDeleteOrTombstoned: { _ in false })
    XCTAssertEqual(emergencyManager.getRemainingEmergencyUnblocks(), 2, "idempotent union")
  }
}
```
> `MockSessionController` is the existing test double used by `SyncApplyServiceTests`; `seedForTesting`/`EmergencyUnblockManager(defaults:)` come from Task 4a. Confirm `SyncApplyService`'s init label set during Task 0 (it is `modelContext:store:sessionController:emergencyManager:deviceId:` at `4307654`).

- [ ] **Step 2: Run — expect FAIL** (event type falls through to `.ignored`)

- [ ] **Step 3: Add the apply dispatch + handler** (in `SyncApplyService.swift`)

In `applyFetchedModification`'s `switch record.recordType` (lines 70-83), add:
```swift
    case SyncedEmergencyUnblockEvent.recordType:
      return applyUnblockEventModification(record)
```
Add the handler:
```swift
  // MARK: - Emergency unblock event apply (#221 union / G-Set)

  private func applyUnblockEventModification(_ record: CKRecord) -> ApplyOutcome {
    guard let event = SyncedEmergencyUnblockEvent(from: record) else {
      Log.info("Ignoring undecodable EmergencyUnblockEvent record", category: .sync)
      return .ignored
    }
    emergencyManager.mergeRemoteUnblockEvent(event)  // idempotent union
    store.removeFailedApply(recordName: record.recordID.recordName)  // supersession (§5.6)
    storeSystemFields(record)
    return .applied
  }
```

- [ ] **Step 4: Add RecordProvider materialization** (in `RecordProvider.record(forRecordName:)`, before the `UUID(uuidString:)` branch)
```swift
    if recordName.hasPrefix(SyncedEmergencyUnblockEvent.recordNamePrefix) {
      guard let event = emergencyManager.eventRecord(forRecordName: recordName) else { return nil }
      let record = materialize(
        recordName: recordName,
        recordType: SyncedEmergencyUnblockEvent.recordType,
        freshRecordID: CKRecord.ID(recordName: recordName, zoneID: zoneID))
      event.updateCKRecord(record)
      return record
    }
```

- [ ] **Step 5: Run apply + RecordProvider tests — expect PASS**

Run: `xcodebuild test ... -only-testing:FoqosTests/EmergencyUnblockUnionApplyTests -only-testing:FoqosTests/RecordProviderTests | xcpretty`

**S0 conformance note:** inbound apply performs a pure idempotent union (no push). RecordProvider materialization reuses `materialize(...)` (cached system fields ⇒ change-tag-correct) exactly like profiles/locations. Events are never mutated, so there is no version/tie path. Deletion (GC) is handled explicitly in Task 4e via `applyFetchedDeletion`.

- [ ] **Step 6: Commit**
```bash
git add Foqos/CloudKit/SyncEngine/RecordProvider.swift Foqos/CloudKit/SyncEngine/SyncApplyService.swift FoqosTests/EmergencyUnblockUnionApplyTests.swift FoqosTests/RecordProviderTests.swift
git commit -m "feat(#221): inbound union apply + RecordProvider materialization for unblock events"
```

---

### Task 4d: consume through the funnel; reset advances the epoch; drop the LWW scalar

**Files:**
- Modify: `Foqos/Utils/EmergencyUnblockManager.swift` (`performEmergencyUnblock`, `emergencyUnblock` gate, resets, `applyRemoteEmergencySettings`, `currentEmergencySettings`).
- Modify: `Foqos/CloudKit/SyncEngine/SyncApplyService.swift` (`applyEmergencyModification` — apply config incl. epoch, stop overwriting the count).
- Test: extend `FoqosTests/EmergencyUnblockEventLedgerTests.swift` (or a new `EmergencyUnblockConsumeTests.swift`).

- [ ] **Step 1: Write the failing tests**

Driving the full `emergencyUnblock(...)` path needs a live `BlockedProfileSession`, which no existing test constructs. Instead test the seam that carries the #221 behavior — a new internal `recordAndEnqueueUnblock(now:)` (added in Step 2) — plus reset. Create `FoqosTests/EmergencyUnblockConsumeTests.swift`:
```swift
import XCTest

@testable import FamilyFoqos

@MainActor
final class EmergencyUnblockConsumeTests: XCTestCase {

  private var emgSuite: String!
  private var emgDefaults: UserDefaults!
  private var savedController: (any SyncEngineControlling)?
  private var savedEnabled = false
  private var mock: MockSyncEngineControlling!

  override func setUp() {
    super.setUp()
    emgSuite = "Consume-emg-\(UUID().uuidString)"
    emgDefaults = UserDefaults(suiteName: emgSuite)!
    savedController = ProfileSyncManager.shared.engineController
    savedEnabled = ProfileSyncManager.shared.isEnabled
    mock = MockSyncEngineControlling()
    ProfileSyncManager.shared.engineController = mock
    ProfileSyncManager.shared.isEnabled = true
  }
  override func tearDown() {
    ProfileSyncManager.shared.engineController = savedController
    ProfileSyncManager.shared.isEnabled = savedEnabled
    emgDefaults.removePersistentDomain(forName: emgSuite)
    super.tearDown()
  }

  func testGivenSyncEnabled_WhenRecordAndEnqueueUnblock_ThenEventEnqueuedAndRemainingDrops() {
    let now = Date()
    let manager = EmergencyUnblockManager(defaults: emgDefaults, profileSyncManager: .shared)
    manager.seedForTesting(allowance: 3, epoch: 1)

    manager.recordAndEnqueueUnblock(now: now)

    XCTAssertEqual(manager.getRemainingEmergencyUnblocks(), 2)
    XCTAssertEqual(mock.enqueuedEmergencyUnblockEvents.count, 1, "one event pushed through the funnel")
    XCTAssertEqual(mock.enqueuedEmergencyUnblockEvents.first?.resetEpoch, 1)
  }

  func testGivenConsumedUnblocks_WhenReset_ThenEpochAdvancesAndRemainingRestored() {
    let now = Date()
    let manager = EmergencyUnblockManager(defaults: emgDefaults, profileSyncManager: .shared)
    manager.seedForTesting(allowance: 3, epoch: 1)
    manager.recordAndEnqueueUnblock(now: now)
    manager.recordAndEnqueueUnblock(now: now)
    XCTAssertEqual(manager.getRemainingEmergencyUnblocks(), 1)

    manager.resetEmergencyUnblocks()

    XCTAssertEqual(manager.currentResetEpoch, 2, "reset advances the epoch")
    XCTAssertEqual(manager.getRemainingEmergencyUnblocks(), 3, "prior-epoch events no longer count")
  }
}
```
> `EmergencyUnblockManager(defaults:profileSyncManager:)` — Task 4a adds `defaults:`; `profileSyncManager:` already exists (`EmergencyUnblockManager.swift:47`). `MockSyncEngineControlling` gained `enqueuedEmergencyUnblockEvents` in Task 4b.

- [ ] **Step 2: Add the consume seam and route `performEmergencyUnblock` through it**

Add the testable seam to `EmergencyUnblockManager`:
```swift
  /// #221: record a consumed unblock as an immutable event and push it through the funnel.
  /// Extracted from `performEmergencyUnblock` so the record+enqueue is unit-testable without a
  /// live session. Returns the event.
  @discardableResult
  func recordAndEnqueueUnblock(now: Date = Date()) -> SyncedEmergencyUnblockEvent {
    let event = consumeUnblockEvent(now: now)
    if profileSyncManager.isEnabled {
      do {
        try profileSyncManager.enqueueEmergencyUnblockEvent(event)
      } catch {
        Log.warning(
          "enqueueEmergencyUnblockEvent skipped: \(error.localizedDescription)", category: .sync)
      }
    }
    return event
  }
```
Rewrite `performEmergencyUnblock` (lines 220-233) to use it:
```swift
  private func performEmergencyUnblock(
    context: ModelContext,
    session: BlockedProfileSession,
    onUnblock: @escaping (ModelContext, BlockedProfileSession) -> Void,
    now: Date = Date()
  ) {
    onUnblock(context, session)
    recordAndEnqueueUnblock(now: now)  // #221: event + funnel push replaces the scalar decrement
    WidgetCenter.shared.reloadTimelines(ofKind: "ProfileControlWidget")
  }
```
(Thread `now` from `emergencyUnblock(...)` for test-time pinning — add a `now: Date = Date()` param there and pass it down. The gate `guard emergencyUnblocksRemaining > 0` at line 198 becomes `guard getRemainingEmergencyUnblocks() > 0`.)

- [ ] **Step 3: Resets advance the epoch**

Rewrite `resetEmergencyUnblocks()` and the elapsed-period branch of `checkAndResetEmergencyUnblocks()` to advance the epoch instead of setting the scalar to 3:
```swift
  func resetEmergencyUnblocks() {
    currentResetEpoch += 1
    lastEmergencyUnblocksResetDateTimestamp = Date().timeIntervalSinceReferenceDate
    pushEmergencySettingsToCloudKit()  // propagates the new epoch via config LWW
    objectWillChange.send()
  }
```
(Do the same epoch-advance in `checkAndResetEmergencyUnblocks`'s elapsed branch; remove the `emergencyUnblocksRemaining = 3` assignments.)

- [ ] **Step 4: Config apply carries the epoch; count is no longer overwritten**

In `applyRemoteEmergencySettings` (line 238), remove `emergencyUnblocksRemaining = remote.unblocksRemaining` and instead adopt the epoch as the max (monotonic, so a lagging device never rewinds):
```swift
  func applyRemoteEmergencySettings(_ remote: SyncedEmergencySettings) {
    emergencyUnblocksResetPeriodInDays = remote.resetPeriodInDays
    lastEmergencyUnblocksResetDateTimestamp = remote.lastResetDate.timeIntervalSinceReferenceDate
    emergencySettingsLockedStorage = remote.settingsLocked
    emergencySettingsVersion = remote.version
    currentResetEpoch = max(currentResetEpoch, remote.resetEpoch)
    objectWillChange.send()
  }
```
In `currentEmergencySettings` (line 248), include `resetEpoch: currentResetEpoch` and set `unblocksRemaining: getRemainingEmergencyUnblocks()` (still emitted for informational/back-compat, but no longer authoritative — the derived count is source of truth). In `applyEmergencyModification` (`SyncApplyService.swift:443`), keep the versioned-LWW gate for CONFIG only; it calls `applyRemoteEmergencySettings`, which no longer touches the count — no code change needed there beyond confirming it compiles.

- [ ] **Step 5: Delete the now-dead scalar plumbing**

Remove the `@Published private var emergencyUnblocksRemaining` stored property (lines 61-69) and its `DefaultsKey.unblocksRemaining`, plus any remaining assignments. `getRemainingEmergencyUnblocks()` is now the sole source. Grep to confirm no other reader: `grep -rn 'emergencyUnblocksRemaining' Foqos`. Fix any remaining reference to call `getRemainingEmergencyUnblocks()`.

- [ ] **Step 6: Run the emergency suite + snapshot tests — expect PASS**

Run: `xcodebuild test ... -only-testing:FoqosTests/EmergencyUnblockEventLedgerTests -only-testing:FoqosTests/EmergencyUnblockManagerSnapshotTests -only-testing:FoqosTests/EmergencyUnblockUnionApplyTests | xcpretty`
> `EmergencyUnblockManagerSnapshotTests` may assert on the old scalar — update those assertions to the derived count / epoch model (they are testing this manager's own contract, which is legitimately changing). Do not weaken them; re-express them against `getRemainingEmergencyUnblocks()`/`currentResetEpoch`.

**S0 conformance note:** consumption pushes ONLY via `enqueueEmergencyUnblockEvent` (funnel, I2). Config (period/locked/epoch) still syncs via the existing versioned-LWW `SyncedEmergencySettings` — legitimate for parent-set config. No inbound path writes the count; it is derived locally from the unioned ledger.

**Convergence residual (flag for maintainer sign-off):** the union *ledger* converges unconditionally (G-Set), but the `resetEpoch` that scopes the count rides the config's versioned-LWW channel, which inherits that channel's same-version divergence: if device A makes a non-reset config change to version N (epoch unchanged) while device B resets to version N (epoch+1), each device's `remote.version > local.version` gate rejects the other's record and the two epochs can diverge — so the derived remaining count could differ across devices until the next strictly-greater config write reconciles them. This is an accepted limitation of reusing the config LWW channel (the `max(currentResetEpoch, remote.resetEpoch)` adoption bounds it monotonically upward, never rewinding). If stronger epoch convergence is required, carry `resetEpoch` on a monotonic-max channel independent of the version gate — note this option for the maintainer rather than silently claiming full convergence.

- [ ] **Step 7: Commit**
```bash
git add Foqos/Utils/EmergencyUnblockManager.swift Foqos/CloudKit/SyncEngine/SyncApplyService.swift FoqosTests/
git commit -m "feat(#221): consume unblocks as funnel events; resets advance epoch; drop LWW count"
```

---

### Task 4e: epoch-GC of stale events (rides the explicit deletion path)

**Why:** the ledger grows unbounded. GC events from epochs older than the current one, deleting them through the funnel so peers converge — never by inference.

**Files:**
- Modify: `Foqos/Utils/EmergencyUnblockManager.swift` (add `staleUnblockEventRecordNames()` + local prune).
- Modify: `Foqos/CloudKit/SyncEngine/MutationFunnel.swift` (add `enqueueDelete(unblockEventRecordName:)` — tombstone-free: events are write-once, a missing event is a no-op) OR reuse a generic delete. **Decision:** add a dedicated `enqueueEmergencyUnblockEventDelete(_ recordName:)` that mirrors `enqueueDelete(locationId:)` minus the entity re-find (the ledger is the source; prune locally, then enqueue `.deleteRecord`).
- Modify: `Foqos/CloudKit/SyncEngine/SyncApplyService.swift` (`applyFetchedDeletion` — add `EmergencyUnblockEvent` case to prune the local ledger).
- Test: extend the ledger/apply tests with a GC round-trip.

- [ ] **Step 1: Write the failing GC test**

Create `FoqosTests/EmergencyUnblockGCTests.swift` (same spy setUp/tearDown as `EmergencyUnblockConsumeTests` — save/restore `ProfileSyncManager.shared.engineController` + `isEnabled`, inject `mock`, isolate `emgDefaults`):
```swift
  func testGivenStaleEpochEvents_WhenGC_ThenRemovedLocallyAndDeletesEnqueued() {
    let now = Date()
    let manager = EmergencyUnblockManager(defaults: emgDefaults, profileSyncManager: .shared)
    manager.seedForTesting(allowance: 3, epoch: 1)
    let e1 = manager.consumeUnblockEvent(now: now)
    let e2 = manager.consumeUnblockEvent(now: now)
    manager.advanceResetEpochForTesting()  // epoch 1 → 2; e1/e2 are now stale

    manager.garbageCollectStaleUnblockEvents()

    XCTAssertEqual(mock.enqueuedEmergencyUnblockEventDeletes.count, 2, "one delete per stale event")
    XCTAssertTrue(mock.enqueuedEmergencyUnblockEventDeletes.contains(e1.recordName))
    XCTAssertTrue(mock.enqueuedEmergencyUnblockEventDeletes.contains(e2.recordName))
    XCTAssertTrue(manager.staleUnblockEventRecordNames().isEmpty, "stale events pruned locally")
  }
```
Also add an inbound-deletion assertion as a method inside `EmergencyUnblockUnionApplyTests` (Task 4c — it already builds the service + emergencyManager):
```swift
  func testGivenUnblockEventDeletion_WhenApplied_ThenRemovedFromLedgerIdempotently() {
    let now = Date()
    let apply = makeService()
    let event = SyncedEmergencyUnblockEvent(id: UUID(), deviceId: "peer", consumedAt: now, resetEpoch: 1)
    _ = apply.applyFetchedModification(event.toCKRecord(in: zoneID), isPendingDeleteOrTombstoned: { _ in false })
    XCTAssertEqual(emergencyManager.getRemainingEmergencyUnblocks(), 2)

    let recordID = CKRecord.ID(recordName: event.recordName, zoneID: zoneID)
    let outcome = apply.applyFetchedDeletion(recordID: recordID, recordType: SyncedEmergencyUnblockEvent.recordType)
    XCTAssertEqual(outcome, .deleted)
    XCTAssertEqual(emergencyManager.getRemainingEmergencyUnblocks(), 3, "event removed from ledger")
    // Idempotent re-delivery:
    _ = apply.applyFetchedDeletion(recordID: recordID, recordType: SyncedEmergencyUnblockEvent.recordType)
    XCTAssertEqual(emergencyManager.getRemainingEmergencyUnblocks(), 3)
  }
```

- [ ] **Step 2: Implement** — add to `EmergencyUnblockManager`:
```swift
  /// Record names of events from epochs older than the current one (safe to GC).
  func staleUnblockEventRecordNames() -> [String] {
    unblockEvents.filter { $0.resetEpoch < currentResetEpoch }.map { $0.recordName }
  }

  /// Remove an event from the local ledger by recordName (used by GC and by inbound deletion apply).
  func removeUnblockEvent(recordName: String) {
    unblockEvents = unblockEvents.filter { $0.recordName != recordName }
    objectWillChange.send()
  }
```
Add the funnel delete method (in `MutationFunnel.swift`, "Delete paths"):
```swift
  /// Delete a write-once emergency-unblock event (#221 GC). Events carry no tombstone (they are
  /// immutable and idempotent to re-create/absent-delete), so this just enqueues one .deleteRecord.
  func enqueueEmergencyUnblockEventDelete(_ recordName: String) {
    let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
    driver.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
  }
```
Facade it at the three seams (protocol + Cutover + ProfileSyncManager), mirroring Task 4b. **Also add the method to `FoqosTests/Mocks/MockSyncEngineControlling.swift`** (it conforms to the protocol, so the test target won't compile otherwise): `private(set) var enqueuedEmergencyUnblockEventDeletes: [String] = []` and
```swift
  func enqueueEmergencyUnblockEventDelete(_ recordName: String) throws {
    if let errorToThrow { throw errorToThrow }
    enqueuedEmergencyUnblockEventDeletes.append(recordName)
  }
```
Add the inbound deletion case in `SyncApplyService.applyFetchedDeletion` (`:88`):
```swift
    case SyncedEmergencyUnblockEvent.recordType:
      emergencyManager.removeUnblockEvent(recordName: recordName)
      clearDeletionBookkeeping(recordName: recordName)
      return .deleted
```
Add a GC entry point on `EmergencyUnblockManager` (call it after a reset and on app foreground; the reset already advances the epoch — after `pushEmergencySettingsToCloudKit()` in `resetEmergencyUnblocks`, prune locally + enqueue deletes):
```swift
  func garbageCollectStaleUnblockEvents() {
    let stale = staleUnblockEventRecordNames()
    guard !stale.isEmpty else { return }
    for name in stale {
      removeUnblockEvent(recordName: name)
      if profileSyncManager.isEnabled {
        try? profileSyncManager.enqueueEmergencyUnblockEventDelete(name)
      }
    }
  }
```
Call `garbageCollectStaleUnblockEvents()` at the end of `resetEmergencyUnblocks()` and the elapsed branch of `checkAndResetEmergencyUnblocks()`.

- [ ] **Step 3: Run GC tests + full emergency suite — expect PASS**

**S0 conformance note:** GC rides the explicit funnel delete + explicit inbound `applyFetchedDeletion` deletion event — never orphan inference. Immutable events need no tombstone (absent-delete is a harmless no-op; re-creation is impossible since ids are unique-per-consume).

- [ ] **Step 4: Commit**
```bash
git add Foqos/Utils/EmergencyUnblockManager.swift Foqos/CloudKit/SyncEngine/MutationFunnel.swift Foqos/CloudKit/SyncEngine/SyncEngineControlling.swift Foqos/CloudKit/SyncEngine/SyncEngineController+Cutover.swift Foqos/CloudKit/ProfileSyncManager.swift Foqos/CloudKit/SyncEngine/SyncApplyService.swift FoqosTests/
git commit -m "feat(#221): epoch-GC stale unblock events via explicit funnel deletion"
```

---

## Final verification (whole bundle)

- [ ] **Run the full FoqosTests suite** against the booted simulator UUID; expect green.
  `xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' | xcpretty`
- [ ] **Run the sync-guard CI check** (S0 invariant guard): `./scripts/check-sync-guards.sh` (expect pass — no new raw `@Query`, no funnel bypass).
- [ ] **swift-format lint clean:** `swift-format lint --recursive . && echo OK`
- [ ] **Request code review before merging** (AGENTS.md requirement). The PR description must restate the two maintainer decisions (Task 3 Option B, Task 4 Option C) and the #222 idempotent-success choice so the reviewer ratifies them.

## Self-review checklist (planner ran this)

- Spec coverage: #265 (Task 1), #222 (Task 2), #218 (Task 3), #221 (Task 4a–4e). #219 is closed by #267 (no query in sync path) — not in scope.
- All code steps show complete code; no "TODO"/"similar to"/"add validation" placeholders.
- Type consistency: `remoteWinsProfileTie`, `SyncedEmergencyUnblockEvent`, `enqueueEmergencyUnblockEvent`, `getRemainingEmergencyUnblocks`, `currentResetEpoch` used consistently across tasks.
- Every mutating task carries an S0 conformance note; every task ends with a commit.
