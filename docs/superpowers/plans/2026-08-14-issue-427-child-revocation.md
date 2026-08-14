# Issue #427 Child Revocation Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Detect authoritative CloudKit share revocation on a Child-mode device, erase only the
revoked family's stale PIN authority, and transition the device to Individual mode without
weakening offline fail-closed behavior.

**Architecture:** A verification-local tri-state classifier distinguishes an exact shared policy
zone, a successful lookup with no exact zone, and an indeterminate failed lookup. The existing
`VerificationResult.enforcedMode` field carries the Child-only confirmed-revocation signal to
`CloudKitManager`, which invokes trigger-keyed centralized cleanup. `LockCodeManager` erases its
child cache only for the confirmed CloudKit trigger.

**Tech Stack:** Swift 6, CloudKit, Combine/ObservableObject, UserDefaults, XCTest, Xcode simulator
gate.

## Global Constraints

- Work only in `/Users/rob/git/family-foqos/.worktrees/build2-427` on
  `fix/427-child-revocation`.
- Do not edit `Foqos/CloudKit/CloudKitNetworkService.swift`; the planner granted ownership only of
  `Foqos/CloudKit/CloudKitNetworkService+Verification.swift` and
  `Foqos/Utils/LockCodeManager.swift` among build1-overlapping files.
- Use 2-space Swift indentation, privacy-focused `Log`, and no personal identifiers or PINs in
  logs.
- Keep every offline/transient lookup indeterminate and preserve #197's persisted child PIN cache.
- Only successful CloudKit lookup plus absent exact `FamilyPolicies` zone plus current Child mode
  may erase the child PIN cache and select Individual mode.
- Keep Family Controls-driven authorization loss separate: issue #431's transient error path must
  not erase either PIN cache.
- Run every build/test through
  `scripts/xcode-stream.sh --agent build2 --session implement_beta_fixes`; never provide a
  destination or DerivedData path.
- If main stays at `2.0.31 (50)`, set every configuration to `2.0.32 (51)`; otherwise recompute both
  version values strictly above main before publication.
- Every commit is signed. Never amend, force-push, or merge; the planner merges after independent
  review.

---

### Task 1: Classify the shared policy zone without conflating errors

**Files:**

- Create: `FoqosTests/ChildRevocationTests.swift`
- Modify: `Foqos/CloudKit/CloudKitNetworkService+Verification.swift`

**Interfaces:**

- Consumes: `CKDatabase.allRecordZones()`, `CKRecordZone.ID`, `AppMode`, and the existing
  `VerificationResult` initializer.
- Produces: `CloudKitNetworkService.SharedPolicyZoneLookup`,
  `resolveSharedPolicyZoneLookup(zoneIDsFromSuccessfulLookup:)`, and
  `enforcedMode(for:localMode:)`.

- [ ] **Step 1: Write failing tri-state and Child-only decision tests**

Create `FoqosTests/ChildRevocationTests.swift` with literals whose expected values are independent
of the production classifier:

