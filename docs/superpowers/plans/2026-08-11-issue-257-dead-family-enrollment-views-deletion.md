# Issue #257 Dead Family Enrollment Views Deletion Implementation Plan

> Execute in `fix/257-delete-family-enrollment-views`. Never amend or force-push. Run Xcode only
> through `scripts/xcode-stream.sh` with `set -o pipefail` and `bundle exec xcpretty`; never pass a
> simulator destination.

**Goal:** Remove two unreachable enrollment UIs and the directly orphaned role-copy helper while
preserving the live dashboard/CloudKit enrollment flow byte-for-byte.

**Baseline:** `main` `eebb04b`, version 2.0.12/31, privacy 232 files / 500 sites / 0 annotations.

## Task 1: Freeze evidence

1. Search both dead type names over all five production roots, package sources, tests, UI tests,
   resources, and project files.
2. Repeat excluding their containing files; expect no hits.
3. Search distinctive copy, onboarding/dashboard routes, dynamic type lookup, and Git history.
4. Trace the live dashboard buttons through `ShareCoordinator`, the enrollment modifier, and
   `CloudSharingView`.
5. Cascade-check every shared callee. Confirm only `FamilyRole.description` becomes orphaned.
6. Confirm no `CustomStringConvertible`, direct role interpolation, or `String(describing:)`
   dependency.
7. Run privacy lint; expect 232/500/0.
8. Run baseline targeted tests:

```bash
set -o pipefail
scripts/xcode-stream.sh --agent build1 --session collab -- \
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -only-testing:FoqosTests/FamilyMemberLogRedactionTests \
  -only-testing:FoqosTests/ScreenshotDemoModeTests 2>&1 | bundle exec xcpretty
```

Expected: 7 tests, zero failures.

## Task 2: Commit design and plan

Commit the approved spec and this plan before production edits. Both must state internal access and
the whole-module/five-root search radius.

## Task 3: Surgical deletion

Use `apply_patch` to:

1. remove the complete `AddFamilyMemberView` MARK section/declaration but retain the following
   `#Preview { ParentDashboardView() }` unchanged;
2. remove the complete `EnrollFamilyMemberButton` MARK section/declaration at the tail of
   `ShareCoordinator.swift`; and
3. remove only `FamilyRole.description` from `FamilyMember.swift`.

Do not edit the live dashboard enrollment blocks, `ShareCoordinator.enrollFamilyMember`,
`EnrollFamilyMemberModifier`, `CloudSharingView`, other role properties, imports, or route strings.

## Task 4: Prove deletion and privacy stability

1. Confirm both dead types, distinctive dead strings, and `FamilyRole.description` have zero live
   hits.
2. Confirm the live enrollment method, sheet modifier, role properties, and dashboard route retain
   live hits.
3. Extract and compare base/head live regions; require byte identity.
4. Run privacy lint. It must pass at 232/500/0 without editing either privacy baseline.
5. Commit the three directly related deletions together. State the cascade removal in the body.

## Task 5: Version bump

Update all 12 Xcode configurations to MARKETING_VERSION 2.0.13 and CURRENT_PROJECT_VERSION 32.
Commit separately, then run `scripts/check-version-increment.sh origin/main HEAD`.

## Task 6: Exact-head verification

Run static gates:

- `swift-format lint --recursive .`
- `git diff --check origin/main...HEAD`
- `scripts/check-c2-guards.sh`
- `scripts/check-sync-guards.sh`
- version gate
- privacy lint
- dead/live symbol, string, route, cascade, and byte-identity checks

Run the targeted 7 tests again, the full test suite, and a serialized Debug build. All commands must
exit zero; the full suite must report the current baseline count with zero failures.

## Task 7: Review and publish

Request a read-only deletion-focused AMQ review with base/head SHAs, access/search evidence,
five-root and route-string sweeps, cascade analysis, byte-identity results, privacy stability,
version, and exact test/build results. Reviewer must not mutate files or run Xcode.

Resolve Critical/Important findings in new commits and rerun affected verification. Refresh
`origin/main`; rebase without amend/force if needed. Open a non-draft PR closing only #257, monitor
GitHub checks to green, verify OPEN/non-draft/CLEAN/exact reviewed head, and request the
planner-owned merge. Do not start #259 until merge confirmation.
