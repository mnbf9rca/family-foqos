# Issue #447 Empty-Store Family Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Detect a locally fresh device that still belongs to a Family Foqos family before onboarding or sync writes, restore its family role, and offer only CloudKit-confirmed synced profiles for explicit restoration.

**Architecture:** A first-property, read-only local snapshot classifies the launch before migrations, SwiftData materialization, onboarding, or sync attachment can mask evidence. A durable main-actor coordinator gates startup, calls a dedicated CloudKit reader for membership and private-zone profile count, survives termination, and supports the planner-approved offline Continue Setup plus re-armed membership checks.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Core Foundation preferences, SQLite3 read-only inspection, CloudKit shared-zone query, `CKFetchRecordZoneChangesOperation`, XCTest, the project Xcode simulator gate.

## Global Constraints

- The first local snapshot must run before `@StateObject` initialization, `UserDefaultsMigration`, `ModelContainer` access, `HomeView`, and `ProfileSyncManager.attachEngine`.
- The snapshot creates no preferences suite, SwiftData store, or WAL. Store read failure is indeterminate, never fresh.
- A confirmed `FamilyMember` restores role/onboarding regardless of Device Sync or synced-profile count.
- Child role persistence and the pending offer are durable before authorization verification; shared lock codes refresh after role restoration.
- Private `DeviceSync` discovery uses `CKFetchRecordZoneChangesOperation`, never `CKQuery`, and performs no writes.
- After one failed explicit Retry, Continue Setup is available; it durably re-arms membership checks on later foreground/connectivity until a confirmed answer.
- A pending recovery offer survives termination and clears only on Restore, Not Now, or the zero-profile Continue decision.
- Genuinely new users with confirmed no membership follow current onboarding unchanged.
- All 12 build configurations use `MARKETING_VERSION = 2.0.47` and `CURRENT_PROJECT_VERSION = 65`.
- No CloudKit schema change, dependency addition, #430 root-cause diagnosis, or local-only profile reconstruction.

---

### Task 1: Pre-startup read-only local classifier

**Files:**
- Create: `Foqos/Utils/AppModelStore.swift`
- Create: `Foqos/Utils/StartupRecoveryLocalState.swift`
- Create: `FoqosTests/StartupRecoveryLocalStateTests.swift`
- Modify: `Foqos/FoqosApp.swift`

**Interfaces:**
- Produces: `AppModelStore.schema`, `configuration`, `storeURL`, and `makeContainer()` as the one production SwiftData configuration.
- Produces: `StartupRecoveryStoreFinding`, `StartupRecoveryLocalSnapshot`, and `StartupRecoveryLocalClassification`.
- `StartupRecoveryLocalState.capture(...)` accepts injected preference, file-existence, and SQLite readers for deterministic tests.

- [ ] **Step 1: Write failing classifier and physical-effect tests**

  Add tests whose wished-for API is:

  ```swift
  XCTAssertEqual(
    StartupRecoveryLocalState.classify(
      .init(onboardingValuePresent: false, appGroupStatePresent: false, store: .profileCount(0))),
    .fresh)
  XCTAssertEqual(
    StartupRecoveryLocalState.classify(
      .init(onboardingValuePresent: false, appGroupStatePresent: false, store: .readFailed)),
    .indeterminate)
  ```

  Cover store absent, table missing, zero, positive count, read failure, current and pre-migration onboarding-key presence, and any app-group value. Prove a missing store never calls SQLite and construction of `AppModelStore.configuration` does not create its URL.

- [ ] **Step 2: Run focused tests and verify RED**

  Run:

  ```bash
  scripts/xcode-stream.sh --agent build2 --session issue_447 -- xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -only-testing:FoqosTests/StartupRecoveryLocalStateTests
  ```

  Expected: compile failure because the new types do not exist.

