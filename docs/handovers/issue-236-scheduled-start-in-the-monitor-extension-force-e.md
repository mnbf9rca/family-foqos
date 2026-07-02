# Handover: Scheduled start in the monitor extension force-ends any other active session, ignoring disableBackgroundStops and stop conditions

- **GitHub issue:** #236
- **Severity:** medium
- **Domain:** widgets-extensions
- **Primary location:** `Packages/FoqosShared/Sources/FoqosShared/Timers/ScheduleTimerActivity.swift:80`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

ScheduleTimerActivity.start, when an active shared session belongs to a different profile, calls SharedData.endActiveSharedSession() and replaces its restrictions with the scheduled profile's. Unlike all app-side stop paths, it performs no disableBackgroundStops, geofence, or stop-condition check on the session being terminated. Combined with a scheduled profile whose window ends shortly after it starts (or one with an empty app selection), this silently terminates a strict/NFC-locked session in the background.

## Failure scenario

Session for strict profile A is active (disableBackgroundStops = true, NFC-only stop). Profile B has a start schedule at 21:00 with a 21:15 stop. At 21:00 the monitor extension ends A's session and activates B; at 21:15 B stops and all restrictions clear -> A's protections were bypassed without ever satisfying A's stop conditions, and the user can create such a profile B while A is running.

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, high] The defect is confirmed by direct code reading of the full path. (1) Manual/strict sessions ARE visible to the extension: every session start mirrors to the shared store — BlockedProfileSessions.swift:138 `SharedData.createActiveSharedSession(for: newSession.toSnapshot())`. (2) ScheduleTimerActivity.start (invoked from the DeviceActivityMonitor extension via TimerActivityUtil) at lines 74-85 force-ends a different profile's active session with no disableBackgroundStops / stop-condition / geofence check, then activates the scheduled profile's restrictions. Every app-side stop path checks these (StrategyManager.swift:234 and :429 guard on disableBackgroundStops; deep-link path also runs StartStopActionResolver.canStop and geofence evaluation), so the extension path is a genuine bypass, not an intended exception. (3) The bypass is permanent, not transient: SharedData.endActiveSharedSession (SharedData.swift:389-398) stamps the strict session's snapshot with endTime and queues it as completed; StrategyManager.syncScheduleSessions (lines 784-789) later upserts it, setting endTime on the local SwiftData session (BlockedProfileSessions.swift:160). (4) When the scheduled profile's window ends, ScheduleTimerActivity.stop (lines 105-109) calls appBlocker.deactivateRestrictions(), clearing all restrictions — the strict profile's protections are removed without satisfying its stop conditions. (5) No guard exists in DeviceActivityCenterUtil.scheduleTimerActivity preventing schedule registration while a strict session is active, so the claimed failure scenario (user creates schedule-B while strict-A runs) is achievable. Severity medium is reasonable: it requires deliberately creating a scheduled profile, but it fully defeats disableBackgroundStops/NFC-lock semantics in the background.

## Suggested fix approach

In ScheduleTimerActivity.start, skip (or defer) the takeover when the existing session's profile snapshot has disableBackgroundStops == true or non-manual stop conditions; log and keep the existing session instead.

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