```swift
import CloudKit
import XCTest

@testable import FamilyFoqos

final class ChildRevocationTests: XCTestCase {
  private func zoneID(_ name: String) -> CKRecordZone.ID {
    CKRecordZone.ID(zoneName: name, ownerName: "test-owner")
  }

  func testGivenSuccessfulEmptyLookup_WhenResolvingZone_ThenRevocationIsConfirmed() {
    XCTAssertEqual(
      CloudKitNetworkService.resolveSharedPolicyZoneLookup(
        zoneIDsFromSuccessfulLookup: []),
      .confirmedAbsent)
  }

  func testGivenFailedLookup_WhenResolvingZone_ThenResultIsIndeterminate() {
    XCTAssertEqual(
      CloudKitNetworkService.resolveSharedPolicyZoneLookup(
        zoneIDsFromSuccessfulLookup: nil),
      .indeterminate)
  }

  func testGivenExactPolicyZoneAmongOtherZones_WhenResolving_ThenExactZoneIsPresent() {
    let exact = zoneID("FamilyPolicies")
    let fixture = [zoneID("OtherZone"), zoneID("FamilyPolicies-Renamed"), exact]

    XCTAssertEqual(
      CloudKitNetworkService.resolveSharedPolicyZoneLookup(
        zoneIDsFromSuccessfulLookup: fixture),
      .present(exact))
  }

  func testGivenOnlyMutatedPolicyName_WhenResolving_ThenRevocationIsConfirmed() {
    let mutatedFixture = [zoneID("FamilyPolicies-Renamed"), zoneID("OtherZone")]

    XCTAssertEqual(
      CloudKitNetworkService.resolveSharedPolicyZoneLookup(
        zoneIDsFromSuccessfulLookup: mutatedFixture),
      .confirmedAbsent)
  }

  func testGivenConfirmedAbsenceInChildMode_WhenResolvingMode_ThenEnforcesIndividual() {
    XCTAssertEqual(
      CloudKitNetworkService.enforcedMode(for: .confirmedAbsent, localMode: .child),
      .individual)
  }

  func testGivenConfirmedAbsenceOutsideChildMode_WhenResolvingMode_ThenDoesNotChangeMode() {
    XCTAssertNil(
      CloudKitNetworkService.enforcedMode(for: .confirmedAbsent, localMode: .parent))
    XCTAssertNil(
      CloudKitNetworkService.enforcedMode(for: .confirmedAbsent, localMode: .individual))
  }

  func testGivenIndeterminateLookupInChildMode_WhenResolvingMode_ThenDoesNotChangeMode() {
    XCTAssertNil(
      CloudKitNetworkService.enforcedMode(for: .indeterminate, localMode: .child))
  }
}
```

Mutation check: renaming the exact string, accepting prefix matches, treating `nil` as absence, or
returning `.individual` for any non-Child mode must fail at least one test.

- [ ] **Step 2: Run the focused class and verify RED**

Run:

```bash
scripts/xcode-stream.sh --agent build2 --session implement_beta_fixes -- \
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -only-testing:FoqosTests/ChildRevocationTests
```

Expected: build failure because `SharedPolicyZoneLookup`,
`resolveSharedPolicyZoneLookup(zoneIDsFromSuccessfulLookup:)`, and `enforcedMode(for:localMode:)`
do not exist. This is the intended RED, not a fixture or syntax failure.

- [ ] **Step 3: Add the minimal tri-state classifier and lookup**

At the top of the verification extension, add:

```swift
enum SharedPolicyZoneLookup: Equatable, Sendable {
  case present(CKRecordZone.ID)
  case confirmedAbsent
  case indeterminate
}

private static let verificationPolicyZoneName = "FamilyPolicies"

static func resolveSharedPolicyZoneLookup(
  zoneIDsFromSuccessfulLookup zoneIDs: [CKRecordZone.ID]?
) -> SharedPolicyZoneLookup {
  guard let zoneIDs else { return .indeterminate }
  guard
    let policyZoneID = zoneIDs.first(where: {
      $0.zoneName == verificationPolicyZoneName
    })
  else {
    return .confirmedAbsent
  }
  return .present(policyZoneID)
}

static func enforcedMode(
  for lookup: SharedPolicyZoneLookup,
  localMode: AppMode
) -> AppMode? {
  guard case .confirmedAbsent = lookup, localMode == .child else { return nil }
  return .individual
}

private func lookupSharedPolicyZoneForVerification() async -> SharedPolicyZoneLookup {
  do {
    let zones = try await sharedDatabase.allRecordZones()
    return Self.resolveSharedPolicyZoneLookup(
      zoneIDsFromSuccessfulLookup: zones.map(\.zoneID))
  } catch {
    Log.error(
      "Failed to fetch shared zones during verification: \(redactedErrorForLog(error))",
      category: .cloudKit)
    return .indeterminate
  }
}
```

Replace `verifySelfFamilyMember`'s optional-zone guard with one lookup and switch:

