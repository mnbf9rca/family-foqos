# Handover: activateSession/stopBreak wipe ALL pending notifications, killing other profiles' pre-activation reminders until next app foreground

- **GitHub issue:** #227
- **Severity:** medium
- **Domain:** strategies-session
- **Primary location:** `Foqos/Utils/StrategyManager.swift:537`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

activateSession calls timersUtil.cancelAll() and stopBreak calls timersUtil.cancelAllNotifications() (line 705); both invoke UNUserNotificationCenter.removeAllPendingNotificationRequests() (TimersUtil.swift:280-281), which deletes every pending notification app-wide — including pre-activation reminders scheduled for OTHER profiles later the same day (scheduled by PreActivationReminderScheduler.rescheduleAllReminders, which only runs on app launch/foreground, FoqosApp.swift:141/237). The redundant targeted call at line 551 (cancelAllPreActivationReminders for the started profile) shows the author assumed other profiles' reminders would survive.

## Failure scenario

Profile B is scheduled for 5:00 PM with a 5-minute pre-activation reminder (scheduled at app launch). At 9:00 AM the user starts profile A manually (or ends a break) and then doesn't reopen the app. B's 4:55 PM reminder was silently removed and never fires; B still auto-starts at 5:00 PM with no warning, defeating the opt-in reminder feature.

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, high] Every element of the claim checked out: (1) cancelAll/cancelAllNotifications invoke removeAllPendingNotificationRequests, deleting all pending notifications app-wide including other profiles' pre-activation reminders; (2) activateSession (line 537) is the single convergence point for all session starts, and stopBreak (line 705) also wipes; (3) pre-activation reminders are ordinary main-app pending notifications (UNTimeIntervalNotificationTrigger) scheduled once per foreground via PreActivationReminderScheduler — there is no background/extension path that reschedules them, so a mid-day wipe leaves profile B without its reminder while B's DeviceActivity schedule still auto-starts it; (4) the targeted per-profile cancel at line 551 right after the blanket wipe confirms the author assumed other profiles' reminders would survive. Attempted refutations (BG-task resilience path, DeviceActivityMonitor extension rescheduling, other scheduleTimerActivity callers) all failed — none restore reminders in the claimed scenario. Severity medium is appropriate: user-visible loss of an opt-in reminder feature, no blocking-behavior impact.

## Suggested fix approach

Replace removeAllPendingNotificationRequests with targeted cancellation: track/scope notification identifiers per profile or per type (session reminders, break reminders) and cancel only those, leaving other profiles' pre-activation reminders intact.

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
