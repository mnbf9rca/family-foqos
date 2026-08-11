# Issue #255 Dead Child Authorization View Deletion Design

## Goal

Delete `ChildAuthorizationRequiredView`, its module-internal companion `SetupStepRow`, and their
misleading Family Sharing setup guidance because the application no longer has a presentation path
for that screen.

## Current behavior and root cause

The view was introduced for the old child-only CloudKit share flow. Commit `210ba4f` replaced that
flow with role detection and confirmation:

- the `.sheet` presenting `ChildAuthorizationRequiredView` was removed;
- `childAuthorizationFailed`, `childAuthorizationErrorMessage`, their setter/clearer, and
  `CloudKitError.childAuthorizationRequired` were removed; and
- `.notChildDevice` and `.notAuthorized` now map to `.parent`, followed by the same confirmation
  alert used for an authorized child role.

The source file remained after its trigger state and presentation path disappeared. Keeping it now
misleads maintainers into editing UX that cannot run.

## Deletion evidence

The evidence was re-derived from `main` at `e8d6b239e17b91afe2ea364447f7c13cb8addad9`, rather than
accepted from the historical handover.

### Static and stringly reachability

- Exact searches for `ChildAuthorizationRequiredView` and `SetupStepRow` across the entire Foqos
  module find Swift hits only in `Foqos/Views/Child/ChildAuthorizationRequiredView.swift` itself.
  The module-wide radius is required because `SetupStepRow` has internal access rather than
  file-private access.
- Searches for the removed trigger names `childAuthorizationFailed`,
  `setChildAuthorizationFailure`, and `childAuthorizationRequired` find no current Swift hit.
- Searches for the filename and distinctive UI strings find no resource, plist, script, project,
  route, test, or runtime lookup. Outside the file, only issue handover documentation names it.
- The only current `NSClassFromString` call checks for `XCTestCase`; there is no dynamic type lookup
  or string-based navigation capable of constructing this view.

### Five production roots and tests

The exact symbol/trigger search was run independently over all five production roots covered by the
privacy analyzer:

1. `Foqos` — matches only the file being deleted;
2. `FoqosWidget` — no match;
3. `FoqosDeviceMonitor` — no match;
4. `FoqosShieldConfig` — no match; and
5. `Packages/FoqosShared/Sources` — no match.

`FoqosTests` and `FoqosUITests` also have no match. The Xcode project uses file-system-synchronized
root groups. The file lives under the main app's `Foqos` root, is not a membership exception, and is
not named in `project.pbxproj`; deleting it requires no project-file membership edit.

### V1, schema, and persisted state

The file imports only SwiftUI. Its state consists of `@Environment(\.dismiss)` and an injected
`onDismiss` closure. Neither view conforms to `Codable`, is a SwiftData `@Model`, participates in a
versioned schema or migration, defines a CloudKit record, or reads/writes UserDefaults,
`@AppStorage`, `@SceneStorage`, or app-group `SharedData`. Its symbols and strings have no hit in V1
compatibility or migration code. Deletion therefore has no data migration or backward-compatibility
requirement.

### Lint-floor impact

The current privacy analyzer reports 233 files, 503 log sites, and 0 annotations. The file's preview
contains exactly one production-root `Log.debug` call. Deleting the file intentionally changes the
analyzer inventory to 232 files and 502 log sites. Lower
`scripts/log-privacy-baseline.txt` from `503` to `502` in the same deletion commit. Do not change the
annotation baseline.

## Considered approaches

### A. Delete the file and lower the privacy floor — approved

Remove the 146-line file and lower the site floor by exactly one. Prove the repository has no
remaining symbol or distinctive-string references, then compile and test every target through the
normal scheme. This is the smallest change that removes the misleading maintenance surface.

### B. Add a source-layout regression test — rejected

A test that reads the checkout and asserts that a filename or type is absent would test repository
layout rather than application behavior. It would be decorative, brittle, and would make a pure
deletion PR add new code.

### C. Extract and test share-role mapping — rejected for this PR

The role mapping could be refactored into a unit-testable policy, but that is feature-flow work and
does not make deletion of this already-unreachable view safer. It would materially expand a hygiene
PR.

The planner approved approach A and ruled that the handover's generic regression-test criterion
applies to behavior changes, not deletion of unreachable code.

## Implementation

1. Delete `Foqos/Views/Child/ChildAuthorizationRequiredView.swift` in one source-deletion commit.
2. In that same commit, lower `scripts/log-privacy-baseline.txt` from `503` to `502`, explicitly
   noting that the removed preview log site is deliberate.
3. Re-run exact symbol, trigger, filename, and distinctive-string searches. Only documentation may
   remain.
4. Bump every target from 2.0.10 (29) to 2.0.11 (30), provided live main has not advanced.

No share acceptance, authorization, app-mode, sync, schema, persistence, or session code changes.

## Verification and delivery

The clean baseline is 1,223 tests with zero failures. After deletion:

- prove zero live-code/resource/project references with the documented searches;
- run privacy lint and require exactly 232 files / 502 sites / 0 annotations;
- run swift-format lint, diff check, strict version gate, C2 guards, and sync guards;
- run all tests and a Debug build through the serialized Xcode stream;
- request a read-only independent review with the full deletion evidence; and
- open one undrafted PR that closes only #255, then wait for green CI and planner-owned merge.

The branch must remain strictly above live main's version, and no work on #256 starts until the
planner confirms #255 merged.