```swift
let zoneLookup = await lookupSharedPolicyZoneForVerification()
guard case .present(let zoneID) = zoneLookup else {
  let enforcedMode = Self.enforcedMode(for: zoneLookup, localMode: localMode)
  Log.info(
    enforcedMode == .individual
      ? "verifySelfFamilyMember: shared zone revocation confirmed"
      : "verifySelfFamilyMember: shared zone unavailable",
    category: .cloudKit)
  return VerificationResult(
    isConnected: false,
    userRecordID: cachedUserRecordID,
    isSignedIn: nil,
    enforcedMode: enforcedMode)
}
```

Within that method only, replace both uses of `zone.zoneID` with `zoneID`. Do not change
`registerSelfAsFamilyMember` or the core optional shared-zone helper.

- [ ] **Step 4: Run the focused class and verify GREEN**

Run the exact Step 2 command. Expected: all seven `ChildRevocationTests` pass, including the
mutated rename fixture and indeterminate Child-mode case.

- [ ] **Step 5: Format, inspect scope, and create a signed classifier commit**

Run:

```bash
swift-format --in-place \
  Foqos/CloudKit/CloudKitNetworkService+Verification.swift \
  FoqosTests/ChildRevocationTests.swift
git diff --check
git diff -- Foqos/CloudKit/CloudKitNetworkService+Verification.swift \
  FoqosTests/ChildRevocationTests.swift
git add Foqos/CloudKit/CloudKitNetworkService+Verification.swift \
  FoqosTests/ChildRevocationTests.swift
git commit -S -m "fix: distinguish child share revocation"
```

Expected: only the two owned files are committed; signature verification succeeds with
`git log -1 --show-signature`.

---

### Task 2: Key PIN erasure to confirmed CloudKit revocation

**Files:**

- Create: `FoqosTests/ChildRevocationCacheTests.swift`
- Modify: `Foqos/Utils/AuthorizationVerifier.swift`
- Modify: `Foqos/Utils/LockCodeManager.swift`
- Modify: `Foqos/CloudKit/CloudKitManager.swift`

**Interfaces:**

- Consumes: Task 1's disconnected plus enforced `.individual` signal and the existing
  `handleAuthorizationLoss()` cleanup.
- Produces: `FamilyAuthorizationLossTrigger`,
  `LockCodeManager.handleFamilyAuthorizationLoss(_:)`, and
  `CloudKitManager.confirmedRevocationTrigger(isConnected:enforcedMode:currentMode:)`.

- [ ] **Step 1: Add failing manager-signal and real cache-policy tests**

Append to `ChildRevocationTests`:

```swift
func testGivenDisconnectedIndividualSignalInChildMode_WhenResolving_ThenRevocationIsConfirmed() {
  XCTAssertEqual(
    CloudKitManager.confirmedRevocationTrigger(
      isConnected: false, enforcedMode: .individual, currentMode: .child),
    .confirmedCloudKitRevocation)
}

func testGivenRevocationSignalOutsideChildMode_WhenResolving_ThenNoLossIsApplied() {
  XCTAssertNil(
    CloudKitManager.confirmedRevocationTrigger(
      isConnected: false, enforcedMode: .individual, currentMode: .parent))
  XCTAssertNil(
    CloudKitManager.confirmedRevocationTrigger(
      isConnected: false, enforcedMode: .individual, currentMode: .individual))
}

func testGivenConnectedIndividualSignalInChildMode_WhenResolving_ThenNoLossIsApplied() {
  XCTAssertNil(
    CloudKitManager.confirmedRevocationTrigger(
      isConnected: true, enforcedMode: .individual, currentMode: .child))
}
```

Create `FoqosTests/ChildRevocationCacheTests.swift`:

