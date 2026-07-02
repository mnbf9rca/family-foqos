# Handover: Legacy-schedule profiles restart a manually stopped session when the app is foregrounded (no lastStoppedAt suppression on the legacy path)

- **GitHub issue:** #229
- **Severity:** medium
- **Domain:** triggers-schedules
- **Primary location:** `Packages/FoqosShared/Sources/FoqosShared/Timers/ScheduleTimerActivity.swift:58`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

PreActivationReminderScheduler.rescheduleAllReminders (PreActivationReminderScheduler.swift:10-33, called on every launch/foreground from FoqosApp.swift:141,237) calls DeviceActivityCenterUtil.scheduleTimerActivity, which stops and re-registers the schedule DeviceActivity (DeviceActivityCenterUtil.swift:69-70). Per the project's own 2026-02-14 schedule-start-timing design doc, startMonitoring inside an active interval fires intervalDidStart instantly. The V2 path in ScheduleTimerActivity.start is protected by shouldBeActiveNow's lastStoppedAt suppression, but the legacy path (lines 58-66) only checks isTodayScheduled() and olderThanOneMinute() — it ignores scheduleLastStoppedAt entirely, so the instant intervalDidStart re-creates the session and re-activates restrictions.

## Failure scenario

Unmigrated legacy profile with schedule 09:00-17:00 today and pre-activation reminders enabled: the scheduled session starts at 09:00, the user manually stops it at 10:00, backgrounds the app, and reopens it at 11:00. rescheduleAllReminders re-registers monitoring, intervalDidStart fires instantly, the legacy checks pass, and the user is re-blocked despite having stopped the session an hour earlier.

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, high] The legacy branch of ScheduleTimerActivity.start (lines 58-66) checks only isTodayScheduled() and olderThanOneMinute(), ignoring profile.scheduleLastStoppedAt, while the V2 branch (lines 48-57) suppresses via shouldBeActiveNow's lastStoppedAt check (ProfileScheduleTime.swift:163-166). Manual stop of a schedule-started session does set scheduleLastStoppedAt (BlockedProfileSessions.swift:88-92) and the snapshot carries it (BlockedProfiles.swift:534), so the data exists but is unused on the legacy path. The project's own design doc (docs/plans/completed/2026-02-14-schedule-start-timing-design.md:12) confirms startMonitoring inside an active interval fires intervalDidStart instantly (<1s), and DeviceActivityCenterUtil.scheduleTimerActivity does stopMonitoring+startMonitoring (lines 69-70); bare-UUID activities route to ScheduleTimerActivity.start with the SharedData snapshot (TimerActivityUtil.swift:38-42). Unmigrated legacy profiles exist by design (migration deferred while a session is active, ProfileMigrationUtil.swift:19-25 — exactly the state during a running scheduled session). The claimed trigger (rescheduleAllReminders on foreground, FoqosApp.swift:141/237, which re-registers legacy profiles with preActivationReminderEnabled per PreActivationReminderScheduler.swift:15-23) is reachable. Refutation attempts failed: (a) deferred migration does run at manual stop (StrategyManager.swift:603-615), but it immediately re-registers the activity mid-interval while the SharedData snapshot is still legacy-shaped (endSession's updateSnapshot ran pre-migration; neither migrateToV2IfNeeded nor scheduleTimerActivity refreshes the snapshot, and V1 snapshots have startTriggersSchedule=false per ProfileStartTriggers.swift:12 default) — so the unsuppressed legacy branch fires and re-blocks the user ~1 second after they manually stop, an even more immediate manifestation of the same root cause; (b) if that instant fire is missed, the claimed foreground-at-11:00 path re-blocks as described; (c) catchUpMissedScheduleStarts is V2-only and does not guard the legacy path. The fix sketch (apply lastStoppedAt suppression to the legacy branch, plus refreshing the snapshot after deferred migration) addresses the root cause.

## Suggested fix approach

Apply the same lastStoppedAt suppression to the legacy branch of ScheduleTimerActivity.start (compare profile.scheduleLastStoppedAt snapshot field against today's legacy window start).

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
