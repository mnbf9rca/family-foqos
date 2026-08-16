# Issue #447 Empty-Store Family Recovery V2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Recover confirmed family authority before startup side effects, offer only account-validated synced profiles for a genuinely fresh local store, and avoid automatic profile merging when local state appears before delayed recovery.

**Architecture:** A read-only first-property snapshot feeds a main-actor, single-flight coordinator. A literal-default-held process runtime gates foreground composition, silent pushes, and sync attachment; successful share acceptance is the only alternate authority exit. Durable recovery intent is account-scoped, current-account membership and profile counts are revalidated before surface and action, and the corrected #449 notice pattern supplies defer/surface/invalidate behavior.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Core Foundation preferences, SQLite3 read-only inspection, CloudKit zone-change operations, XCTest, and the project Xcode simulator gate.

## Global Constraints

- Approved design: signed commit `a95781a54c42f65a17540ff11b398773f6d4ba94`, plus the maintainer-authored M1/M2 rulings and reviewer-approved copy correction recorded on 2026-08-16.
- Existing signed implementation commits `be49cda`, `6f60fba`, and `bb632d3` remain intact; revise forward with new signed commits only.
- The held Task 4 diff in `FoqosApp.swift`, `StartupRecoveryView.swift`, `StartupRecoveryCopyTests.swift`, and `StartupRecoveryOrderingTests.swift` is preserved and audited before reuse.
- Missing onboarding completion plus an absent, table-missing, or zero-profile store is `fresh` regardless of app-group values. Positive profiles or persisted onboarding are `localStatePresent`; read failure is `indeterminate`.
- After two indeterminate membership attempts, Continue Setup is unbounded and enters normal onboarding. Persist only `recheckPending`; implement no grace counter, elapsed/launch cap, or capability restriction.
- Every recovery claim is bound to the current iCloud user record name. Unknown account defers without clearing; mismatch holds startup, invalidates stale claims, and reruns membership.
- Inherit the corrected notice pattern from exact merged main `f0293418539aeced376c121f410b1152faed3a11`. Use explicit verb-shaped names for operations that can clear or rewrite durable state, and never create an ownerless recovery intent.
- Successful lookup absence is authoritative. A thrown `.zoneNotFound`, `.userDeletedZone`, partial failure, record failure, or operation failure remains indeterminate unless a fresh successful zone list proves absence.
- Only `freshMember` counts remote profiles. `localStatePresentMember` restores the role, persists Device Sync disabled, shows distinct copy, and never enumerates, attaches, seeds, or merges profiles.
- Stored profile count is a hint. Reconfirm account and count before surfacing and before every Restore, Not Now, or zero-profile Continue action; a changed count updates the offer and requires a new tap.
- `StartupRecoveryRuntime` is lazy static state with literal default `held`. No consumer can observe released before an allowed coordinator transition.
- Durable transitions are mutually exclusive with share acceptance; asynchronous CloudKit lookups are not. No critical section spans an `await`.
- Silent pushes return `.noData` while held and invoke no account, membership, child-data, sync, heartbeat, or app-group mutation path.
- The profile-availability read occurs before Device Sync consent, uses `CKFetchRecordZoneChangesOperation` only, and discloses that read honestly.
- The fresh-member introduction is exactly: `This device doesn't have local Family Foqos data, but this iCloud account is part of a Family Foqos family. Your family role has been restored.` It must not contain `no longer`, `previous`, `lost`, or `wiped`.
- All 12 configurations target `MARKETING_VERSION = 2.0.49` and `CURRENT_PROJECT_VERSION = 67` after v2.0.48/66 merges.
- Build and test only through `scripts/xcode-stream.sh --agent build2 --session issue_447`; never use a device-name destination.
- No CloudKit schema change, dependency addition, #430 root-cause claim, local-only reconstruction, or naive local/remote merge.

---

### Task 1: Close the maintainer rulings and forward plan

**Files:**
- Modify: `docs/superpowers/specs/2026-08-16-issue-447-empty-store-family-recovery-design.md`
- Create: `docs/superpowers/plans/2026-08-16-issue-447-empty-store-family-recovery-v2.md`