```swift
import XCTest

@testable import FamilyFoqos

@MainActor
final class ChildRevocationCacheTests: XCTestCase {
  private let cacheKey = "family_foqos_child_lock_codes"

  private func withSeededCache(
    _ body: (LockCodeManager, UserDefaults) throws -> Void
  ) throws {
    let suiteName = "ChildRevocationCacheTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let manager = LockCodeManager.shared
    let originalMode = AppModeManager.shared.currentMode
    defer {
      manager.overrideDefaults(nil)
      AppModeManager.shared.currentMode = originalMode
      defaults.removePersistentDomain(forName: suiteName)
    }

    AppModeManager.shared.currentMode = .child
    let code = FamilyLockCode(code: "test-code", scope: .allChildren)
    defaults.set(try JSONEncoder().encode([code]), forKey: cacheKey)
    manager.overrideDefaults(defaults)
    XCTAssertTrue(manager.canVerifyCode)

    try body(manager, defaults)
  }

  func testGivenFamilyControlsLoss_WhenApplyingCachePolicy_ThenPINCacheIsPreserved() throws {
    try withSeededCache { manager, defaults in
      manager.handleFamilyAuthorizationLoss(.familyControls)

      XCTAssertTrue(manager.canVerifyCode)
      XCTAssertNotNil(defaults.data(forKey: cacheKey))
    }
  }

  func testGivenConfirmedCloudKitRevocation_WhenApplyingCachePolicy_ThenPINCacheIsErased() throws {
    try withSeededCache { manager, defaults in
      manager.handleFamilyAuthorizationLoss(.confirmedCloudKitRevocation)

      XCTAssertFalse(manager.canVerifyCode)
      XCTAssertNil(defaults.data(forKey: cacheKey))
    }
  }
}
```

These tests exercise the real singleton cache and isolated UserDefaults. They do not mock or alter
CloudKit. Mutation check: removing the trigger guard, erasing only persisted state, erasing only
in-memory state, accepting the overloaded signal while connected, or dropping the Child-only gate
must fail.

- [ ] **Step 2: Run both focused classes and verify RED**

Run:

```bash
scripts/xcode-stream.sh --agent build2 --session implement_beta_fixes -- \
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -only-testing:FoqosTests/ChildRevocationTests \
  -only-testing:FoqosTests/ChildRevocationCacheTests
```

Expected: build failure for missing `FamilyAuthorizationLossTrigger`,
`handleFamilyAuthorizationLoss(_:)`, and `confirmedRevocationTrigger(...)`. The already-green Task
1 tests remain syntactically valid.

- [ ] **Step 3: Add trigger-keyed cache behavior**

Add above `AuthorizationVerifier`:

```swift
enum FamilyAuthorizationLossTrigger: Equatable {
  case familyControls
  case confirmedCloudKitRevocation
}
```

Change the handler signature and route the trigger before existing cleanup:

```swift
func handleAuthorizationLoss(
  trigger: FamilyAuthorizationLossTrigger = .familyControls
) async -> String {
  let cloudKitManager = CloudKitManager.shared
  let appModeManager = AppModeManager.shared

  Log.info("Handling authorization loss", category: .authorization)

  LockCodeManager.shared.handleFamilyAuthorizationLoss(trigger)
  cloudKitManager.clearSharedState()
  clearAuthorizationState()
  appModeManager.selectMode(.individual)

  return
    "Your child account authorization was revoked (the device may have been removed from Apple Family Sharing). You've been switched to individual mode. To reconnect, ask a parent to re-add this device and send a new invitation."
}
```

Existing call sites keep the default `.familyControls` trigger. In `LockCodeManager`, add beside
the child cache resolver:

```swift
func handleFamilyAuthorizationLoss(_ trigger: FamilyAuthorizationLossTrigger) {
  guard trigger == .confirmedCloudKitRevocation else { return }
  cachedLockCodes = []
  throttleDefaults.removeObject(forKey: CacheKey.childLockCodes)
}
```

- [ ] **Step 4: Interpret the overloaded verification signal in CloudKitManager**

Add the pure decision:

```swift
nonisolated static func confirmedRevocationTrigger(
  isConnected: Bool,
  enforcedMode: AppMode?,
  currentMode: AppMode
) -> FamilyAuthorizationLossTrigger? {
  guard !isConnected, enforcedMode == .individual, currentMode == .child else { return nil }
  return .confirmedCloudKitRevocation
}
```

