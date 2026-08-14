# Issue #435 CloudKit Revocation Notice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this
> plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface a truthful one-shot explanation after confirmed CloudKit family removal, for
both foreground and silent-push discovery, while isolating the revocation cache test.

**Architecture:** Keep CloudKit membership verification as the sole confirmation authority. Route
foreground and child shared-database pushes through the same verifier and one destructive
transition, which publishes dedicated alert state after cleanup. Keep share-acceptance UI and
Family Controls failures independent.

**Tech Stack:** Swift 6, SwiftUI, CloudKit, FamilyControls, XCTest, Xcode simulator gate.

## Constraints

- Work only in `.worktrees/build1-435` on `fix/435-revocation-notice`.
- Base is `3410b5d`, version 2.0.42 (61); publish reserved version 2.0.44 (63).
- Use the planner-approved alert title and message verbatim.
- Only confirmed CloudKit absence may clear family state or select Individual.
- The silent shared-database push must verify membership before child-data refresh.
- Do not reuse share-acceptance state or copy.
- Remove all `AppModeManager` access from `ChildRevocationCacheTests`.
- Every commit must be new and signed; the planner merges.

---

### Task 1: Add failing behavior and hygiene tests

**Files:**
- Modify: `FoqosTests/ChildRevocationTests.swift`
- Modify: `FoqosTests/ChildSharedRefreshTests.swift`
- Modify: `FoqosTests/FamilyControlsVerificationTests.swift`
- Modify: `FoqosTests/ChildRevocationCacheTests.swift`

- [ ] Rename trigger assertions to the missing Bool API and keep every positive/negative case.
- [ ] Add tests for exact alert title/copy, forbidden `Screen Time` and `Family Sharing` wording,
      cleanup-before-publication, and one-shot dismissal state.
- [ ] Add background routing tests: a cold child shared push refreshes account status before
      membership verification; confirmed revocation skips child refresh and reports `.newData`;
      unchanged membership retains the current refresh result.
- [ ] Remove the cache test's `originalMode`, `selectMode(.child)`, and restoration.
- [ ] Add/retain typed-mapping coverage proving `.unauthorized` and unknown cases are non-destructive.
- [ ] Run selected tests and confirm RED from missing production APIs:

```bash
scripts/xcode-stream.sh --agent build1 --session issue_435 --xcbeautify -- xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -only-testing:FoqosTests/ChildRevocationTests -only-testing:FoqosTests/ChildRevocationCacheTests -only-testing:FoqosTests/ChildSharedRefreshTests -only-testing:FoqosTests/FamilyControlsVerificationTests
```

---

### Task 2: Implement the common transition and alert

**Files:**
- Modify: `Foqos/CloudKit/CloudKitManager.swift`
- Modify: `Foqos/Utils/AuthorizationVerifier.swift`
- Modify: `Foqos/FoqosApp.swift`

- [ ] Add `@Published var familyRevocationMessage: String?` plus internal title/message constants.
- [ ] Add one confirmed-revocation transition that performs injected/production cleanup first,
      then publishes the approved message. Make authorization cleanup synchronous `Void`.
- [ ] Replace the optional single-case trigger with `isConfirmedRevocation(...) -> Bool`.
- [ ] Have membership verification return whether it handled confirmed revocation so foreground can
      ignore the result and background can skip child refresh/report `.newData` after demotion.
- [ ] Extract the background child-refresh sequence behind injected account-status/verifier/refresh
      closures, use it from `AppDelegate`, and preserve existing `.noData`/`.failed` results without
      revocation.
- [ ] Present dedicated `Family Connection Removed` root alert and clear its state on dismissal.
- [ ] Remove the redundant iOS 26.4 pre-check; retain `.unauthorized` and `@unknown default`.
- [ ] Run the focused command until GREEN, then format changed Swift files and run `git diff --check`.
- [ ] Create a new signed implementation commit.

---

### Task 3: Version, verify, review, and deliver

**Files:**
- Modify: `FamilyFoqos.xcodeproj/project.pbxproj`

- [ ] Set every `MARKETING_VERSION` to 2.0.44 and every `CURRENT_PROJECT_VERSION` to 63.
- [ ] Run changed-file `swift-format lint`, `git diff --check`, focused tests, full simulator-gated
      tests, and standalone Debug build through the `issue_435` stream.
- [ ] Run project structural/version guards and verify all branch commits have good signatures.
- [ ] Create a new signed version commit and confirm the worktree is clean.
- [ ] Obtain independent review of the exact `origin/main...HEAD` diff. Address Critical/Important
      findings only in new signed commits and rerun affected/full gates.
- [ ] Push without force, open a ready-for-review PR closing #435, confirm exact head/version gate/
      mergeability, then send exact-SHA evidence to the workflow reviewer and planner. The planner
      performs the merge.
