# Handover: Deviation #17 still present: disableBackgroundStops ignored by schedule-based stops (StopScheduleTimerActivity)

- **GitHub issue:** #239
- **Severity:** medium
- **Domain:** deviation-audit
- **Primary location:** `Packages/FoqosShared/Sources/FoqosShared/Timers/StopScheduleTimerActivity.swift:22`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

The deviation recorded 2026-02-09 is unchanged. StopScheduleTimerActivity.stop() (lines 22-47) ends the active session and calls appBlocker.deactivateRestrictions() (line 45) without ever checking the profile's disableBackgroundStops flag, even though the flag is available on the snapshot it receives (SharedData.ProfileSnapshot.disableBackgroundStops, Packages/FoqosShared/Sources/FoqosShared/SharedData.swift:173). The scheduling side also ignores it: DeviceActivityCenterUtil.scheduleStopActivity (Foqos/Utils/DeviceActivityCenterUtil.swift:101-120) registers the stop-only DeviceActivity based solely on stopConditions.schedule/stopSchedule.isActive. By contrast, deep-link stops (Foqos/Utils/StrategyManager.swift:234-241) and Shortcuts/background stops (Foqos/Utils/StrategyManager.swift:429-435) both enforce the flag. Per the deviation report, schedule-based stops should also respect disableBackgroundStops.

## Failure scenario

User enables both 'Disable Background Stops' and a scheduled stop time on a profile, then starts a session and backgrounds the app. When the stop schedule's intervalDidEnd fires in the FoqosDeviceMonitor extension, StopScheduleTimerActivity.stop() lifts all restrictions and ends the shared session in the background — exactly the class of stop the disableBackgroundStops toggle claims to prevent — creating inconsistent enforcement versus deep-link and Shortcuts stops, which are refused.

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, high]  

## Suggested fix approach

In StopScheduleTimerActivity.stop(), guard on profile.disableBackgroundStops == true and return without deactivating restrictions (or, alternatively, skip registering the stop activity in DeviceActivityCenterUtil.scheduleStopActivity when the flag is set). If the product decision is instead that scheduled stops are intentionally exempt, update the toggle description in Foqos/Views/BlockedProfileView.swift:427-433 and close the deviation explicitly.

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
