# Handover: FoqosUITests target has zero source files and no source directory, yet is a parallelizable target in FamilyFoqos.xctestplan

- **GitHub issue:** #258
- **Severity:** low
- **Domain:** structural-debt
- **Primary location:** `FamilyFoqos.xctestplan:33`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

FamilyFoqos.xctestplan includes test target FoqosUITests (identifier 801B20AF2CB363A20073E9E2, line 33). In project.pbxproj that target's Sources build phase (801B20AC2CB363A20073E9E2, pbxproj lines 592-598) has an empty files list, the target has no fileSystemSynchronizedGroups, and no FoqosUITests directory exists in the repo. Every `xcodebuild test` run builds, signs, installs and launches an empty UI-test runner bundle on the simulator.

## Failure scenario

Test runs pay the cost of building/deploying a UI-test runner that can never contain a test, and the test plan reports a green 'FoqosUITests' target, giving a false signal that UI testing exists; anyone adding a UI test file to a new FoqosUITests folder will find it is not actually compiled into the target (empty explicit Sources phase, no synchronized group).

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, high] Verified all three legs of the claim: (1) the xctestplan includes FoqosUITests as a parallelizable test target; (2) the pbxproj target 801B20AF2CB363A20073E9E2 is a ui-testing bundle whose Sources build phase 801B20AC2CB363A20073E9E2 has an empty files list and, unlike every other target in the project, has no fileSystemSynchronizedGroups entry; (3) no FoqosUITests directory exists in the repo root. Every `xcodebuild test` run therefore builds and deploys an empty UI-test runner, and new test files added to a FoqosUITests folder would not be compiled (explicit empty Sources phase, no synchronized group). This is real orphaned scaffolding; severity low as claimed since it wastes build time and gives a false green UI-test signal but breaks nothing functional.

## Suggested fix approach

Remove the FoqosUITests target from project.pbxproj and from FamilyFoqos.xctestplan, or populate it with a synchronized folder and real tests.

This is a sketch, not a spec. Re-trace the defect yourself first (use the superpowers systematic-debugging skill), then design the minimal fix. If the fix touches sync, mode logic, or session lifecycle, check the App Modes table in AGENTS.md and `docs/codebase-analysis/deviation-report.md` for recorded design intent before changing behavior.

## Acceptance criteria

- The failure scenario above can no longer be reproduced by code inspection or test.
- A regression test exists in `FoqosTests` covering the scenario (naming: `testGivenX_WhenY_ThenZ`), where the defect is testable at unit level.
- No behavior change outside the defect's scope; all existing tests pass.
- swift-format clean; code review requested before merge (AGENTS.md requirement).

## Project conventions (mandatory — from AGENTS.md)

- Read `AGENTS.md` at the repo root before writing any code. It overrides everything else.
- Work on a feature branch off `main`. NEVER amend or force-push; new commits only. Request code review before merging.
- Views must use `@SafeQuery` (never raw `@Query`); non-query model arrays must be filtered with `.valid`.
- Lock-code restriction checks must use `appModeManager.currentMode == .child` — the pattern `!= .parent` is forbidden (it wrongly blocks Individual mode).
- Use `Log.<level>(_, category:)` instead of `print()`. Never log lock codes or personal identifiers.
- swift-format is enforced by a pre-commit hook (2-space indent, ~100-120 col).
- Tests: name `testGivenX_WhenY_ThenZ()`; pin time — capture one `let now = Date()` per test and inject via `now:` parameters.
- Run tests against an already-booted simulator by UUID (never by device name):
  `xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' | xcpretty`

## Architecture context

- SwiftData + a CUSTOM CloudKit sync layer (SwiftData auto CloudKit sync is disabled, `cloudKitDatabase: .none`).
- Profiles sync same-user via `ProfileSyncManager` (private DB); lock codes sync parent->child via `FamilyCommand` (shared DB).
- Blocking is enforced via FamilyControls / ManagedSettings / DeviceActivity across the main app, the `FoqosDeviceMonitor` extension, `FoqosShieldConfig`, and `FoqosWidget`, sharing state through the `FoqosShared` package (app group `SharedData`).
- App modes: Individual / Parent / Child — see the mode table in AGENTS.md before touching any lock or mode logic.
