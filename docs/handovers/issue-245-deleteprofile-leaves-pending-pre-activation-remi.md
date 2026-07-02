# Handover: deleteProfile leaves pending pre-activation reminder notifications and the stop-only DeviceActivity registered

- **GitHub issue:** #245
- **Severity:** low
- **Domain:** views-primary
- **Primary location:** `Foqos/Models/BlockedProfiles.swift:489`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

BlockedProfiles.deleteProfile (lines 469-494, invoked from BlockedProfileView.swift:798 and BlockedProfileListView.swift:160) ends sessions, deletes the snapshot, and calls DeviceActivityCenterUtil.removeScheduleTimerActivities(for:) — but it never calls TimersUtil.cancelAllPreActivationReminders(for:) (reminders are only cancelled when re-scheduling, DeviceActivityCenterUtil.swift:9, or on session activation) and never calls removeStopScheduleActivity(for:), so a stop-only StopScheduleTimerActivity registration survives the delete as a ghost schedule.

## Failure scenario

User has a profile scheduled to start at 16:00 with a '15 minutes before' reminder, then deletes the profile at noon. At 15:45 the device still shows the 'profile starts in 15 minutes' notification for the now-deleted profile; a profile with a stop-only schedule additionally leaves a daily DeviceActivity registered that fires into a missing snapshot forever (until cleanUpGhostSchedules happens to run).

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, high] Attempted refutation failed on every avenue. (1) The delete path (BlockedProfiles.deleteProfile and all three call sites: BlockedProfileView.swift:798, BlockedProfileListView.swift:160, SyncCoordinator.swift:195) performs no reminder-notification cancellation and no stop-only activity removal. (2) Pre-activation reminders are plain UNUserNotificationCenter time-interval notifications scheduled earlier the same day; the only cancellation hooks are re-scheduling (requires the profile to still exist in the DB), session activation, and ScheduleTimerActivity.start in the DeviceActivity extension — the last fires at interval start, after the reminder time, and deleteProfile already stopped that activity anyway. So a reminder for a deleted profile fires. (3) The stop-only DeviceActivity uses a prefixed name ("StopScheduleTimerActivity:<uuid>") that removeScheduleTimerActivities (unprefixed UUID name) does not stop, and cleanUpGhostSchedules explicitly filters out prefixed names, so the claim's caveat "until cleanUpGhostSchedules happens to run" is actually too generous — that cleanup never removes stop-only ghosts; only the manual DebugView tooling can. Severity low is fair: consequences are a stray notification and a leaked DeviceActivity registration slot firing into a missing snapshot (extension no-ops on missing snapshot).

## Suggested fix approach

In deleteProfile, add TimersUtil.cancelAllPreActivationReminders(for: profile.id) and DeviceActivityCenterUtil.removeStopScheduleActivity(for: profile).

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
