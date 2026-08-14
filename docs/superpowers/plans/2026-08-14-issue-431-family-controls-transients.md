# Issue #431 Family Controls Transients Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent Family Controls contention and other non-authoritative failures from making an existing Child leave and rejoin locally, while retaining pre-share role detection and CloudKit-confirmed revocation.

**Architecture:** Decode `FamilyControlsError` into explicit typed verification results, then apply a separate enrolled-Child disposition that is non-destructive for every Family Controls failure. Narrow destructive cleanup to the existing CloudKit-confirmed revocation producer, and route recoverable verification copy through the Child dashboard instead of share-acceptance or destructive authorization-lost UI.

**Tech Stack:** Swift 6, SwiftUI, FamilyControls, CloudKit, XCTest, Xcode simulator gate.

## Global Constraints

- Work only in `.worktrees/build1-431` on `fix/431-family-controls-transients`.
- Base is main `2f707c1`, version 2.0.37 (56); publish reserved version 2.0.38 (57).
- Use typed `FamilyControlsError` cases and `@unknown default`; do not restore domain-string classification.
- No Family Controls result may clear shared state, erase the child PIN cache, or select Individual.
- Only `CloudKitManager.confirmedRevocationTrigger` may reach destructive confirmed-revocation cleanup.
- Preserve `invalidAccountType -> notChildDevice` only for human-confirmed pre-share Parent role detection.
- Code 4 guidance must say the check could not complete and can be retried; never claim revocation or require a new invitation.
- Do not expand into issue #435's genuine-revocation explanation copy.
- Every commit must be new and signed; the planner merges.

---

### Task 1: Typed Family Controls mapping and CloudKit-only destruction

**Files:**
- Modify: `Foqos/Utils/AuthorizationVerifier.swift`
- Modify: `Foqos/CloudKit/CloudKitManager.swift`
- Modify: `Foqos/Utils/LockCodeManager.swift`
- Create: `FoqosTests/FamilyControlsVerificationTests.swift`
- Modify: `FoqosTests/ChildRevocationCacheTests.swift`

**Interfaces:**
- Produces: `AuthorizationVerifier.verificationResult(for: NSError) -> VerificationResult`.
- Produces: new `VerificationResult.authorizationConflict` and `.authorizationCanceled` cases with recoverable `errorMessage` copy.
- Produces: `AuthorizationVerifier.VerificationDisposition` with only `.authorized` and `.indeterminate` Family Controls outcomes.
- Produces: `AuthorizationVerifier.handleConfirmedCloudKitRevocation() async -> String` and `LockCodeManager.handleConfirmedCloudKitRevocation()` as the only destructive cleanup path.
- Consumes: `CloudKitManager.confirmedRevocationTrigger` from #433 as the sole authority for that path.

- [ ] **Step 1: Write failing same-domain typed-mapping tests**

Add fixtures using `FamilyControlsError.errorDomain` and raw values, not hard-coded domain strings:

```swift
func testGivenSameFamilyControlsDomain_WhenCodesDiffer_ThenTypedOutcomesRemainDistinct() {
  let invalidAccount = NSError(
    domain: FamilyControlsError.errorDomain,
    code: FamilyControlsError.invalidAccountType.rawValue)
  let conflict = NSError(
    domain: FamilyControlsError.errorDomain,
    code: FamilyControlsError.authorizationConflict.rawValue)

  guard case .notChildDevice = AuthorizationVerifier.verificationResult(for: invalidAccount)
  else { return XCTFail("invalidAccountType must remain the pre-share non-child signal") }
  guard case .authorizationConflict = AuthorizationVerifier.verificationResult(for: conflict)
  else { return XCTFail("authorizationConflict must remain recoverable") }
}
```

Add table tests for `restricted`, `unavailable`, `invalidArgument`, `authorizationCanceled`,
`networkError`, `authenticationMethodUnavailable`, availability-gated `unauthorized`, and an
unknown raw code. Assert every non-authorized result produces `.indeterminate` at the enrolled
Child disposition layer.

- [ ] **Step 2: Run the focused tests and confirm RED**

Run:

```bash
scripts/xcode-stream.sh --agent build1 --session issue_431 --xcbeautify -- xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -only-testing:FoqosTests/FamilyControlsVerificationTests
```