**Interfaces:**
- Consumes: immutable reviewer approval on `a95781a` and planner rulings for M1, M2, and fresh-member copy.
- Produces: a signed docs-only commit that removes both open slots, names maintainer authorship, and defines the remaining implementation sequence.

- [x] **Step 1: Replace OPEN-M1 with the maintainer's unbounded escape**

  State Retry then Continue Setup, durable `recheckPending`, and explicit absence of bound machinery.

- [x] **Step 2: Replace OPEN-M2 with the concrete classifier**

  State that app-group values inform recovery but never veto `fresh` when onboarding is absent and the profile store is empty/absent.

- [x] **Step 3: Adopt account-neutral fresh-member copy**

  Replace the false lost-data claim with the exact Global Constraints string.

- [x] **Step 4: Verify and commit**

  Run:

  ```bash
  rg -n "OPEN-M1|OPEN-M2|no longer has its previous" docs/superpowers/specs/2026-08-16-issue-447-empty-store-family-recovery-design.md
  git diff --check
  ```

  Expected: `rg` exits 1 with no stale open-slot/copy text; `git diff --check` exits 0. Commit only the two docs:

  ```bash
  git add docs/superpowers/specs/2026-08-16-issue-447-empty-store-family-recovery-design.md docs/superpowers/plans/2026-08-16-issue-447-empty-store-family-recovery-v2.md
  git commit -S -m "docs(#447): apply maintainer recovery rulings"
  ```

### Task 2: Apply the loosened local classifier

**Files:**
- Modify: `Foqos/Utils/StartupRecoveryLocalState.swift`
- Modify: `FoqosTests/StartupRecoveryLocalStateTests.swift`

**Interfaces:**
- Produces: `StartupRecoveryLocalClassification.localStatePresent`, `.fresh`, and `.indeterminate`.
- Preserves: `StartupRecoveryLocalSnapshot.appGroupStatePresent` as informational evidence.

- [ ] **Step 1: Write the failing app-group-crumb test and rename expectations**

  Replace the old app-group-veto fixture with:

  ```swift
  func testGivenOnlyAppGroupState_WhenOnboardingAndProfilesAreEmpty_ThenRecoveryCheckIsRequired() {
    XCTAssertEqual(
      StartupRecoveryLocalState.classify(
        .init(
          onboardingValuePresent: false,
          appGroupStatePresent: true,
          store: .profileCount(0))),
      .fresh)
  }
  ```

  Rename `.existing` expectations to `.localStatePresent` and prove onboarding or a positive profile count still takes that path.

- [ ] **Step 2: Run focused RED**

  ```bash
  scripts/xcode-stream.sh --agent build2 --session issue_447 -- xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -only-testing:FoqosTests/StartupRecoveryLocalStateTests
  ```

  Expected: the app-group-only assertion fails because current code returns `.existing`.

- [ ] **Step 3: Implement the minimal classifier**

  ```swift
  enum StartupRecoveryLocalClassification: Equatable {
    case localStatePresent
    case fresh
    case indeterminate
  }

  static func classify(_ snapshot: StartupRecoveryLocalSnapshot)
    -> StartupRecoveryLocalClassification
  {
    if snapshot.onboardingValuePresent { return .localStatePresent }
    switch snapshot.store {
    case .storeAbsent, .tableMissing, .profileCount(0): return .fresh
    case .profileCount: return .localStatePresent
    case .readFailed: return .indeterminate
    }
  }
  ```

- [ ] **Step 4: Run focused GREEN and commit**

  Run the Task 2 command again. Expected: all local-state tests pass. Then:

  ```bash
  git add Foqos/Utils/StartupRecoveryLocalState.swift FoqosTests/StartupRecoveryLocalStateTests.swift
  git commit -S -m "fix(#447): treat app-group crumbs as recovery evidence"
  ```

### Task 3: Bind CloudKit recovery evidence to a successful account lookup

**Files:**
- Modify: `Foqos/CloudKit/StartupRecoveryCloudService.swift`
- Modify: `Foqos/Utils/StartupRecoveryCoordinator.swift`
- Modify: `FoqosTests/StartupRecoveryCloudServiceTests.swift`