- [ ] **Step 3: Implement the minimal read-only snapshot**

  Move the existing three-model configuration from the global `FoqosApp` closure into `AppModelStore`. Implement Core Foundation preference reads and the #430-proven WAL-aware read-only SQLite table/count reader. The classifier must be equivalent to:

  ```swift
  static func classify(_ value: StartupRecoveryLocalSnapshot)
    -> StartupRecoveryLocalClassification
  {
    if value.onboardingValuePresent || value.appGroupStatePresent { return .existing }
    switch value.store {
    case .profileCount(let count) where count > 0: return .existing
    case .storeAbsent, .tableMissing, .profileCount(0): return .fresh
    case .readFailed: return .indeterminate
    default: return .indeterminate
    }
  }
  ```

- [ ] **Step 4: Run focused tests and verify GREEN**

  Run the Task 1 command again. Expected: all `StartupRecoveryLocalStateTests` pass, with no created store/WAL.

- [ ] **Step 5: Commit the task**

  ```bash
  git add Foqos/Utils/AppModelStore.swift Foqos/Utils/StartupRecoveryLocalState.swift Foqos/FoqosApp.swift FoqosTests/StartupRecoveryLocalStateTests.swift
  git commit -S -m "feat(#447): classify fresh local state before startup"
  ```

### Task 2: Durable recovery state machine and offline escape

**Files:**
- Create: `Foqos/Utils/StartupRecoveryCoordinator.swift`
- Create: `FoqosTests/StartupRecoveryCoordinatorTests.swift`

**Interfaces:**
- Produces: `StartupRecoveryMembershipResult` with `.member(FamilyRole)`, `.confirmedNone`, `.indeterminate`.
- Produces: `StartupRecoveryProfileCountResult` with `.confirmed(Int)` and `.indeterminate`.
- Produces: `StartupRecoveryState` for checking, retry, normal startup, profile lookup, and recovery offer.
- Produces: `StartupRecoveryStore` with a durable recheck bit and a Codable pending offer containing `role` plus optional `profileCount`.
- Consumes injected async closures for membership lookup, profile count, role/onboarding persistence, child lock refresh, sync enablement, and startup release.

- [ ] **Step 1: Write failing durability and transition tests**

  Test these transitions with recording closures:

  ```swift
  fresh -> member(.child) -> persistPending(role, nil) -> restoreRole -> refreshLocks
    -> profileCount(.confirmed(2)) -> persistPending(role, 2) -> offer

  fresh -> indeterminate -> retry -> indeterminate -> retry(canContinueSetup: true)
    -> continueSetup -> normal(recheckArmed: true)
  ```

  Recreate `StartupRecoveryStore` with the same isolated defaults and prove both `recheckPending` and a pending offer survive. Prove pending state clears only after explicit decisions. Prove `confirmedNone` clears recheck state. Prove a relaunched offer with `profileCount == nil` resumes profile lookup, while a stored count immediately reconstructs the offer.

- [ ] **Step 2: Run focused tests and verify RED**

  Run the Xcode stream command from Task 1 with `-only-testing:FoqosTests/StartupRecoveryCoordinatorTests`. Expected: compile failure for missing coordinator/store types.

- [ ] **Step 3: Implement the minimal coordinator**

  Keep the coordinator `@MainActor`. Persist the pending offer before role/onboarding writes. After membership confirmation, execute dependency callbacks in this tested order:

  ```swift
  store.pendingOffer = .init(role: role, profileCount: nil)
  restoreFamilyRole(role)
  if role == .child { await refreshChildLockCodes() }
  let count = await lookupSyncedProfileCount()
  ```

  `restoreProfiles()` enables Device Sync, clears pending state, and releases startup. `declineProfiles()` and `continueWithoutProfiles()` clear pending state without enabling sync. `continueSetup()` sets `recheckPending = true` before releasing startup.

- [ ] **Step 4: Run focused tests and verify GREEN**

  Expected: transition ordering, relaunch, retry/escape, re-arm, and clearing tests all pass.

- [ ] **Step 5: Commit the task**

  ```bash
  git add Foqos/Utils/StartupRecoveryCoordinator.swift FoqosTests/StartupRecoveryCoordinatorTests.swift
  git commit -S -m "feat(#447): persist startup family recovery state"
  ```

### Task 3: Read-only CloudKit membership and synced-profile discovery