Expected: compile/test failure because the mapper and recoverable result cases do not exist and
the current `.notChildDevice` disposition is `.confirmedLoss`.

- [ ] **Step 3: Implement the minimal typed mapper and non-destructive disposition**

In `AuthorizationVerifier`, decode only the SDK error domain, switch on the typed enum, and preserve
future cases:

```swift
static func verificationResult(for error: NSError) -> VerificationResult {
  guard error.domain == FamilyControlsError.errorDomain,
    let familyControlsError = FamilyControlsError(rawValue: error.code)
  else {
    return error.domain == NSURLErrorDomain ? .networkError(error) : .unknownError(error)
  }

  if #available(iOS 26.4, *), familyControlsError == .unauthorized {
    return .notAuthorized
  }

  switch familyControlsError {
  case .invalidAccountType:
    return .notChildDevice
  case .authorizationConflict:
    return .authorizationConflict
  case .authorizationCanceled:
    return .authorizationCanceled
  case .networkError:
    return .networkError(error)
  case .restricted, .unavailable, .invalidArgument, .authenticationMethodUnavailable:
    return .unknownError(error)
  @unknown default:
    return .unknownError(error)
  }
}
```

Keep the availability-gated equality check ahead of the switch so deployment targets below iOS
26.4 compile while `@unknown default` still protects future SDK cases. Make
`verifyChildAuthorization()` delegate its catch to this mapper. Map `.authorized` to
`.authorized` and every other result to `.indeterminate`; `verifyIfNeeded()` logs indeterminate
results and never invokes destructive cleanup.

- [ ] **Step 4: Narrow the destructive APIs to CloudKit confirmation**

Rename `AuthorizationVerifier.handleAuthorizationLoss(trigger:)` to
`handleConfirmedCloudKitRevocation()` with no default or Family Controls trigger. Rename the lock
manager cleanup similarly. Update only `CloudKitManager.verifySelfFamilyMemberRecord()` to call it
after `confirmedRevocationTrigger` succeeds. Remove Family Controls/dashboard/refresh calls into
that cleanup.

- [ ] **Step 5: Update revocation-cache tests and verify GREEN**

Keep the confirmed-CloudKit test proving the PIN cache is erased. Replace the obsolete direct
Family Controls cleanup invocation with classifier coverage proving each Family Controls failure
is indeterminate and never reaches the narrowed cleanup API. Re-run the Task 1 focused command,
plus:

```bash
scripts/xcode-stream.sh --agent build1 --session issue_431 --xcbeautify -- xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -only-testing:FoqosTests/ChildRevocationTests -only-testing:FoqosTests/ChildRevocationCacheTests
```

Expected: all selected tests pass with zero failures.

- [ ] **Step 6: Format, inspect, and commit Task 1**

Run changed-file `swift-format`, `swift-format lint`, and `git diff --check`, then create:

```bash
git commit -S -m "fix: classify Family Controls failures safely"
```

---

### Task 2: Recovery sequence, role detection, refresh, and dashboard guidance

**Files:**
- Modify: `Foqos/Utils/AuthorizationVerifier.swift`
- Modify: `Foqos/Utils/LockCodeManager.swift`
- Modify: `Foqos/FoqosApp.swift`
- Modify: `Foqos/Views/Child/ChildDashboardView.swift`
- Modify: `FoqosTests/FamilyControlsVerificationTests.swift`
- Modify: `FoqosTests/ChildSharedRefreshTests.swift`

**Interfaces:**
- Produces: `AuthorizationVerifier.detectedFamilyRole(for:) -> FamilyRole?`, where only
  `.authorized` returns Child and `.notChildDevice` returns Parent.
- Produces: `LockCodeManager.sharedRefreshAuthorizationResult(persisted:verify:) async -> VerificationResult` so bootstrap failures retain recoverable copy.
- Consumes: `VerificationResult.errorMessage` for dashboard and refresh retry guidance.

- [ ] **Step 1: Write failing sequence, role, copy, and bootstrap tests**

Add a sequence fixture for `[.authorizationConflict, .authorized]` starting in Child mode. Assert
the first disposition is indeterminate, the second authorized, the role detector returns nil for
the conflict, no step requests Individual or invitation state, and the final mode remains Child.

Add role assertions:

```swift
XCTAssertEqual(AuthorizationVerifier.detectedFamilyRole(for: .authorized), .child)
XCTAssertEqual(AuthorizationVerifier.detectedFamilyRole(for: .notChildDevice), .parent)
XCTAssertNil(AuthorizationVerifier.detectedFamilyRole(for: .notAuthorized))
XCTAssertNil(AuthorizationVerifier.detectedFamilyRole(for: .authorizationConflict))
```

Assert conflict copy contains "couldn't check" and "try again" (case-insensitive), and excludes
"removed", "revoked", "invitation", and "leave". Update shared-refresh tests so persisted Child
skips verification, missing persistence verifies exactly once, and conflict returns a failed
refresh result without a destructive action.

- [ ] **Step 2: Run selected tests and confirm RED**

Run:

```bash
scripts/xcode-stream.sh --agent build1 --session issue_431 --xcbeautify -- xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -only-testing:FoqosTests/FamilyControlsVerificationTests -only-testing:FoqosTests/ChildSharedRefreshTests
```

Expected: failures for the missing role detector/result-returning bootstrap seam and old copy.

- [ ] **Step 3: Implement role and refresh integration**

Make share acceptance use `detectedFamilyRole(for:)`; only `.notChildDevice` proposes Parent.
Every nil role result uses its recoverable `errorMessage` and returns without opening the role
confirmation dialog. Update the `.notAuthorized` branch/comment so it no longer treats that result
as Parent.

Change shared-refresh bootstrap to return the actual verification result:

```swift
static func sharedRefreshAuthorizationResult(
  persisted authorizationType: AuthorizationVerifier.AuthorizationType,
  verify: () async -> AuthorizationVerifier.VerificationResult
) async -> AuthorizationVerifier.VerificationResult {
  guard authorizationType != .child else { return .authorized }
  return await verify()
}
```

Proceed only for `.authorized`; for `.indeterminate`, set `LockCodeManager.error` to truthful
recoverable copy and return `.failed` without clearing cache, shared state, or mode.

- [ ] **Step 4: Repurpose the Child dashboard alert**

Replace `showAuthorizationLostAlert` with an optional recoverable message. Title the alert
"Unable to Verify Screen Time", show the result's error message, keep `Try Again` and a cancel
action, and remove `Switch to Individual Mode` plus `handleAuthorizationLost()`. Do not change
genuine CloudKit revocation copy owned by #435.

- [ ] **Step 5: Verify GREEN and commit Task 2**

Run the Task 2 focused command, `ChildDashboardCopyTests`, changed-file formatting/lint, and
`git diff --check`. Expected: all selected tests pass with zero failures. Create:

```bash
git commit -S -m "fix: recover from Family Controls contention"
```

---

### Task 3: Version, full verification, review, and delivery

**Files:**
- Modify: `FamilyFoqos.xcodeproj/project.pbxproj`
- Modify: PR body only after publishing

**Interfaces:**
- Produces: every target/configuration at marketing version 2.0.38 and build 57.
- Consumes: all Task 1 and Task 2 tests and the project delivery workflow.

- [ ] **Step 1: Bump every target configuration**

Change every `MARKETING_VERSION = 2.0.37;` to `2.0.38` and every
`CURRENT_PROJECT_VERSION = 56;` to `57`. Verify the project contains only the reserved pair.

- [ ] **Step 2: Run complete verification**

Run changed-file `swift-format lint`, `git diff --check`, focused authorization/revocation/refresh
tests, the full simulator-gated suite, and:

```bash
scripts/xcode-stream.sh --agent build1 --session issue_431 --xcbeautify -- xcodebuild -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -configuration Debug build
```

Read each exit status and test count before claiming success.

- [ ] **Step 3: Commit the version bump and verify signatures**

Create a new signed commit without amending:

```bash
git commit -S -m "chore: bump version to 2.0.38"
```

Verify every branch commit reports a good signature and the worktree is clean.

- [ ] **Step 4: Obtain independent exact-head review**

Review the complete `origin/main...HEAD` diff against issue #431, the approved design/spec, typed
mapping table, destructive boundary, recovery copy, tests, and version. Fix Critical/Important
findings only in new signed commits, then rerun affected and full gates.

- [ ] **Step 5: Publish and route workflow review**

Push without force, create a ready-for-review PR that closes #431, confirm Version gate,
mergeability, exact head, and non-draft status, then send the exact SHA and validation evidence to
the workflow reviewer and planner. The planner performs the merge.
