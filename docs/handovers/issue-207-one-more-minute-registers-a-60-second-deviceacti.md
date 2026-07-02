# Handover: One More Minute registers a 60-second DeviceActivity interval — always below the 15-minute minimum, so the feature always aborts

- **GitHub issue:** #207
- **Severity:** high
- **Domain:** triggers-schedules
- **Primary location:** `Foqos/Utils/DeviceActivityCenterUtil.swift:308`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

startOneMoreMinuteActivity (lines 308-347) builds a DeviceActivitySchedule spanning exactly 60 seconds (now to now+60 with second precision). DeviceActivityCenter.startMonitoring throws MonitoringError.intervalTooShort for any interval under 15 minutes, regardless of second-level precision. StrategyManager.startOneMoreMinute (StrategyManager.swift:158-167) correctly schedules enforcement first and returns on error without lifting restrictions — which means the throw path makes the entire 'One More Minute' feature a silent no-op: the error is only logged, no user-facing message is set.

## Failure scenario

During any active session the user taps 'One More Minute': DeviceActivityCenter.startMonitoring throws intervalTooShort, StrategyManager logs and returns, restrictions are never lifted, and the UI gives no feedback — the feature never works on any device.

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, high] The cited code builds a DeviceActivitySchedule spanning exactly 60 seconds (intervalStart = now's h/m/s, intervalEnd = now+60s) and calls startMonitoring, which per Apple's documented DeviceActivity constraint throws MonitoringError.intervalTooShort for any schedule interval under 15 minutes. StrategyManager.startOneMoreMinute catches the throw, logs, and returns before lifting restrictions or setting any user-facing error, and HomeView.swift:220 is the sole entry point — so the feature is a silent no-op on every invocation. Attempts to refute failed: there is no minimum-interval guard, padding, or fallback path anywhere in the repo. Corroborating history confirms the regression: the PR #56 design originally used intervalStart 00:00:00 (interval >15 min for most of the day, passing validation) — the stale comment at OneMoreMinuteTimerActivity.swift:23 still says 'intervalDidStart fires immediately (since intervalStart is 00:00:00)' — but an AI review suggestion recorded in commit 7d0ce50 ('Replace midnight cap with actual start time in DeviceActivity schedule... (sourcery-ai #2, copilot #5)') changed intervalStart to the actual current time, shrinking the interval to 60 seconds. Unlike break/strategy timers whose durations can reach 15+ minutes, this interval can never satisfy the minimum. The only untestable element (no physical device available) is the framework throw itself, but the 15-minute minimum is a well-documented, widely confirmed DeviceActivity limitation.

> [real=true, high] Reproduced the full chain in code: tap in HomeView -> StrategyManager.startOneMoreMinute -> DeviceActivityCenterUtil.startOneMoreMinuteActivity builds a now->now+60s (60-second) non-repeating DeviceActivitySchedule and calls startMonitoring. Apple's DeviceActivity framework enforces a 15-minute minimum interval at registration (MonitoringError.intervalTooShort), so this throw happens on every invocation regardless of second-level precision — there is no code path producing a longer interval. The catch in StrategyManager only logs and returns: restrictions are never deactivated, session state is never updated, and no user-facing error is surfaced, making the feature a permanent silent no-op. No fallback enforcement or alternate unlock path exists (the re-block in OneMoreMinuteTimerActivity.stop only runs from the never-fired intervalDidEnd). The only premise not verifiable from repo code alone is the framework's 15-minute minimum, which is documented Apple behavior since iOS 15; the code-side chain is fully confirmed.

## Suggested fix approach

Enforce the 60-second window without DeviceActivity (e.g., re-activate restrictions from the main app via a timer plus a BGTask/shield fallback), or lift restrictions immediately and use the existing oneMoreMinuteStartTime wall-clock check for re-blocking; surface an error to the user if enforcement cannot be scheduled.

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
