# Handover: scheduleLastStoppedAt written by the monitor extension is never imported back into SwiftData and is clobbered by app-side snapshot writes

- **GitHub issue:** #243
- **Severity:** low
- **Domain:** triggers-schedules
- **Primary location:** `Foqos/Utils/PreActivationReminderScheduler.swift:58`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

The extension records schedule-window suppression in the SharedData snapshot only (StrategyTimerActivity.swift:58-63 -> SharedData.setLastStoppedAt, SharedData.swift:402-410, documented as 'called from extension processes that cannot access SwiftData'). But the app never reads that value back: catchUpMissedScheduleStarts evaluates shouldBeActiveNow with profile.scheduleLastStoppedAt from SwiftData (PreActivationReminderScheduler.swift:54) and rebuilds the snapshot from SwiftData (line 58, BlockedProfiles.getSnapshot line 534), and every BlockedProfiles.updateProfile/updateSnapshot (BlockedProfiles.swift:462, 539-542) overwrites the SharedData snapshot with the stale SwiftData value. So any suppression recorded out-of-process can be silently lost the next time the app writes a snapshot or runs foreground catch-up.

## Failure scenario

A schedule-started session (tag == profile UUID) is ended in the monitor extension by a still-registered strategy timer, which records lastStoppedAt in SharedData only. The user then opens the app mid-window: catchUpMissedScheduleStarts sees a nil/stale SwiftData scheduleLastStoppedAt, shouldBeActiveNow returns true, and the session the extension just ended is restarted (user re-blocked); any profile edit similarly erases the extension's suppression record from SharedData.

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, high] The one-way data flow is confirmed by exhaustive grep and file reads: the monitor extension records schedule suppression only in the SharedData snapshot (StrategyTimerActivity.stop -> SharedData.setLastStoppedAt), and no app-side code ever reads that field back — the sole reader of SharedData.snapshot(for:) is the extension-side TimerActivityUtil. SwiftData's scheduleLastStoppedAt is written only by in-app endSession() and CloudKit remote sync; the import path for extension-completed sessions (syncScheduleSessions -> upsertSessionFromSnapshot) sets endTime directly and never sets scheduleLastStoppedAt. Every BlockedProfiles.updateSnapshot call (updateProfile, activateSession, startSessionFromBackground) rebuilds the SharedData snapshot from the stale SwiftData value, clobbering the extension's write. catchUpMissedScheduleStarts (run on every launch/foreground, FoqosApp.swift:141-142/237-239) evaluates shouldBeActiveNow with the SwiftData value AND passes a freshly built SwiftData-based snapshot to ScheduleTimerActivity.start, so both suppression checks see nil/stale and the just-ended session is restarted (createSessionForScheduler + activateRestrictions). The only caveat is trigger reachability: the extension writer fires only when a stale StrategyTimerActivity interval ends while a schedule-started session (tag == profile UUID) for the same profile is active — an edge case requiring the strategy timer registration to have survived (normal in-app stops call removeAllStrategyTimerActivities). That matches the claim's own 'low' severity. Even in the narrowest reading, the suppression writer introduced in #96/#98 produces state the app never honors, so the state-drift defect is real as described.

## Suggested fix approach

On app launch/foreground (before catch-up and before any updateSnapshot), merge SharedData.snapshot(for:)?.scheduleLastStoppedAt into the SwiftData profile using max(swiftDataValue, sharedDataValue).

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
