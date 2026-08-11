# Issue #259 Bogus Supported Info.plist Key Deletion Implementation Plan

> Execute in `fix/259-delete-bogus-supported-plist-keys`. Never amend or force-push. Serialize all
> Xcode commands through `scripts/xcode-stream.sh` with `set -o pipefail` and `bundle exec xcpretty`.

**Baseline:** `f7278df`, 2.0.13/32, privacy 232/500/0.

## Task 1: Freeze evidence

1. Inventory all four target plists and the fifth production root.
2. Lint every source plist with `plutil`.
3. Search all roots, tests, scripts, and project settings for exact key reads/configuration.
4. Record commit `5ed7d75` as the actual introduction during Live Activities work.
5. Confirm both real keys are build-setting-owned in Debug and Release.
6. Inspect the baseline built main-app plist: expect Supported false, Live Activities true, and
   non-exempt encryption false.

## Task 2: Commit design and plan

Commit the approved design and this executable plan before changing the plist.

## Task 3: Delete and prove source configuration

Use `apply_patch` to delete only the two `Supported` XML lines. Then:

- run `plutil -lint` on all target plists;
- require zero exact `Supported` source/build-setting/runtime-read hits;
- run privacy lint and require unchanged 232/500/0; and
- inspect the diff to require a pure two-line plist deletion.

Commit the deletion. Do not edit either privacy baseline.

## Task 4: Version bump

Update all 12 configurations from MARKETING_VERSION 2.0.13 to 2.0.14 and
CURRENT_PROJECT_VERSION 32 to 33. Commit separately and run the version gate.

## Task 5: Exact-head verification

Run formatting, diff, C2, sync, version, privacy, plist lint, and exact-key searches. Run the full
1,223-test suite and serialized Debug build. Inspect the newly built main-app Info.plist:

- extraction of `Supported` must fail because the key is absent;
- `NSSupportsLiveActivities` must be true; and
- `ITSAppUsesNonExemptEncryption` must be false.

## Task 6: Review and publish

Request read-only independent review with base/head, target inventory, runtime-read sweep, history
correction, source/generated plist results, exact tests/build, privacy, and version evidence. The
reviewer must not mutate files or run Xcode.

Refresh main, push, and open a non-draft PR closing only #259. Monitor checks to green, verify the
exact reviewed head is OPEN/non-draft/CLEAN, and request the planner-owned merge. Do not begin #319
until merge confirmation.
