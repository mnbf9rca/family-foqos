# Handover: Scheduled-session CAS reconciliation overwrites startTime of whichever session is active, without verifying profile identity

- **GitHub issue:** #226
- **Severity:** medium
- **Domain:** strategies-session
- **Primary location:** `Foqos/Utils/StrategyManager.swift:761`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

In syncScheduleSessions, the .alreadyActive branch reconciles startTime with only `let currentSession = self.activeSession, currentSession.startTime != remoteStartTime` — no check that currentSession belongs to activeScheduledSession.blockedProfileId. The equivalent non-scheduled path in syncSessionStart was hardened with an identity check (`currentSession.id == session.id`, lines 510-512) for exactly this reason, but the scheduled path was not.

## Failure scenario

Profile A's scheduled session is active at launch; loadActiveSession queues the CAS startSession task for A (network takes several seconds). Before it completes, the user stops A and manually starts profile B; the CAS result returns .alreadyActive with A's remote startTime (e.g., 9:00 AM), and the closure overwrites B's session.startTime with it and saves. B's session now shows hours of elapsed time, and its recorded duration/stats are permanently corrupted.

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, high] The scheduled-session .alreadyActive reconciliation (StrategyManager.swift:761-765) checks only that some activeSession exists and its startTime differs from the remote value; it never verifies the session belongs to activeScheduledSession.blockedProfileId. The parallel non-scheduled path (syncSessionStart, lines 508-512) was explicitly hardened with `currentSession.id == session.id` and a comment 'Verify session identity — activeSession may have changed during async call', proving the race is acknowledged. The scheduled task runs after two awaits (previous task + network CAS call), during which activeSession is mutated synchronously by user actions (activateSession line 543 sets it; stop path line 583 nils it). Task chaining orders network calls so the scheduled-A start resolves with A's remote startTime while activeSession locally already points at newly started profile B; the startTime-mismatch guard then passes and B's session.startTime is overwritten with A's earlier start and saved, corrupting B's duration/stats. The path is reachable at launch via loadActiveSession → getActiveSession (line 726) whenever profileSyncManager.isEnabled. No guard elsewhere prevents this.

## Suggested fix approach

Mirror syncSessionStart: also require currentSession.blockedProfile.id == activeScheduledSession.blockedProfileId (or capture the upserted session's id) before reconciling startTime.

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