**Interfaces:**
- Produces:

  ```swift
  enum StartupRecoveryMembershipResult: Equatable {
    case member(role: FamilyRole, ownerUserRecordName: String)
    case confirmedNone(ownerUserRecordName: String)
    case indeterminate
  }
  ```

- Produces: `fetchSyncedProfileCount(expectedOwnerUserRecordName:)` which verifies the current account before reading the private zone.

- [ ] **Step 1: Write failing semantic mapping tests**

  Add exact fixtures for:

  ```swift
  XCTAssertEqual(
    StartupRecoveryCloudService.resolveMembership(
      .recordRole(role: FamilyRole.child.rawValue, ownerUserRecordName: "owner-A")),
    .member(role: .child, ownerUserRecordName: "owner-A"))
  XCTAssertEqual(
    StartupRecoveryCloudService.resolveMembership(.recordFetchFailed),
    .indeterminate)
  XCTAssertEqual(
    StartupRecoveryCloudService.resolveMembership(.zoneListSucceededWithoutPolicyZone(ownerUserRecordName: "owner-A")),
    .confirmedNone(ownerUserRecordName: "owner-A"))
  ```

  Prove thrown missing-zone and partial-failure observations remain indeterminate. Prove a successful list missing the private `DeviceSync` zone confirms count zero, while a thrown missing-zone fetch does not.

- [ ] **Step 2: Run focused RED**

  ```bash
  scripts/xcode-stream.sh --agent build2 --session issue_447 -- xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -only-testing:FoqosTests/StartupRecoveryCloudServiceTests
  ```

  Expected: compile failures for account-bearing result cases and the stricter observation cases.

- [ ] **Step 3: Implement the exact #427 evidence boundary**

  Carry `userRecordID.recordName` through only successful account observations. Never map an operation error directly to absence. If a zone-change fetch reports `.zoneNotFound` or `.userDeletedZone`, perform a fresh `allRecordZones()` read; confirm none/zero only when that new list succeeds without the exact zone.

- [ ] **Step 4: Run focused GREEN and sync guards**

  ```bash
  scripts/xcode-stream.sh --agent build2 --session issue_447 -- xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -only-testing:FoqosTests/StartupRecoveryCloudServiceTests
  scripts/check-sync-guards.sh
  ```

  Expected: focused tests pass; I5 reports no private-path `CKQuery` and I2 reports no new outbound enqueue.

- [ ] **Step 5: Commit**

  ```bash
  git add Foqos/CloudKit/StartupRecoveryCloudService.swift Foqos/Utils/StartupRecoveryCoordinator.swift FoqosTests/StartupRecoveryCloudServiceTests.swift
  git commit -S -m "fix(#447): bind recovery evidence to iCloud account"
  ```

### Task 4: Make recovery intent account-scoped, single-flight, and honest after re-arm

**Files:**
- Modify: `Foqos/Utils/StartupRecoveryCoordinator.swift`
- Modify: `FoqosTests/StartupRecoveryCoordinatorTests.swift`

**Interfaces:**
- Produces:

  ```swift
  enum StartupRecoveryPath: String, Codable { case freshMember, localStatePresentMember }

  struct StartupRecoveryOriginState: Codable, Equatable {
    let modeRawValue: String?
    let hasSelectedMode: Bool?
    let onboardingCompleted: Bool?
    let showIntro: Bool?
    let showModeSelection: Bool?
    let deviceSyncEnabled: Bool?
  }

  struct StartupRecoveryPendingOffer: Codable, Equatable {
    let ownerUserRecordName: String
    let role: FamilyRole
    let path: StartupRecoveryPath
    let profileCountHint: Int?
    let profileCountConfirmedAt: Date?
    let origin: StartupRecoveryOriginState
  }
  ```

- Consumes: injected `captureLocalClassification`, `captureOrigin`, `restoreOrigin`, account-bearing membership lookup, account-bound profile count, role restore, lock refresh, sync toggle, and release callbacks.
- Produces async `restoreProfiles()`, `declineProfiles()`, and `continueWithoutProfiles()` actions that revalidate before commit.

- [ ] **Step 1: Write failing account/durability tests**

  Test matching owner resume, unknown-account defer, different-account invalidation plus rerun, new-account confirmed-none origin rollback, and indeterminate mismatch holding startup. Recreate `StartupRecoveryStore` between actions to prove persistence.

