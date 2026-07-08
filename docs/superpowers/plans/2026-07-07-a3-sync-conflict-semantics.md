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

> **grep portability (PR #292 review N3):** multi-pattern greps use `grep -nF -e … -e …` (fixed strings, one `-e` per pattern) rather than BRE `\|` alternation, so they are portable across BSD/macOS and GNU `grep` and never treat `.`/`(` as regex metacharacters. Apply the same form to any other multi-pattern grep in this plan if you copy it. (On this repo's `/usr/bin/grep` — "BSD grep, GNU compatible" — `\|` happens to work, but `-F -e` is portable and precise everywhere.)

```bash
grep -nF -e 'func applyDecodedProfile' -e 'synced.version == existing.syncVersion' -e 'pendingReenqueues.append' Foqos/CloudKit/SyncEngine/SyncApplyService.swift
grep -nF -e 'func applyEmergencyModification' -e 'applyRemoteEmergencySettings' -e 'performEmergencyUnblock' -e 'emergencyUnblocksRemaining' -e 'currentResetEpoch' Foqos/Utils/EmergencyUnblockManager.swift Foqos/CloudKit/SyncEngine/SyncApplyService.swift
grep -nF -e 'reminderTimeInSeconds' -e 'UInt8(exactly:' Foqos/CloudKit/SyncModels.swift
grep -nF -e 'func sendCommand' -e 'serverRecordChanged' Foqos/CloudKit/CloudKitNetworkService+Commands.swift Foqos/CloudKit/SessionSyncService.swift
```

- [ ] **Step 3: Boot the test simulator once** (per AGENTS.md — reuse it for every task)

```bash
xcrun simctl list devices available | grep "iPhone 17"   # pick the UUID
xcrun simctl boot <UUID>
```

---

## Maintainer decisions in this bundle — SETTLED (2026-07-08, PR #292 review)

Both decisions are ratified; the tasks implement them.

- **#218 tie-break policy** (Task 3): **Option B — deterministic winner: `updatedAt`, then `originDeviceId`.** Deterministic, no server round-trip. Also fixes the equal-version conflict-copy bug at `SyncConflictManager.swift:64` (the "older app version" message reused for a same-version tie). Options A/C recorded in Task 3.
- **#221 count semantics** (Task 4): **Option C — union of immutable usage-event records (G-Set)**, WITH two maintainer refinements folded in:
  - **Mandatory pruning** — prune usage-event records whose `resetEpoch < currentResetEpoch` (unbounded records are rejected). Task 4e.
  - **Epoch on a SEPARATE monotonic-max channel** (`SyncedEmergencyEpoch`), NOT config LWW — supersedes the old "accept the residual" note; the residual is **closed**. Tasks 4a/4c/4d.
  - Option B (CAS delta-retry counter arithmetic) remains *flagged, not chosen*.
  - The pruning × monotonic-max-epoch interaction is discharged in the **Skeptic Pass** section at the end of Task 4.

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

- [ ] **Step 2: Confirm the red state — note the trap ABORTS the test runner (it is not a clean XCTest failure)**

The pre-fix `UInt32(reminderInt)` is a **fatal trap**: it does not produce an `XCTFail`, it aborts the whole test process (`Fatal error: Not enough bits to represent…`), so you cannot run these two cases red-then-green in the normal suite — the runner dies before reporting. Confirm the red state one of two ways instead of running the full suite: (a) reason from the code (`UInt32(_:)` traps on out-of-range; the value flows in unguarded at `SyncModels.swift:200`), or (b) temporarily run ONLY the guard tests against the unpatched code (`-only-testing:FoqosTests/SyncedProfileDecodeBoundsTests`) and observe the process-abort/crash log — expected, and it confirms the trap. Then apply Step 3; after the fix the same two cases pass cleanly (nil, no trap). Do NOT leave the trap-triggering red run wired into CI.

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

### MAINTAINER DECISION — tie-break policy: **Option B, SETTLED (2026-07-08)**

- **Option A — local-always-wins (current).** No data silently lost, surfaced via banner, but non-converging (version escalation risk). *Rejected: doesn't converge.*
- **Option B — deterministic winner (SETTLED — implemented below).** On a payload-differing tie, both devices pick the SAME winner from a total order already carried in `SyncedProfile`: newer `updatedAt` wins; ties broken by lexicographically-lower `originDeviceId`. Winner keeps+bumps+re-enqueues; loser *adopts* the winner's payload. Both converge to identical data in ≤2 sync rounds; one concurrent edit is dropped but surfaced via a banner. *Chosen — deterministic, no server round-trip.*
- **Option C — field-level 3-way merge.** High complexity, needs per-field base tracking. *Rejected: out of scope.*

The decision is ratified — implement Option B in full (Steps 1-8). The copy fix (Steps 5-7) also resolves the maintainer-cited equal-version copy bug at `SyncConflictManager.swift:64`: routing ties through the new `divergenceProfiles` category means the tie no longer reuses that line's "older app version" schema-mismatch wording.

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

**Design** (maintainer-ratified 2026-07-08 — union of usage events + reset-epoch on its OWN monotonic-max channel + **mandatory** epoch-based pruning). Model consumption events like sessions (a recordName-prefixed non-SwiftData entity — **no ModelContainer schema change**), stored in `EmergencyUnblockManager` (co-located with the state they replace):
- Record type `EmergencyUnblockEvent`, recordName `EmergencyUnblock_<uuid>`, fields `deviceId: String`, `consumedAt: Date`, `resetEpoch: Int` (the epoch the unblock was consumed in — tagged on the event).
- The event ledger is a persisted `[EmergencyUnblockEvent]` (UserDefaults JSON, like the existing counters). Union on apply = insert-if-absent by `id` (a G-Set). `remaining = max(0, allowance − |events where resetEpoch == currentResetEpoch|)`, `allowance = 3`.
- **`resetEpoch` syncs on a DEDICATED monotonic-max channel — a single fixed-name `SyncedEmergencyEpoch` record (`emergency-reset-epoch`), NOT the config LWW record.** Apply is `currentResetEpoch = max(local, remote.epoch)` with **no version gate**: a monotonic-max merge is commutative, idempotent, and order-independent, so it can never be clobbered by a stale writer and every device converges on one agreed epoch boundary. This is the property that makes cleanup race-free — it is why the epoch does NOT ride the config channel (a transient LWW desync there could let one device prune events another still counts). One source of truth for the epoch; `resetEpoch` is removed from `SyncedEmergencySettings` entirely.
- A reset advances `resetEpoch` (`+1`) and pushes it on the monotonic-max channel; old-epoch events stop counting immediately (epoch predicate) and are **MANDATORILY pruned** (Step 4e) — the maintainer will not accept unbounded historic records. **Pruning reads the merged `currentResetEpoch` and deletes only strictly-less-than (`event.resetEpoch < currentResetEpoch`)**, never a locally-bumped-but-unsynced value.
- All mutations ride `MutationFunnel`: consuming an unblock enqueues an event save; a reset enqueues an epoch save; GC enqueues event deletes.

This is a multi-part task; each sub-task (4a–4e) is independently testable.

**Interfaces produced (used across sub-tasks):**
- `struct SyncedEmergencyUnblockEvent: Codable, Equatable` in `SyncModels.swift` — `id: UUID`, `deviceId: String`, `consumedAt: Date`, `resetEpoch: Int`; `static let recordType = "EmergencyUnblockEvent"`, `static let recordNamePrefix = "EmergencyUnblock_"`, `var recordName: String { Self.recordNamePrefix + id.uuidString }`; `toCKRecord(in:)` / `updateCKRecord(_:)` / `init?(from:)`.
- `struct SyncedEmergencyEpoch: Codable, Equatable` in `SyncModels.swift` — `epoch: Int`; `static let recordType = "EmergencyResetEpoch"`, `static let recordName = "emergency-reset-epoch"` (fixed, single record); `toCKRecord(in:)` / `updateCKRecord(_:)` / `init?(from:)`. Merged by max, never version-gated.
- `EmergencyUnblockManager`: `func consumeUnblockEvent(now: Date) -> SyncedEmergencyUnblockEvent`; `func mergeRemoteUnblockEvent(_:)` (union insert); `func eventRecord(forRecordName:) -> SyncedEmergencyUnblockEvent?`; `var currentResetEpoch: Int`; `func adoptRemoteEpoch(_ epoch: Int)` (`currentResetEpoch = max(currentResetEpoch, epoch)`); `func currentEpochRecord() -> SyncedEmergencyEpoch`; derived `getRemainingEmergencyUnblocks()`.
- `MutationFunnel.enqueueEmergencyUnblockEvent(_ event:)`, `.enqueueEmergencyEpochSave()`, `.enqueueEmergencyUnblockEventDelete(_ recordName:)` + facades on `SyncEngineControlling` / `SyncEngineController+Cutover` / `ProfileSyncManager` mirroring `enqueueEmergencySettingsSave`.

---

### Task 4a: the event model + derived count + epoch (no sync wiring yet)

**Files:**
- Modify: `Foqos/CloudKit/SyncModels.swift` (add `SyncedEmergencyUnblockEvent` and `SyncedEmergencyEpoch`; do NOT add a `resetEpoch` field to `SyncedEmergencySettings` — the epoch lives only on its own channel).
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

In `SyncModels.swift`, add the dedicated monotonic-max epoch record (leave `SyncedEmergencySettings` untouched — the epoch does NOT live there):
```swift
// MARK: - Synced Emergency Reset Epoch (monotonic-max channel — never version-gated)

/// The current emergency-unblock reset epoch, synced as a single fixed-name record and merged by
/// `max()` (commutative/idempotent/order-independent) so all devices converge on one agreed epoch
/// boundary. This is what makes epoch-based pruning race-free (#221). NOT on the config LWW record.
struct SyncedEmergencyEpoch: Codable, Equatable {
  var epoch: Int

  static let recordType = "EmergencyResetEpoch"
  static let recordName = "emergency-reset-epoch"

  enum FieldKey: String { case epoch }

  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let record = CKRecord(
      recordType: Self.recordType,
      recordID: CKRecord.ID(recordName: Self.recordName, zoneID: zoneID))
    updateCKRecord(record)
    return record
  }

  func updateCKRecord(_ record: CKRecord) {
    record[FieldKey.epoch.rawValue] = epoch
  }

  init(epoch: Int) { self.epoch = epoch }

  init?(from record: CKRecord) {
    guard record.recordType == Self.recordType,
      let epoch = record[FieldKey.epoch.rawValue] as? Int
    else { return nil }
    self.epoch = epoch
  }
}
```
Then add the event struct:
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

  // MARK: - Monotonic-max reset-epoch channel (#221)

  /// Adopt a remote epoch by MAX (no version gate) — commutative/idempotent/order-independent, so
  /// every device converges on one agreed epoch boundary and a stale writer can never lower it.
  func adoptRemoteEpoch(_ epoch: Int) {
    let merged = max(currentResetEpoch, epoch)
    guard merged != currentResetEpoch else { return }
    currentResetEpoch = merged
    objectWillChange.send()
  }

  /// Materialize the current epoch record for RecordProvider / push.
  func currentEpochRecord() -> SyncedEmergencyEpoch {
    SyncedEmergencyEpoch(epoch: currentResetEpoch)
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

  /// Enqueue the single fixed-name reset-epoch record on its monotonic-max channel (#221). The new
  /// epoch value is already persisted by the reset (`currentResetEpoch`); RecordProvider serializes
  /// the current value. No version bump — the value itself is the merge key (max on apply).
  func enqueueEmergencyEpochSave() {
    let recordID = CKRecord.ID(recordName: SyncedEmergencyEpoch.recordName, zoneID: zoneID)
    driver.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
  }
```

- [ ] **Step 4: Add the facades** (mirror `enqueueEmergencySettingsSave` at all three seams — for BOTH `enqueueEmergencyUnblockEvent(_:)` and `enqueueEmergencyEpochSave()`)
- `SyncEngineControlling.swift`: add `func enqueueEmergencyUnblockEvent(_ event: SyncedEmergencyUnblockEvent) throws` and `func enqueueEmergencyEpochSave() throws`
- `SyncEngineController+Cutover.swift`:
```swift
  func enqueueEmergencyUnblockEvent(_ event: SyncedEmergencyUnblockEvent) throws {
    guard let funnel else { throw SyncEngineControllingError.notAttached }
    funnel.enqueueEmergencyUnblockEvent(event)
  }
  func enqueueEmergencyEpochSave() throws {
    guard let funnel else { throw SyncEngineControllingError.notAttached }
    funnel.enqueueEmergencyEpochSave()
  }
```
- `ProfileSyncManager.swift`:
```swift
  func enqueueEmergencyUnblockEvent(_ event: SyncedEmergencyUnblockEvent) throws {
    guard let engineController else { throw SyncEngineControllingError.notAttached }
    try engineController.enqueueEmergencyUnblockEvent(event)
  }
  func enqueueEmergencyEpochSave() throws {
    guard let engineController else { throw SyncEngineControllingError.notAttached }
    try engineController.enqueueEmergencyEpochSave()
  }
```
> **Required:** `FoqosTests/Mocks/MockSyncEngineControlling.swift` conforms to `SyncEngineControlling`, so both new protocol methods must be added there or the test target won't compile. Mirror the existing `enqueueEmergencySettingsSave` capture:
> ```swift
>   private(set) var enqueuedEmergencyUnblockEvents: [SyncedEmergencyUnblockEvent] = []
>   private(set) var enqueuedEmergencyEpochSaves = 0
>   func enqueueEmergencyUnblockEvent(_ event: SyncedEmergencyUnblockEvent) throws {
>     if let errorToThrow { throw errorToThrow }
>     enqueuedEmergencyUnblockEvents.append(event)
>   }
>   func enqueueEmergencyEpochSave() throws {
>     if let errorToThrow { throw errorToThrow }
>     enqueuedEmergencyEpochSaves += 1
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
    case SyncedEmergencyEpoch.recordType:
      return applyEmergencyEpochModification(record)
```
Add the handlers:
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

  // MARK: - Emergency reset-epoch apply (#221 monotonic-max channel — NO version gate)

  private func applyEmergencyEpochModification(_ record: CKRecord) -> ApplyOutcome {
    guard let remote = SyncedEmergencyEpoch(from: record) else {
      Log.info("Ignoring undecodable EmergencyResetEpoch record", category: .sync)
      return .ignored
    }
    // Unconditional max-merge — commutative/idempotent/order-independent. Deliberately NOT gated
    // by any version (unlike applyEmergencyModification): that gate is exactly what would let the
    // epoch desync and make pruning unsafe (maintainer decision 2026-07-08).
    emergencyManager.adoptRemoteEpoch(remote.epoch)
    store.removeFailedApply(recordName: record.recordID.recordName)
    storeSystemFields(record)
    return .applied
  }
```

- [ ] **Step 4: Add RecordProvider materialization** (in `RecordProvider.record(forRecordName:)`, before the `UUID(uuidString:)` branch)
```swift
    if recordName == SyncedEmergencyEpoch.recordName {
      let record = materialize(
        recordName: recordName,
        recordType: SyncedEmergencyEpoch.recordType,
        freshRecordID: CKRecord.ID(recordName: recordName, zoneID: zoneID))
      emergencyManager.currentEpochRecord().updateCKRecord(record)
      return record
    }
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
Add a focused apply test to `EmergencyUnblockUnionApplyTests` proving the epoch merges by max with no version gate (both directions):
```swift
  func testGivenRemoteEpoch_WhenApplied_ThenAdoptedByMaxRegardlessOfOrder() {
    let apply = makeService()  // seeded at epoch 1
    _ = apply.applyFetchedModification(
      SyncedEmergencyEpoch(epoch: 3).toCKRecord(in: zoneID), isPendingDeleteOrTombstoned: { _ in false })
    XCTAssertEqual(emergencyManager.currentResetEpoch, 3, "higher epoch adopted")
    _ = apply.applyFetchedModification(
      SyncedEmergencyEpoch(epoch: 2).toCKRecord(in: zoneID), isPendingDeleteOrTombstoned: { _ in false })
    XCTAssertEqual(emergencyManager.currentResetEpoch, 3, "lower epoch never lowers it (max, no gate)")
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
- Modify: `Foqos/CloudKit/SyncEngine/SyncApplyService.swift` (`applyEmergencyModification` — apply CONFIG only, stop overwriting the count; the epoch is a separate channel).
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
    XCTAssertEqual(
      mock.enqueuedEmergencyEpochSaves, 1, "reset pushes the epoch on its monotonic-max channel")
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

Rewrite `resetEmergencyUnblocks()` and the elapsed-period branch of `checkAndResetEmergencyUnblocks()` to advance the epoch (on its own channel) instead of setting the scalar to 3. Add a `pushEmergencyEpochToCloudKit()` helper mirroring `pushEmergencySettingsToCloudKit`:
```swift
  private func pushEmergencyEpochToCloudKit() {
    guard profileSyncManager.isEnabled else { return }
    do {
      try profileSyncManager.enqueueEmergencyEpochSave()
    } catch {
      Log.warning("enqueueEmergencyEpochSave skipped: \(error.localizedDescription)", category: .sync)
    }
  }

  func resetEmergencyUnblocks() {
    currentResetEpoch += 1
    lastEmergencyUnblocksResetDateTimestamp = Date().timeIntervalSinceReferenceDate
    pushEmergencyEpochToCloudKit()     // #221: epoch on its OWN monotonic-max channel (NOT config)
    pushEmergencySettingsToCloudKit()  // config (lastResetDate/period/locked) still syncs LWW
    objectWillChange.send()
    // NOTE: the mandatory prune (garbageCollectStaleUnblockEvents) is wired here in Task 4e —
    // it runs AFTER the epoch push and reads the merged currentResetEpoch (strictly-less-than).
  }
```
(Do the same epoch-advance + both pushes in `checkAndResetEmergencyUnblocks`'s elapsed branch; remove the `emergencyUnblocksRemaining = 3` assignments.)

- [ ] **Step 4: Config apply drops the count; the epoch is NOT on this channel**

In `applyRemoteEmergencySettings` (line 238), remove `emergencyUnblocksRemaining = remote.unblocksRemaining`. Do **not** touch the epoch here — the epoch lives only on the dedicated monotonic-max channel (`adoptRemoteEpoch`, Task 4c); reading it off the LWW config record is exactly the desync the maintainer ruled out:
```swift
  func applyRemoteEmergencySettings(_ remote: SyncedEmergencySettings) {
    emergencyUnblocksResetPeriodInDays = remote.resetPeriodInDays
    lastEmergencyUnblocksResetDateTimestamp = remote.lastResetDate.timeIntervalSinceReferenceDate
    emergencySettingsLockedStorage = remote.settingsLocked
    emergencySettingsVersion = remote.version
    objectWillChange.send()
  }
```
In `currentEmergencySettings` (line 248), set `unblocksRemaining: getRemainingEmergencyUnblocks()` (still emitted for informational/back-compat, but no longer authoritative). It carries **no** `resetEpoch` (the field was never added to `SyncedEmergencySettings`). In `applyEmergencyModification` (`SyncApplyService.swift:443`), keep the versioned-LWW gate for CONFIG only; it calls `applyRemoteEmergencySettings`, which no longer touches the count or epoch — no code change needed there beyond confirming it compiles.

- [ ] **Step 5: Delete the now-dead scalar plumbing**

Remove the `@Published private var emergencyUnblocksRemaining` stored property (lines 61-69) and its `DefaultsKey.unblocksRemaining`, plus any remaining assignments. `getRemainingEmergencyUnblocks()` is now the sole source. Grep to confirm no other reader: `grep -rn 'emergencyUnblocksRemaining' Foqos`. Fix any remaining reference to call `getRemainingEmergencyUnblocks()`.

- [ ] **Step 6: Run the emergency suite + snapshot tests — expect PASS**

Run: `xcodebuild test ... -only-testing:FoqosTests/EmergencyUnblockEventLedgerTests -only-testing:FoqosTests/EmergencyUnblockManagerSnapshotTests -only-testing:FoqosTests/EmergencyUnblockUnionApplyTests | xcpretty`
> `EmergencyUnblockManagerSnapshotTests` may assert on the old scalar — update those assertions to the derived count / epoch model (they are testing this manager's own contract, which is legitimately changing). Do not weaken them; re-express them against `getRemainingEmergencyUnblocks()`/`currentResetEpoch`.

**S0 conformance note:** consumption pushes ONLY via `enqueueEmergencyUnblockEvent` (funnel, I2). Config (period/locked/epoch) still syncs via the existing versioned-LWW `SyncedEmergencySettings` — legitimate for parent-set config. No inbound path writes the count; it is derived locally from the unioned ledger.

**Convergence (residual CLOSED — maintainer decision 2026-07-08):** the union *ledger* converges unconditionally (G-Set), and the `resetEpoch` that scopes the count now rides its **own dedicated monotonic-max channel** (`SyncedEmergencyEpoch`, Task 4a/4c) — applied by unconditional `max()` with no version gate. Because max-merge is commutative/idempotent/order-independent, two concurrent resets can never produce a "lost" epoch (both push, `max` wins deterministically) and a stale writer can never lower it, so every device converges on one agreed epoch boundary. This is what makes the mandatory pruning (Task 4e) race-free. The earlier "reuse config LWW, accept the residual" approach is **superseded**: the residual is closed, not accepted. The one remaining property to demonstrate — that partial arrival of a reset's two effects (epoch-bump vs. event/prune deletions) never *under*-counts remaining (never wrongly denies a legitimate unblock; a brief self-healing over-grant is the accepted direction) — is discharged by the Skeptic Pass section below, per the maintainer's directive.

- [ ] **Step 7: Commit**
```bash
git add Foqos/Utils/EmergencyUnblockManager.swift Foqos/CloudKit/SyncEngine/SyncApplyService.swift FoqosTests/
git commit -m "feat(#221): consume unblocks as funnel events; resets advance epoch; drop LWW count"
```

---

### Task 4e: epoch-GC of stale events (MANDATORY — rides the explicit deletion path)

**Why:** the maintainer accepts the G-Set only WITH bounded storage — unbounded historic records are rejected, so this pruning is **mandatory**, not optional hygiene. GC events from epochs strictly older than the current one, deleting them through the funnel so peers converge — never by inference. **Race-free invariant (maintainer, 2026-07-08):** the prune predicate reads the **merged** `currentResetEpoch` (the value produced by the monotonic-max channel, incl. a local `+1` on reset) and deletes only `event.resetEpoch < currentResetEpoch`. Strictly-less-than against the monotonic epoch means a pruned event's epoch is provably dead cluster-wide (no device can ever treat it as current again — epochs only advance), so a peer that hasn't yet seen the bump loses at most a transient count that self-heals when the epoch record arrives, and only ever in the over-grant (never wrongly-deny) direction. The Skeptic Pass section discharges this.

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
  /// Record names of events from epochs strictly older than the MERGED current epoch (safe to GC).
  /// Reads `currentResetEpoch` (the monotonic-max value), and only `< currentResetEpoch` — never an
  /// unmerged/locally-guessed epoch — so a pruned event's epoch is provably dead cluster-wide (#221).
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
Add a GC entry point on `EmergencyUnblockManager` (call it after a reset and on app foreground; the reset already advanced + pushed the epoch — so after `pushEmergencyEpochToCloudKit()`/`pushEmergencySettingsToCloudKit()` in `resetEmergencyUnblocks`, prune locally + enqueue deletes against the just-merged epoch):
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

### Task 4f: engine-controller wiring for the new record types (REQUIRED — the max channel is dead without it)

**Why (adversarial-pass BLOCKER):** a *fixed-name, repeatedly-updated* record (like `SyncedEmergencySettings`) only propagates its updates because the controller (a) caches the server-assigned change tag on each confirmed own-push and on `.serverRecordChanged`, gated by `scopedTypes`, and (b) re-adds a CAS-losing-but-locally-newer record via `localIsStrictlyNewer`. `SyncedEmergencyEpoch` is a fixed-name repeatedly-updated record but was in NEITHER set, so after its first push it would freeze on the server: a fresh (untagged) re-materialization collides → `.serverRecordChanged` → the higher local epoch is dropped and never re-added → peers never receive later bumps → a lagging device stays on a stale epoch and keeps counting stale-epoch events → **permanent under-count → wrong-deny** (the forbidden direction). Additionally `restorableRecordNames()` seeds neither the epoch nor the event ledger, so a T5 zone re-seed loses them permanently. This task closes both.

**Files:**
- Modify: `Foqos/CloudKit/SyncEngine/SyncEngineController.swift` (`scopedTypes` :347, `localIsStrictlyNewer` :527-557, `restorableRecordNames` :913-921).
- Modify: `Foqos/Utils/EmergencyUnblockManager.swift` (add `allUnblockEventRecordNames()`).
- Test: `FoqosTests/SyncEngineControllerTests.swift` (or the existing controller test file) — `localIsStrictlyNewer` epoch case + `restorableRecordNames` inclusion.

- [ ] **Step 1: Scope the epoch record** — add it to `scopedTypes` (`:347`) so confirmed own-pushes and `.serverRecordChanged` responses cache its change tag (events stay UNscoped — they are write-once/unique-name and never re-saved, so they never CAS-conflict on their own record):
```swift
  private static let scopedTypes: Set<String> = [
    SyncedProfile.recordType, SyncedLocation.recordType, SyncedEmergencySettings.recordType,
    SyncedEmergencyEpoch.recordType,
  ]
```

- [ ] **Step 2: Re-add a CAS-losing higher epoch** — add an `EmergencyResetEpoch` case to `localIsStrictlyNewer` (`:554`, before `default`), mirroring the `SyncedEmergencySettings` case but comparing the epoch integer. On `.serverRecordChanged` the inbound merge already `max()`-adopts the server epoch, so the provider materializes `max(local, server)`; if that exceeds the server's value the record is re-added and eventually lands:
```swift
    case SyncedEmergencyEpoch.recordType:
      guard let localRecord = provider.record(forRecordName: name) else { return false }
      let localEpoch = localRecord[SyncedEmergencyEpoch.FieldKey.epoch.rawValue] as? Int ?? 0
      let serverEpoch = server[SyncedEmergencyEpoch.FieldKey.epoch.rawValue] as? Int ?? 0
      return localEpoch > serverEpoch
```

- [ ] **Step 3: Re-seed the epoch + event ledger** — add an `allUnblockEventRecordNames()` accessor to `EmergencyUnblockManager`:
```swift
  func allUnblockEventRecordNames() -> [String] {
    unblockEvents.map { $0.recordName }
  }
```
and include the epoch record + every ledger event in `restorableRecordNames()` (`:913`), before the provider-non-nil filter (the provider branches from Task 4c/4a materialize them, so the existing `.filter { provider.record != nil }` keeps them):
```swift
    names.append(SyncedEmergencyEpoch.recordName)
    names.append(contentsOf: EmergencyUnblockManager.shared.allUnblockEventRecordNames())
```

- [ ] **Step 4: Tests**
```swift
  func testGivenHigherLocalEpoch_WhenServerRecordLower_ThenLocalIsStrictlyNewer() {
    // Seed the manager at epoch 5 via the provider; a server record at epoch 3 ⇒ re-add.
    // (Construct the controller as the existing controller tests do; build a server CKRecord
    //  SyncedEmergencyEpoch(epoch: 3).toCKRecord(in: zoneID); assert localIsStrictlyNewer == true,
    //  and == false when the server epoch is >= local.)
  }

  func testRestorableRecordNames_IncludesEpochAndEvents() {
    // With currentResetEpoch > 0 and N ledger events present, assert restorableRecordNames()
    // contains SyncedEmergencyEpoch.recordName and every event.recordName.
  }
```
> `localIsStrictlyNewer` and `restorableRecordNames` are `private`/internal on `SyncEngineController`; test them the way the existing `SyncEngineControllerTests` reach controller internals (they already construct a controller with a `RecordProvider` + `EmergencyUnblockManager`). If a member is `private`, either promote the two under test to internal (they are pure, side-effect-free) or assert via the observable behavior (a second epoch push after a simulated `.serverRecordChanged` re-enqueues a `.saveRecord` for `emergency-reset-epoch`).

**S0 conformance note:** this is pure engine-controller plumbing to make the new synced types first-class alongside the existing three — no new mutation path, no funnel bypass. It is what makes the monotonic-max epoch channel actually converge (and survive a zone re-seed), which the whole #221 correctness argument depends on.

- [ ] **Step 5: Commit**
```bash
git add Foqos/CloudKit/SyncEngine/SyncEngineController.swift Foqos/Utils/EmergencyUnblockManager.swift FoqosTests/
git commit -m "fix(#221): scope + CAS-re-add + re-seed the epoch/event records (max channel converges)"
```

---

## Skeptic Pass — #221 pruning × monotonic-max epoch (maintainer-directed, PR #292)

The maintainer required the adversarial re-run to discharge two interleavings before merge. Both are recorded here; the implementer MUST turn each into an explicit test (named below) and must not merge if either fails.

**Invariant to protect:** the derived remaining count must never *under*-count remaining (never wrongly DENY a legitimate unblock). A brief *over*-count that self-heals is the accepted direction (same bound as the original residual). Consumption count = `|events where resetEpoch == currentResetEpoch|`; `currentResetEpoch` only ever moves up (local `+1` on reset, or `max()` on remote adopt).

**Interleaving A — reset-and-prune races ahead of a lagging peer.** Device A resets (epoch 1→2), pushes the epoch on the monotonic-max channel, and prunes its epoch-1 events (enqueuing `.deleteRecord`s). Device B has NOT yet received epoch 2.
- A's prune reads A's **merged** `currentResetEpoch` (=2) and deletes only `resetEpoch < 2`. Epoch-1 is now dead cluster-wide: because the epoch channel is monotonic, B can only ever converge to ≥2, so no device will ever again treat epoch-1 as its current epoch. Deleting epoch-1 events therefore removes data that can never legitimately be counted again.
- If B receives the event `.deleteRecord`s **before** the epoch record: B (still at epoch 1) loses some epoch-1 events → B's epoch-1 count drops → B momentarily shows *more* remaining (over-count, the accepted direction) → heals the instant the epoch-2 record arrives (adopt-by-max → remaining resets to full for epoch 2 regardless of the epoch-1 ledger).
- If B receives the epoch record **first**: B adopts epoch 2, epoch-1 events already stop counting, the later deletions are no-ops. No transient error.
- Test `testGivenPeerPrunedBeforeEpochSeen_ThenNeverUnderCounts`: seed B at epoch 1 with 2 epoch-1 events (remaining 1); apply epoch-1 event deletions with epoch record NOT yet applied; assert remaining ≥ 1 (never < the true value); then apply `SyncedEmergencyEpoch(epoch: 2)`; assert remaining == 3.

**Interleaving B — a reset's two effects arrive singly / out of order.** A reset produces (i) the epoch bump (monotonic channel) and (ii) the prune deletions. A peer may see either alone or in either order.
- epoch-only arrives: adopt-by-max → old-epoch events filtered out of the count immediately (remaining = full for the new epoch); the still-present old events are harmless (never match the new epoch predicate) and will be pruned when their deletions arrive.
- deletions-only arrive (epoch not yet seen): covered by Interleaving A — over-count that heals.
- Neither ordering can drop a **current-epoch** event a peer legitimately counts, because prune deletions only ever target `resetEpoch < currentResetEpoch` at the origin, i.e. strictly-older-than-the-bumped epoch; a current-epoch consumption event is never pruned.
- Test `testGivenEpochBumpArrivesWithoutEvents_ThenCountResetsAndOldEventsInert` and `testGivenEventsArriveBeforeEpoch_ThenCountedOnlyAfterEpochAdopted` (a peer receiving epoch-2 consumption events while still at epoch 1 must NOT count them until it adopts epoch 2 — they sit inert, so no premature under-count of the peer's own epoch-1 budget).

**Convergence:** two concurrent resets both push their epoch on the max channel; `max()` converges deterministically with no lost bump (unlike LWW, where one version would win and the other's epoch would be dropped). Combined with the G-Set union of events, the whole shape converges. This is the property the dedicated channel buys over the config channel — **but only once the epoch record is actually delivered and re-seedable**, which requires Task 4f (below).

### Findings from the maintainer-directed re-run (adversarial pass, 2026-07-08)

The re-run tried to break the design across concrete 2-device timelines. The *math* (G-Set union + monotonic-max epoch + strictly-less-than prune) holds and protects the never-under-count invariant in the abstract, and the following were verified sound: monotonic-max apply in isolation, CKSyncEngine self-echo harmlessness (max/union are idempotent — no `originDeviceId` self-filter needed), cold-start at epoch 0, and higher-epoch events being inert (the only structural skew is toward over-grant). Three real gaps were found and folded:

- **BLOCKER (fixed by Task 4f):** `SyncedEmergencyEpoch` — a fixed-name repeatedly-updated record — was not in `scopedTypes` and had no `localIsStrictlyNewer` case, so after its first push a CAS-losing higher epoch would be dropped and never re-added → the max channel would freeze on the server → lagging peers permanently under-count (wrong-deny). **Task 4f** scopes it + adds the CAS re-add.
- **MAJOR (fixed by Task 4f):** `restorableRecordNames()` seeded neither the epoch nor the event ledger → a T5 zone re-seed loses them permanently. **Task 4f** appends both.
- **RESOLVED — shared-budget semantics, SETTLED (maintainer, 2026-07-08).** The epoch is a bare shared counter, so two devices manually resetting from the same base both go `5 → 6` and collapse onto epoch 6 — and that is the **correct** outcome, not a bug to design around. Rationale (on the record): emergency unblock is a single user's escape hatch (profiles sync **same-user** across that user's own devices), and the count is synced precisely so it is ONE budget — 3 per 4 weeks **for the person**, not 3 per device they happen to own. Per-device semantics would defeat the feature: a user could pick up their iPad to mint three more unblocks. So two concurrent manual resets are **one logical reset**, and converging to the same epoch integer via `max()` is exactly right; device B correctly inherits the family/user's consumption of the shared epoch-6 budget. **No `(counter, deviceId)` / UUID identity — adding one would break the shared-budget property.** The per-device option is dropped.

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