In `verifySelfFamilyMemberRecord()`, capture `localMode` before the await, pass it to verification,
then interpret the returned signal before the existing general enforced-mode branch:

```swift
let localMode = AppModeManager.shared.currentMode
let result = await networkService.verifySelfFamilyMember(
  cachedUserRecordID: currentUserRecordID,
  localMode: localMode
)

// In a disconnected result, enforced .individual is the confirmed-revocation signal. Only
// CloudKitNetworkService+Verification may produce this overload, and only for Child mode.
if let trigger = Self.confirmedRevocationTrigger(
  isConnected: result.isConnected,
  enforcedMode: result.enforcedMode,
  currentMode: AppModeManager.shared.currentMode
) {
  _ = await AuthorizationVerifier.shared.handleAuthorizationLoss(trigger: trigger)
  return
}

if let mode = result.enforcedMode {
  AppModeManager.shared.selectMode(mode)
}
```

Keep the existing published connection, user-record, and sign-in updates before this branch. The
decision rechecks the current mode after the await so a concurrent user mode change cannot be
overwritten by stale verification.

- [ ] **Step 5: Run both focused classes and the #197 regression class; verify GREEN**

Run:

```bash
scripts/xcode-stream.sh --agent build2 --session implement_beta_fixes -- \
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -only-testing:FoqosTests/ChildRevocationTests \
  -only-testing:FoqosTests/ChildRevocationCacheTests \
  -only-testing:FoqosTests/LockCodeFailClosedTests
```

Expected: every selected test passes. In particular, the existing offline fetch retains the
persisted cache, the Family Controls trigger retains both caches, and only confirmed CloudKit
revocation erases both.

- [ ] **Step 6: Format, inspect scope, and create a signed cleanup commit**

Run:

```bash
swift-format --in-place \
  Foqos/CloudKit/CloudKitManager.swift \
  Foqos/Utils/AuthorizationVerifier.swift \
  Foqos/Utils/LockCodeManager.swift \
  FoqosTests/ChildRevocationTests.swift \
  FoqosTests/ChildRevocationCacheTests.swift
git diff --check
git diff --stat
git add Foqos/CloudKit/CloudKitManager.swift \
  Foqos/Utils/AuthorizationVerifier.swift \
  Foqos/Utils/LockCodeManager.swift \
  FoqosTests/ChildRevocationTests.swift \
  FoqosTests/ChildRevocationCacheTests.swift
git commit -S -m "fix: clear stale PIN after confirmed revocation"
```

Expected: no `CloudKitNetworkService.swift`, UI file, #428 subscription work, or unrelated cleanup
is present. Verify the signature with `git log -1 --show-signature`.

---

### Task 3: Version and verify the complete #427 change

**Files:**

- Modify: `FamilyFoqos.xcodeproj/project.pbxproj`
- Verify: every Swift and test file changed in Tasks 1–2

**Interfaces:**

- Consumes: the complete verified behavior from Tasks 1–2 and current `main` version values.
- Produces: a branch whose marketing/build versions are strictly above main and whose focused,
  full-suite, build, formatting, and repository gates pass.

- [ ] **Step 1: Re-read issue #427 and compare every done criterion to the diff**

Fetch/re-read the complete issue body. Confirm the diff shows: automatic foreground detection,
confirmed-absence versus error separation, Child-only transition, in-memory and persisted PIN
erasure, unchanged offline preservation, and focused tests for both branches. Remove any unrelated
change rather than documenting it.

- [ ] **Step 2: Re-read main's version and bump every configuration strictly above it**

Run:

```bash
git show main:FamilyFoqos.xcodeproj/project.pbxproj | \
  rg "MARKETING_VERSION|CURRENT_PROJECT_VERSION"
rg -n "MARKETING_VERSION|CURRENT_PROJECT_VERSION" \
  FamilyFoqos.xcodeproj/project.pbxproj
```