- [ ] **Step 2: Write failing count/action tests**

  A stored count must trigger a new count fetch before `.offer`. Before each action, return a changed count and assert the coordinator updates the offer without enabling sync, clearing intent, or releasing. A second tap after an unchanged confirmation may commit.

- [ ] **Step 3: Write failing single-flight and re-arm tests**

  Use continuations to overlap cold start, Retry, foreground, and connectivity triggers. Assert one membership call, one profile call, stale completion suppression, and one release. After Continue Setup, return `.localStatePresent` from the injected classifier and confirmed membership; assert role-only state, no count call, `[false]` sync writes, and distinct notice.

- [ ] **Step 4: Run focused RED**

  ```bash
  scripts/xcode-stream.sh --agent build2 --session issue_447 -- xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -only-testing:FoqosTests/StartupRecoveryCoordinatorTests
  ```

  Expected: compile failures for the new account-scoped intent and async action API.

- [ ] **Step 5: Implement minimal coordinator generations and synchronous write sections**

  Keep every `UserDefaults`, mode, onboarding, consent, intent, state, and release mutation in non-suspending main-actor helpers. Increment a generation before each async lookup; after every `await`, guard the captured generation and `!acceptanceInFlight` before opening a durable write section. Coalesce repeated triggers onto the current task.

- [ ] **Step 6: Run focused GREEN and commit**

  Run Task 4's focused command. Expected: all durability, mismatch, stale-count, single-flight, re-arm, and role-only tests pass. Then:

  ```bash
  git add Foqos/Utils/StartupRecoveryCoordinator.swift FoqosTests/StartupRecoveryCoordinatorTests.swift
  git commit -S -m "feat(#447): make recovery account-scoped and single-flight"
  ```

### Task 5: Enforce the literal-default-held runtime across startup and silent pushes

**Files:**
- Create: `Foqos/Utils/StartupRecoveryRuntime.swift`
- Modify: `Foqos/FoqosApp.swift`
- Modify: `FoqosTests/StartupRecoveryOrderingTests.swift`
- Create: `FoqosTests/StartupRecoveryRuntimeTests.swift`

**Interfaces:**
- Produces `@MainActor final class StartupRecoveryRuntime` with `static let shared`, literal `private(set) var isHeld = true`, coordinator registration, monotonic `release()`, and share-acceptance forwarding.
- `AppDelegate.didReceiveRemoteNotification` reads `StartupRecoveryRuntime.shared.isHeld` before any current-mode singleton access or CloudKit work.

- [ ] **Step 1: Write failing consumer-first and push tests**

  Instantiate/access the runtime before constructing any app composition helper and assert `isHeld`. Inject closures into a pure push router and assert all counters remain zero while held and completion is `.noData`; after release, assert the existing route runs.

- [ ] **Step 2: Run focused RED**

  ```bash
  scripts/xcode-stream.sh --agent build2 --session issue_447 -- xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -only-testing:FoqosTests/StartupRecoveryRuntimeTests -only-testing:FoqosTests/StartupRecoveryOrderingTests
  ```

  Expected: compile failures for the absent runtime/router API.

- [ ] **Step 3: Implement the runtime and route gate**

  Gate before `AppModeManager.shared.currentMode`, `CloudKitManager.shared`, `LockCodeManager.shared`, `ProfileSyncManager.shared`, or `HeartbeatManager.shared` is touched. Keep Home, migrations, foreground refresh, and `attachEngine` behind the same monotonic release.

- [ ] **Step 4: Run focused GREEN and commit**

  ```bash
  scripts/xcode-stream.sh --agent build2 --session issue_447 -- xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -only-testing:FoqosTests/StartupRecoveryRuntimeTests -only-testing:FoqosTests/StartupRecoveryOrderingTests
  git add Foqos/Utils/StartupRecoveryRuntime.swift Foqos/FoqosApp.swift FoqosTests/StartupRecoveryRuntimeTests.swift FoqosTests/StartupRecoveryOrderingTests.swift
  git commit -S -m "feat(#447): gate startup and silent pushes"
  ```

### Task 6: Serialize successful share acceptance with durable recovery writes