**Files:**
- Create: `Foqos/CloudKit/StartupRecoveryCloudService.swift`
- Create: `FoqosTests/StartupRecoveryCloudServiceTests.swift`

**Interfaces:**
- Produces: `StartupRecoveryCloudService.lookupMembership()` and `fetchSyncedProfileCount()`.
- Produces a pure `StartupRecoveryProfileRecordFold` that accepts modification `(recordName, recordType)` and deletion `(recordName, recordType)` events and returns the current `SyncedProfile` count.
- The production service owns the CloudKit container/database objects; tests exercise semantic mapping and folding without live CloudKit.

- [ ] **Step 1: Write failing membership mapping and profile-fold tests**

  Cover available account plus matching child/parent record, successful no-zone/no-record as confirmed none, signed-out/transient/invalid-role as indeterminate, multi-page profile modifications/deletions, unrelated record types, duplicate callbacks, empty/missing private zone, and transient private-zone failure.

- [ ] **Step 2: Run focused tests and verify RED**

  Run the Xcode stream command with `-only-testing:FoqosTests/StartupRecoveryCloudServiceTests`. Expected: compile failure for the absent service/fold.

- [ ] **Step 3: Implement shared membership lookup and private zone-change reader**

  Shared membership may use the existing `FamilyMember` query shape in the shared `FamilyPolicies` zone. The private path must construct `CKFetchRecordZoneChangesOperation` for `CloudKitConstants.syncZoneName` with a nil previous token, `fetchAllChanges = true`, and read-only callbacks. Fold only records whose type equals `SyncedProfile.recordType`; apply deletions before returning the final count. Map `.zoneNotFound`, `.userDeletedZone`, and an empty result to confirmed zero; map all retryable/ambiguous failures to indeterminate.

- [ ] **Step 4: Run focused tests and sync guard**

  Expected: focused tests pass and:

  ```bash
  scripts/check-sync-guards.sh
  ```

  reports no private-path `CKQuery` and no outbound enqueue violations.

- [ ] **Step 5: Commit the task**

  ```bash
  git add Foqos/CloudKit/StartupRecoveryCloudService.swift FoqosTests/StartupRecoveryCloudServiceTests.swift
  git commit -S -m "feat(#447): inspect CloudKit recovery state read-only"
  ```

### Task 4: Gate app startup and present honest recovery UI

**Files:**
- Create: `Foqos/Views/StartupRecoveryView.swift`
- Create: `FoqosTests/StartupRecoveryCopyTests.swift`
- Create: `FoqosTests/StartupRecoveryOrderingTests.swift`
- Modify: `Foqos/FoqosApp.swift`
- Modify: `Foqos/Views/HomeView.swift`

**Interfaces:**
- `StartupRecoveryView` consumes `StartupRecoveryState` and coordinator actions only.
- `FoqosApp` owns the first-property snapshot and one coordinator `@StateObject`.
- Existing startup attachment is extracted into an idempotent method that runs only after coordinator release.

- [ ] **Step 1: Write failing copy, action, and ordering tests**

  Assert exact strings from the design, including:

  ```swift
  "We found 1 synced profile. Restore it to this device?"
  "We found 3 synced profiles. Restore them to this device?"
  ```

  Add a pure startup-order recorder proving snapshot precedes migration/container/singletons, recovery role persistence precedes authorization verification, and attach is absent while checking/retrying/offering. Test new-user confirmed-none invisibility and later foreground re-arm after Continue Setup.

- [ ] **Step 2: Run focused tests and verify RED**

  Run the Xcode stream command with both new test classes. Expected: compile failure for absent UI/order seams.

- [ ] **Step 3: Wire the first-property snapshot and startup gate**

  Declare the snapshot before every `@StateObject`. Construct the coordinator in `FoqosApp.init` before migrations. Render `StartupRecoveryView` for checking/retry/profile/offer states and construct `HomeView` only for released normal startup. Move `attachEngine` behind the idempotent release callback. Gate the existing scene-active CloudKit/auth/sync work so it cannot bypass recovery; when recheck is armed, run membership recovery before child authorization.

  Role restoration must set:

  ```swift
  AppModeManager.shared.selectMode(role == .parent ? .parent : .child)
  UserDefaults.standard.set(true, forKey: "family_foqos_has_completed_onboarding")
  UserDefaults.standard.set(false, forKey: "family_foqos_show_intro_screen")
  UserDefaults.standard.set(false, forKey: "family_foqos_show_mode_selection")
  ```

  Preserve screenshot-demo and XCTest side-effect guards.

