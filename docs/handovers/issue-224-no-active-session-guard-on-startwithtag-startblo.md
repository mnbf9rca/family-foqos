# Handover: No active-session guard on startWithTag/startBlocking allows double-start: zombie active session or silently lost scheduled session

- **GitHub issue:** #224
- **Severity:** medium
- **Domain:** strategies-session
- **Primary location:** `Foqos/Utils/StrategyManager.swift:942`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

startWithTag (and startBlocking via the async geofence callback in toggleBlocking, line 127-131) creates a session with no check that one is already active. BlockedProfileSession.createSession also unconditionally overwrites SharedData.activeSharedSession (BlockedProfileSessions.swift:138), discarding any scheduler-created snapshot without moving it to completed. mostRecentActiveSession only returns one row, so a second active row becomes a zombie whose endTime is never set.

## Failure scenario

Case A: user taps Start on a geofence-gated profile twice quickly; both async checkGeofenceAndStart callbacks see no active session and each creates a session. Stopping ends only the newer one; on next launch mostRecentActiveSession returns the zombie, so the app shows 'blocking' with restrictions actually off and the user must stop a phantom session. Case B: user opens the NFC start scan at 8:59:55; at 9:00 a scheduled session starts in the extension (shared snapshot + restrictions); the scan completes at 9:00:05 and startWithTag overwrites the scheduler snapshot — the scheduled session is never persisted to SwiftData (lost from history/stats).

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, high] Verified all links in the claimed chain. (1) startWithTag (StrategyManager.swift:942) and startBlocking (819) create sessions with no active-session guard; the intent paths (startSessionFromBackground:346, toggleSessionFromDeeplink:231) DO guard via getActiveSession, proving the guard is the intended pattern and its absence here is an oversight. (2) The only UI gate, HomeView.swift:475 `strategyManager.isBlocking`, is a synchronous in-memory check; for geofence-gated profiles checkGeofenceAndStart defers onStart into an awaited Task (GeofenceEvaluator.swift:173) with no re-entrancy guard, and isCheckingGeofence is not bound to any UI, so a second tap during the ~1s location check creates a second session (Case A). Each stop ends only the newer session (stopBlocking uses activeSession), leaving the first row with endTime==nil; mostRecentActiveSession (fetchLimit=1, endTime==nil) then resurrects the zombie on next launch — app shows blocking while restrictions are off. (3) createSession unconditionally overwrites SharedData.activeSharedSession (BlockedProfileSessions.swift:138 → SharedData.swift:381); a scheduler snapshot written by the extension between opening a scan sheet and scan completion is discarded without being upserted to SwiftData or moved to completedSessionsInScheduler, losing the scheduled session from history (Case B) — syncScheduleSessions runs only inside getActiveSession, which startWithTag never calls. No spinner, strategy-level guard, or dedupe exists anywhere to prevent either case. Severity medium is fair: requires a timing window, but consequences (phantom blocking state, lost session records) are user-visible.

## Suggested fix approach

In startWithTag and startBlocking, guard against getActiveSession(context:) returning non-nil (which also syncs scheduler snapshots first) and surface an errorMessage instead of creating a second session.

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