**Files:**
- Modify: `Foqos/FoqosApp.swift`
- Modify: `Foqos/Utils/StartupRecoveryCoordinator.swift`
- Modify: `Foqos/Utils/StartupRecoveryRuntime.swift`
- Create: `FoqosTests/StartupRecoveryShareAcceptanceTests.swift`

**Interfaces:**
- Produces `beginShareAcceptance()`, `failShareAcceptance()`, and `completeShareAcceptanceAfterModeApplied()` on the runtime/coordinator bridge.
- Preserves existing global `completeShareAcceptance(metadata:role:)` entry point and calls the bridge inside its `Task { @MainActor in ... }`.

- [ ] **Step 1: Write failing acceptance arbitration tests**

  Cover Cancel/no-op; acceptance beginning while a lookup is suspended; a stale lookup completion being ignored; failed `acceptShareDirect` preserving intent byte-for-byte and gate held; and successful `applyAcceptedFamilyMode` atomically clearing intent, standing down, and releasing once.

- [ ] **Step 2: Run focused RED**

  ```bash
  scripts/xcode-stream.sh --agent build2 --session issue_447 -- xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -only-testing:FoqosTests/StartupRecoveryShareAcceptanceTests
  ```

  Expected: compile failures for the absent arbitration API.

- [ ] **Step 3: Implement bounded main-actor write arbitration**

  Mark `acceptanceInFlight` before awaiting `acceptShareDirect`. Do not hold a lock or durable section over that await. Because the main actor cannot enter `beginShareAcceptance` during a synchronous local write, acceptance waits at most for that write. On failure clear only the in-flight marker and restart recovery with a fresh generation; on successful `applyAcceptedFamilyMode`, clear the intent and release before best-effort registration/lock refresh.

- [ ] **Step 4: Run focused GREEN and commit**

  ```bash
  scripts/xcode-stream.sh --agent build2 --session issue_447 -- xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -only-testing:FoqosTests/StartupRecoveryShareAcceptanceTests
  git add Foqos/FoqosApp.swift Foqos/Utils/StartupRecoveryCoordinator.swift Foqos/Utils/StartupRecoveryRuntime.swift FoqosTests/StartupRecoveryShareAcceptanceTests.swift
  git commit -S -m "feat(#447): serialize share acceptance with recovery"
  ```

### Task 7: Present account-neutral recovery and inherit the corrected #449 notice pattern

**Files:**
- Modify: `Foqos/Views/StartupRecoveryView.swift`
- Modify: `Foqos/Utils/StartupRecoveryCoordinator.swift`
- Modify: `FoqosTests/StartupRecoveryCopyTests.swift`
- Modify: `FoqosTests/StartupRecoveryCoordinatorTests.swift`

**Interfaces:**
- Mirrors the merged #449 account-resolution pattern: unknown account defers without clearing; matching owner surfaces; mismatch invalidates without surfacing; a dismissed matching notice clears both payload and owner.
- Produces separate fresh-member and `localStatePresentMember` notice states and exact copy.

- [ ] **Step 1: Confirm the corrected #449 merged head is an ancestor**

  ```bash
  git merge-base --is-ancestor f0293418539aeced376c121f410b1152faed3a11 HEAD
  ```

  Expected: exit 0 after merging the corrected-pattern head into #447. Do not implement this task against an unmerged mutable worktree.

- [ ] **Step 2: Write failing copy and notice-resolution tests**

  Require the exact fresh-member introduction and assert forbidden fault words are absent:

  ```swift
  XCTAssertEqual(StartupRecoveryCopy.introduction, expectedIntroduction)
  for forbidden in ["no longer", "previous", "lost", "wiped"] {
    XCTAssertFalse(StartupRecoveryCopy.introduction.localizedCaseInsensitiveContains(forbidden))
  }
  ```

  Assert role-only copy says existing local setup/profiles, Device Sync off, and no merge. Assert unknown/matching/mismatched account resolution follows the merged #449 pattern.

- [ ] **Step 3: Run focused RED**

  ```bash
  scripts/xcode-stream.sh --agent build2 --session issue_447 -- xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -only-testing:FoqosTests/StartupRecoveryCopyTests -only-testing:FoqosTests/StartupRecoveryCoordinatorTests
  ```

  Expected: current lost-data copy and ownerless pending-offer behavior fail.