If main remains `2.0.31 (50)`, use `apply_patch` to replace every
`MARKETING_VERSION = 2.0.31;` with `MARKETING_VERSION = 2.0.32;` and every
`CURRENT_PROJECT_VERSION = 50;` with `CURRENT_PROJECT_VERSION = 51;`. Verify no old values remain
and every configuration reports the same new pair. If main advanced, use the next marketing patch
and integer build above its maxima instead.

- [ ] **Step 3: Run focused regression tests**

Run the exact Task 2 Step 5 command. Expected: all selected tests pass with zero failures.

- [ ] **Step 4: Run the complete test suite**

Run:

```bash
scripts/xcode-stream.sh --agent build2 --session implement_beta_fixes -- \
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos
```

Expected: `** TEST SUCCEEDED **` and zero failures.

- [ ] **Step 5: Run a formatted Debug build**

First validate the formatter dependency with `command -v xcbeautify`. Then run:

```bash
scripts/xcode-stream.sh --agent build2 --session implement_beta_fixes --xcbeautify -- \
  xcodebuild -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -configuration Debug build
```

Expected: wrapper exit `0` and a successful build.

- [ ] **Step 6: Run formatting and repository guards**

Validate `swift-format` and `rg` with `command -v`, then run:

```bash
swift-format --in-place \
  Foqos/CloudKit/CloudKitManager.swift \
  Foqos/CloudKit/CloudKitNetworkService+Verification.swift \
  Foqos/Utils/AuthorizationVerifier.swift \
  Foqos/Utils/LockCodeManager.swift \
  FoqosTests/ChildRevocationTests.swift \
  FoqosTests/ChildRevocationCacheTests.swift
swift-format lint --recursive .
scripts/check-c2-guards.sh
scripts/check-sync-guards.sh
scripts/run-log-privacy-lint.sh "$PWD"
git diff --check
```

Expected: formatter lint, C2 guards, I2/I5 sync guards, and privacy lint all exit `0`.

- [ ] **Step 7: Inspect the complete uncommitted version delta**

Run:

```bash
git status --short --branch
git diff main...HEAD --stat
git diff --stat
git diff --check
```

Expected: only #427 implementation/tests/docs/version files are present and no worktree is dirty
except the intentional version change.

- [ ] **Step 8: Commit the version bump as a new signed commit**

Run:

```bash
git add FamilyFoqos.xcodeproj/project.pbxproj
git commit -S -m "chore: bump version for child revocation fix"
git log -1 --show-signature
git status --short --branch
```

Expected: a good signature and a clean feature worktree.

- [ ] **Step 9: Run the strict version gate against the committed head**

Run:

```bash
scripts/check-version-increment.sh main HEAD
```

Expected: exit `0` with exactly
`Version gate passed: MARKETING_VERSION 2.0.31 -> 2.0.32; CURRENT_PROJECT_VERSION 50 -> 51.`
when main has not advanced. If main advanced and the values were recomputed, require the same
message shape with the actual strictly increasing pairs.

- [ ] **Step 10: Publish a ready-for-review PR and request independent AMQ review**

Use the `github:yeet` publish workflow: confirm the exact commit/file scope, push
`fix/427-child-revocation`, open one PR against `main` that closes #427, and mark it ready for
review (not draft). The PR body must summarize the tri-state semantics, Child-only trigger,
#197/#431 cache boundary, versions, and exact verification evidence.

Send the reviewer a self-contained AMQ `review_request` with repository, PR number, exact head SHA,
issue acceptance criteria, ownership constraint, and commands/results. Announce the review wait
when it begins. Address findings with new signed commits only, rerun proportionate verification,
and obtain review of the exact final head.

- [ ] **Step 11: Report the literal PR/review state to the planner**

Report PR number and URL, head/base SHAs, draft=false, check state, independent review decision,
version pair, and any exact remaining gate. Do not merge. #425 begins only after the planner's #427
handoff permits the strict sequential transition.
