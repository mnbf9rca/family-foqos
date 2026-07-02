# Handover: 5- and 10-minute break durations schedule DeviceActivity intervals below the 15-minute minimum, so breaks never start

- **GitHub issue:** #214
- **Severity:** high
- **Domain:** widgets-extensions
- **Primary location:** `Foqos/Utils/DeviceActivityCenterUtil.swift:225`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

startBreakTimerActivity builds a DeviceActivitySchedule from profile.breakTimeInMinutes via getTimeIntervalStartAndEnd (now to now+N minutes). The break flow relies entirely on the FoqosDeviceMonitor extension: BreakTimerActivity.start deactivates restrictions and sets breakStartTime when intervalDidStart fires. BlockedProfileView.swift:409-410 offers 5-minute and 10-minute break options, both below the 15-minute DeviceActivitySchedule minimum, so startMonitoring throws intervalTooShort, which startBreakTimerActivity only logs. StrategyManager.startBreak (StrategyManager.swift:663-688) then proceeds regardless: it schedules the 'Break almost over!' notification (scheduleBreakReminder) and updates the Live Activity even though no break ever begins.

## Failure scenario

User sets Break Duration to 5 minutes, starts a session, taps the Break button -> the monitor activity fails to schedule -> restrictions never lift, breakStartTime never set, the UI stays in blocking state, and 4 minutes later the user receives a misleading 'Break almost over! ... starting X in 1 minute' notification for a break that never happened.

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, high] Every link in the claimed failure chain is confirmed in code. The break-duration picker offers 5 and 10 minute options. startBreakTimerActivity schedules a DeviceActivitySchedule spanning exactly breakTimeInMinutes (now to now+N), which for 5/10 minutes is below the DeviceActivity framework's 15-minute minimum interval (DeviceActivityCenter.MonitoringError.intervalTooShort); its catch block only logs. The break's actual effect (deactivateRestrictions + setBreakStartTime) happens ONLY in BreakTimerActivity.start, which is reachable ONLY via the FoqosDeviceMonitor extension's intervalDidStart — there is no app-side fallback (grep of all deactivateRestrictions call sites confirms). StrategyManager.startBreak proceeds unconditionally after the failed scheduling: it schedules the break-reminder notification at (N-1)*60 seconds, reloads widgets, and updates the Live Activity, so the user gets a 'break almost over' notification for a break that never started while restrictions remain active. Decisive internal corroboration: the sibling startOneMoreMinute was already hardened against exactly this failure class ('Schedule DeviceActivity enforcement FIRST — if this fails, don't lift restrictions' with an abort-on-throw), while startBreak has no such guard and startBreakTimerActivity doesn't rethrow. Even if iOS silently ignored (rather than threw on) a sub-15-minute schedule, the outcome is identical: intervalDidStart never fires and the break never begins. Only the 15/30-minute options can work. The single premise not provable from the repo alone is the framework's 15-minute minimum, but it is documented Apple API behavior (MonitoringError.intervalTooShort) and widely reproduced.

> [real=true, high] Every step of the failure chain reproduces in the code as written: the UI offers 5- and 10-minute break durations; startBreakTimerActivity builds a DeviceActivitySchedule of exactly that length; Apple's DeviceActivity framework rejects schedules under 15 minutes with MonitoringError.intervalTooShort; the catch block only logs and the function returns normally; StrategyManager.startBreak then unconditionally schedules the "Break almost over!" notification, reloads widgets, and updates the Live Activity break state. Restriction lifting and breakStartTime are set ONLY in the monitor extension's intervalDidStart handler (BreakTimerActivity.start), which never fires because monitoring was never registered. Result: for 5/10-minute breaks, restrictions never lift, the break never starts, yet the user gets a "break almost over" notification and a break-state Live Activity. The single element not provable from repo code is the 15-minute minimum, which is documented Apple framework behavior; the codebase's own default of 15 minutes (BlockedProfiles.swift:28) and the fact that 15/30-minute options work are consistent with it.

## Suggested fix approach

Remove the 5 and 10 minute options (or clamp to 15), or have startBreakTimerActivity throw and make startBreak abort (and surface an error) when scheduling fails instead of continuing to schedule the reminder notification.

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
