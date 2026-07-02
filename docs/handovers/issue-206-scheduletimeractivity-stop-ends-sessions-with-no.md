# Handover: ScheduleTimerActivity.stop ends sessions with no day-of-week, stop-condition, or session-origin check

- **GitHub issue:** #206
- **Severity:** high
- **Domain:** triggers-schedules
- **Primary location:** `Packages/FoqosShared/Sources/FoqosShared/Timers/ScheduleTimerActivity.swift:88`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

The combined schedule DeviceActivity is registered with repeats:true and only hour/minute components (DeviceActivityCenterUtil.swift:61-70), so intervalDidEnd fires EVERY day at the end time — including days not in the profile's schedule. ScheduleTimerActivity.start correctly filters via shouldBeActiveNow/isTodayScheduled, but stop() (lines 88-110) only checks that the active session's profile ID matches before calling deactivateRestrictions() and endActiveSharedSession(). It performs no isTodayScheduled check (contrast StopScheduleTimerActivity.stop, lines 36-41, which has one), no check that stopConditions.schedule is even enabled, and no check that the session was scheduler-started. Worse, when no stop schedule is configured, DeviceActivityCenterUtil.swift:47-52 synthesizes intervalEnd = start minus 1 minute, so intervalDidEnd fires daily at that synthetic time for profiles whose stop conditions are manual-only.

## Failure scenario

Profile has start triggers {manual, schedule Mon-Fri 09:00} and stop schedule 17:00 (or manual-only stop). User manually starts a session Saturday 10:00. Saturday 17:00 (or at start-minus-1-minute for manual-only-stop profiles) the monitor extension's intervalDidEnd fires, ScheduleTimerActivity.stop matches the profile ID and silently lifts all restrictions and ends the session — on a day the schedule doesn't apply and via a stop condition the user never enabled. On a locked child profile this is an unattended blocking bypass.

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, high] Every link in the claimed failure chain is confirmed by code. (1) The schedule DeviceActivity is registered with repeats:true and hour/minute-only components, so intervalDidEnd fires EVERY day at intervalEnd, not just scheduled days. (2) When stop conditions are manual-only, DeviceActivityCenterUtil synthesizes intervalEnd = start minus 1 minute, so intervalDidEnd still fires daily for profiles the user configured to stop only manually. (3) The monitor extension routes intervalDidEnd unconditionally to ScheduleTimerActivity.stop (DeviceActivityMonitorExtension.swift:37-42 → TimerActivityUtil.stopTimerActivity). (4) ScheduleTimerActivity.stop (lines 88-110) checks ONLY that the active shared session's profile ID matches, then calls appBlocker.deactivateRestrictions() and SharedData.endActiveSharedSession(). It has no isTodayScheduled check, no stopConditionsSchedule check, and no session-origin (tag) check — while start() in the same file carefully filters via shouldBeActiveNow/isTodayScheduled, and the sibling StopScheduleTimerActivity.stop (lines 36-41) DOES check stopSchedule.isTodayScheduled(), proving the omission is an oversight rather than design. (5) Manually started sessions ARE visible to the extension: BlockedProfileSession.createSession writes SharedData.createActiveSharedSession(for: newSession.toSnapshot()) (BlockedProfileSessions.swift:138), which is exactly what getActiveSharedSession() returns; the codebase itself documents that scheduler-origin sessions are distinguishable by tag == profile UUID (BlockedProfileSessions.swift:87-88) yet stop() never checks it. (6) Nothing deregisters the schedule activity during a manual session — StrategyManager.cleanUpGhostSchedules removes activities only for schedule-less or deleted profiles. Concrete failure: Mon-Fri 09:00 profile with manual-only stop; user manually starts Saturday 10:00; Sunday 08:59 (synthetic end) intervalDidEnd fires, profile IDs match, all restrictions silently lifted and session ended; the subsequent intervalDidStart at 09:00 does not restart because Sunday fails shouldBeActiveNow. On a locked child profile this is an unattended blocking bypass. The refute lens found no compensating guard anywhere in the call chain.

> [real=true, high] Every step of the failure chain reproduces in code. (1) The schedule DeviceActivity is registered per profile with only hour/minute components and repeats:true (DeviceActivityCenterUtil.swift:61-65), so intervalDidEnd fires daily regardless of the profile's weekday set; weekday filtering happens only in start() via shouldBeActiveNow/isTodayScheduled (ScheduleTimerActivity.swift:48-70). (2) When stopConditions.schedule is false, DeviceActivityCenterUtil.swift:46-52 synthesizes intervalEnd = start minus 1 minute, so intervalDidEnd still fires daily for manual-stop-only profiles. (3) The monitor extension routes intervalDidEnd for a bare-UUID activity name to ScheduleTimerActivity.stop (DeviceActivityMonitorExtension.swift:37-42, TimerActivityUtil.swift:35-47). (4) stop() (ScheduleTimerActivity.swift:88-110) checks ONLY that the active shared session's profile ID matches — no isTodayScheduled, no stopConditionsSchedule, no session-origin/tag check — then deactivates restrictions and ends the session. StopScheduleTimerActivity.stop:36-41 has exactly the missing isTodayScheduled guard, confirming the check is intended elsewhere. (5) Manually started sessions ARE visible to the extension: BlockedProfileSession.createSession writes SharedData.createActiveSharedSession (BlockedProfileSessions.swift:138) with tag = strategy id (e.g. ManualBlockingStrategy.swift:34-39), so a Saturday manual session on a Mon-Fri profile matches by profile ID and is killed at 17:00 (or start-1min). (6) deactivateRestrictions() clears the shared named ManagedSettingsStore "familyFoqosAppRestrictions" (AppBlockerUtil.swift:5-7, 52-65), lifting shields device-wide immediately, and the ended snapshot is later upserted as completed by the main app (StrategyManager.swift:784-789), so the session is not resurrected. On a locked child profile this ends blocking with no user action — a real high-severity blocking bypass / wrong-behavior defect.

## Suggested fix approach

In ScheduleTimerActivity.stop, guard that today (window) is a scheduled day and that the active session is scheduler-started (tag == profile UUID) or that stopConditionsSchedule is true, mirroring the checks in start() and StopScheduleTimerActivity.stop.

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
