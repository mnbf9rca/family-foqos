# Handover: README documents wrong minimum OS/toolchain: says iOS 17.6+/Xcode 15/Swift 5.9 but project requires iOS 18.6/Swift 6.0

- **GitHub issue:** #253
- **Severity:** low
- **Domain:** structural-debt
- **Primary location:** `README.md:39`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

README.md:39 states 'iOS 17.6+' under Requirements and README.md:74-76 lists 'Xcode 15.0+ / iOS 17.0+ SDK / Swift 5.9+' as development prerequisites. FamilyFoqos.xcodeproj/project.pbxproj sets IPHONEOS_DEPLOYMENT_TARGET = 18.6 and SWIFT_VERSION = 6.0 on all targets (e.g., pbxproj lines 654, 671). Additionally README.md:5, :47 and :205 contain literal 'TODO' placeholder links (title href and both App Store links) that render broken on GitHub.

## Failure scenario

A user on iOS 17.6 or 18.0 reads the README, tries to install/build the app, and it fails to run (deployment target 18.6); a contributor installs Xcode 15 per the README and the Swift 6 project fails to build. Clicking the App Store link navigates to a 404 'TODO' URL.

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, high] The claim survives refutation. README.md states requirements and prerequisites that contradict the project build settings. README.md:39 says "iOS 17.6+" and README.md:74-76 say "Xcode 15.0+ / iOS 17.0+ SDK / Swift 5.9+", but project.pbxproj sets IPHONEOS_DEPLOYMENT_TARGET = 18.6 and SWIFT_VERSION = 6.0 on every configuration (26 grep hits, all uniform — no target has a lower override that would make the README correct for any component). Swift 6 language mode is not supported by Xcode 15 (requires Xcode 16+), so a contributor following the README's toolchain would fail to build, and a user on iOS 17.6–18.5 could not run the app. The three literal "TODO" placeholder hrefs at README.md:5, :47, and :205 are also confirmed present and render as broken links. Severity is correctly rated low (documentation only, no runtime impact), but the finding is factually real with no guard, generator, or alternate source of truth elsewhere that would correct it.

## Suggested fix approach

Update Requirements to iOS 18.6+, prerequisites to Xcode 16+/Swift 6.0, and either fill in or remove the three TODO placeholder links.

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