- [ ] **Step 4: Implement minimal UI and notice resolution**

  Show the pre-consent Device Sync availability disclosure. Keep Restore/Not Now/Continue disabled during final validation. Surface no stored role/count until owner and count are current. Use the role-only notice for `localStatePresentMember` and never show profile actions there.

- [ ] **Step 5: Run focused/full GREEN and commit**

  ```bash
  scripts/xcode-stream.sh --agent build2 --session issue_447 -- xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -only-testing:FoqosTests/StartupRecoveryCopyTests -only-testing:FoqosTests/StartupRecoveryCoordinatorTests
  scripts/xcode-stream.sh --agent build2 --session issue_447 -- xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos
  git add Foqos/Views/StartupRecoveryView.swift Foqos/Utils/StartupRecoveryCoordinator.swift FoqosTests/StartupRecoveryCopyTests.swift FoqosTests/StartupRecoveryCoordinatorTests.swift
  git commit -S -m "feat(#447): present account-validated recovery choices"
  ```

### Task 8: Version, verify, review, merge, and upload in sequence

**Files:**
- Modify: `FamilyFoqos.xcodeproj/project.pbxproj`
- Modify only if verification finds a tested defect: files already owned by Tasks 2–7.

**Interfaces:**
- Produces a signed exact head at v2.0.49/67, independent exact-head code approval, a non-draft PR, planner merge, and one attended TestFlight upload from verified merged main. There is no V1 or diagnostic-experiment upload leg.

- [ ] **Step 1: Verify the version gate is RED before editing**

  ```bash
  scripts/check-version-increment.sh origin/main HEAD
  ```

  Expected: nonzero because #447 has not yet set v2.0.49/67.

- [ ] **Step 2: Set and count all configurations**

  Set all 12 `MARKETING_VERSION` values to `2.0.49` and all 12 `CURRENT_PROJECT_VERSION` values to `67`. Verify:

  ```bash
  rg -n "MARKETING_VERSION = 2.0.49;" FamilyFoqos.xcodeproj/project.pbxproj
  rg -n "CURRENT_PROJECT_VERSION = 67;" FamilyFoqos.xcodeproj/project.pbxproj
  ```

  Expected: exactly 12 lines from each command.

- [ ] **Step 3: Commit version and verify the gate GREEN**

  ```bash
  git add FamilyFoqos.xcodeproj/project.pbxproj
  git commit -S -m "chore(#447): bump release to 2.0.49 build 67"
  scripts/test-check-version-increment.sh
  scripts/check-version-increment.sh origin/main HEAD
  ```

  Expected: fixture suite and live version gate pass.

- [ ] **Step 4: Run the complete verification matrix**

  ```bash
  swift-format lint --recursive .
  ruby scripts/check-log-privacy.rb
  scripts/check-sync-guards.sh
  git diff --check origin/main...HEAD
  scripts/xcode-stream.sh --agent build2 --session issue_447 -- xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos
  scripts/xcode-stream.sh --agent build2 --session issue_447 --xcbeautify -- xcodebuild -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -configuration Debug build
  ```

  Record exact test count, failures, build exit, lints, guard output, and version counts. Any defect returns to a new RED test and a new signed commit; never amend.

- [ ] **Step 5: Obtain immutable exact-head review**

  Send the reviewer exact base/head SHAs, signed design/plan SHAs, diff scope, every RED/GREEN command, full matrix output, account-mismatch and count-revalidation evidence, consumer-first gate proof, push/share arbitration evidence, no-`CKQuery` guard, and version counts. Address findings in new signed commits and request re-review of each new exact head.

- [ ] **Step 6: Publish and preserve release order**

  Push the approved head, open a non-draft PR closing #447, and hand merge ownership to the planner. After the planner confirms merge and fresh-main verification, announce the single attended credential operation, run `scripts/fastlane.sh beta`, and report the exact accepted v2.0.49/67 artifact and merged head. Use bobbithy's standing authorization for the newer artifact; if the execution harness independently requires an external-action escalation, route that gate instead of bypassing it.
