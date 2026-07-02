# Handover: V2 schedule windows shorter than 15 minutes (including stop-only schedules before 00:15) fail DeviceActivity registration silently

- **GitHub issue:** #228
- **Severity:** medium
- **Domain:** triggers-schedules
- **Primary location:** `Foqos/Utils/DeviceActivityCenterUtil.swift:61`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

scheduleTimerActivity builds the combined DeviceActivitySchedule directly from the user-chosen start/stop times (lines 34-70); TriggerConfigurationModel.validate (TriggerConfigurationModel.swift:60-65) only rejects start == stop, not windows under DeviceActivity's 15-minute minimum, so a 09:00-09:10 window (or 23:55-00:05 cross-midnight window) makes startMonitoring throw intervalTooShort, caught at DeviceActivityCenterUtil.swift:79-81 with only Log.info. Likewise the stop-only activity (lines 122-130) anchors intervalStart at 00:00, so any stop time before 00:15 produces a sub-15-minute interval whose failure is only Log.error at lines 139-144. In both cases the profile UI shows a configured schedule that will never fire.

## Failure scenario

Parent configures a child profile to start on schedule at 21:50 and stop at 22:00 (10-minute window), or a manual-start profile with a scheduled stop at 00:10. Registration throws intervalTooShort, nothing is shown to the user, and the schedule never starts (or the session is never stopped at midnight+10) — blocking silently doesn't happen as configured.

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, high] Verified against the code: (1) sub-15-minute windows are reachable — ScheduleTimePicker uses a minute-granular wheel DatePicker whose Save is disabled only when times are exactly equal; (2) the only schedule validation anywhere (TriggerConfigurationModel.validate lines 60-65 plus TriggerValidator rules) rejects start==stop, never window length — grep for any intervalTooShort/minimum-interval guard across the repo finds nothing; (3) scheduleTimerActivity passes raw hour/minute into DeviceActivitySchedule and catches startMonitoring errors with Log.info only (lines 79-81), and the function returns Void so callers like BlockedProfileView.saveProfile cannot surface the failure; (4) the stop-only path hardcodes intervalStart 00:00 (line 123), so any stop time before 00:15 yields a <15-minute interval whose failure is Log.error only (lines 139-144). Apple's DeviceActivity framework documents a 15-minute minimum interval enforced via MonitoringError.intervalTooShort, so a 21:50-22:00 window or a 00:10 stop-only schedule silently fails to register while the UI shows a configured schedule. The only inaccuracy in the claim is trivial: cross-midnight windows (stop before start) wrap to ~24h and do NOT fail, but the same-day short window and early stop-only cases are real and unguarded.

## Suggested fix approach

Add a >= 15-minute window validation error in TriggerConfigurationModel.validate (both same-day and overnight math, and stop-only vs midnight anchor), and surface startMonitoring failures to the UI instead of log-only.

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