- [ ] **Step 4: Implement the recovery view and run focused/full tests**

  Use plain language from the design, ProgressView for checking, Retry plus delayed Continue Setup for indeterminate state, Restore/Not Now for positive counts, and Continue for zero. Run focused tests, then all tests through the same build2 stream. Expected: all tests pass with no onboarding or attach ordering regression.

- [ ] **Step 5: Commit the task**

  ```bash
  git add Foqos/FoqosApp.swift Foqos/Views/HomeView.swift Foqos/Views/StartupRecoveryView.swift FoqosTests/StartupRecoveryCopyTests.swift FoqosTests/StartupRecoveryOrderingTests.swift
  git commit -S -m "feat(#447): gate onboarding on family recovery"
  ```

### Task 5: Version, verify, review, and publish for planner merge

**Files:**
- Modify: `FamilyFoqos.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces one exact signed head on `fix/447-empty-store-recovery`, a ready-for-review PR, and independent approval for planner merge.

- [ ] **Step 1: Write/run the version RED check**

  Change no project values yet. Run:

  ```bash
  scripts/check-version-increment.sh origin/main HEAD
  ```

  Expected: nonzero with unchanged 2.0.45/64 settings, proving the live release gate rejects the pre-bump branch.

- [ ] **Step 2: Set all 12 configurations to 2.0.47/65**

  Mechanically replace the 12 marketing versions and 12 build numbers. Verify `rg -n "MARKETING_VERSION = 2.0.47;" FamilyFoqos.xcodeproj/project.pbxproj` prints exactly 12 lines and `rg -n "CURRENT_PROJECT_VERSION = 65;" FamilyFoqos.xcodeproj/project.pbxproj` prints exactly 12 lines, with no remaining 2.0.45 or build 64 setting.

- [ ] **Step 3: Commit the version bump and verify GREEN**

  ```bash
  git add FamilyFoqos.xcodeproj/project.pbxproj
  git commit -S -m "chore(#447): bump release to 2.0.47 build 65"
  scripts/test-check-version-increment.sh
  scripts/check-version-increment.sh origin/main HEAD
  ```

  Expected: the fixture suite passes and the live gate reports 2.0.45 -> 2.0.47 and 64 -> 65.

- [ ] **Step 4: Run the complete verification matrix**

  Run:

  ```bash
  swift-format lint --recursive .
  ruby scripts/check-log-privacy.rb
  scripts/check-sync-guards.sh
  git diff --check origin/main...HEAD
  scripts/xcode-stream.sh --agent build2 --session issue_447 -- xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos
  scripts/xcode-stream.sh --agent build2 --session issue_447 --xcbeautify -- xcodebuild -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -configuration Debug build
  ```

  Record exact test count, failures, build exit, lints, and version counts.

- [ ] **Step 5: Commit any verification fixes**

  If verification exposes a defect, return to RED with the smallest reproducing test, fix it, rerun the focused and complete matrices, and create a new signed commit. Never amend or force-push.

- [ ] **Step 6: Obtain independent review and publish**

  Send the reviewer exact base/head, design/plan paths, diff scope, RED/GREEN evidence, full test/build/lint results, private-zone no-`CKQuery` evidence, and the offline/pending-offer ordering. Address findings in new signed commits and obtain approval of the new exact head. Then push, open a non-draft PR closing #447, and hand the merge to the planner.

- [ ] **Step 7: Coordinate the attended beta after planner merge**

  After the planner confirms merge and fresh-main verification, announce immediately before the attended `scripts/fastlane.sh beta` credential operation. Confirm App Store Connect accepted version 2.0.47 with a build strictly above 64 and report the exact build/head to the planner.
