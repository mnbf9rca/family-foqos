# Handover: Session mutators write to SharedData's active session without identity checks, clobbering extension-created sessions

- **GitHub issue:** #237
- **Severity:** medium
- **Domain:** widgets-extensions
- **Primary location:** `Foqos/Models/BlockedProfileSessions.swift:80`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

BlockedProfileSession.endSession() unconditionally calls SharedData.setEndTime and SharedData.flushActiveSession(); startBreak/startOneMoreMinute similarly mutate SharedData.activeSharedSession without verifying it belongs to this session (SharedData.swift:429-462 mutators take no session id). If the monitor extension has meanwhile replaced the shared session with a different profile's scheduled session (StrategyManager's in-memory activeSession is only refreshed by loadActiveSession, not on every foreground), stopping the stale in-app session wipes the extension's session: flushActiveSession() discards it without appending to completedSessionsInScheduler, so its endTime never reaches SwiftData.

## Failure scenario

Manual session A is on screen; while backgrounded, the extension ends A and starts scheduled session B (already imported to SwiftData by an earlier refresh). User returns and taps Stop on the still-displayed A -> endSession() sets endTime on B's shared snapshot then flushes it and clears B's restrictions -> B's SwiftData row keeps endTime == nil, so on next launch the app shows B as an active blocking session that is enforcing nothing, requiring a second manual stop; B's real end never syncs.

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, medium] The core defect is real: SharedData's session mutators and flushActiveSession take no session identity, endSession() calls them unconditionally, and the monitor extension can replace activeSharedSession with a different profile's session (ScheduleTimerActivity ends the old one and calls createSessionForScheduler). flushActiveSession discards the snapshot without appending to completedSessionsInScheduler, so a clobbered extension session's lifecycle never reaches SwiftData. HOWEVER, the claim's specific failure scenario is refuted in two details: (1) its premise that activeSession is not refreshed on foreground is false — HomeView.onChange(scenePhase == .active) calls loadApp() → loadActiveSession() on every foreground; (2) its premise that B was 'already imported to SwiftData by an earlier refresh' while stale A is still displayed is self-contradictory, because the only importer (syncScheduleSessions) runs inside loadActiveSession, which simultaneously reassigns activeSession to B (A receives its endTime from the completed-sessions flush, so mostRecentActiveSession returns B). Therefore the claimed 'B zombie row with endTime == nil requiring a second stop' cannot occur via the described background-return path. The defect IS reachable via a narrower variant: the schedule interval fires while the app is foregrounded (no scenePhase change and no cross-process notification exists; the 1s timer never reloads the session), the user taps Stop on stale A → B's shared snapshot is stamped and flushed without completion (B lost entirely, never imported) and deactivateRestrictions() tears down the extension's block. deleteProfile's endSession loop shares the same identity-less clobber path. Net: real medium-severity defect with a confirmed mechanism, but the written failure scenario is inaccurate — actual consequence is silent loss of the extension session and premature restriction teardown, not a zombie active row.

## Suggested fix approach

Pass the session id into SharedData mutators (setEndTime(for sessionId:), flushActiveSession(matching:)) and no-op with a log when the stored active session id differs; have stop paths re-run loadActiveSession before acting.

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
