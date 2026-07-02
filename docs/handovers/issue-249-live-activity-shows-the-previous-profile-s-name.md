# Handover: Live Activity shows the previous profile's name after a session switch because attributes are never recreated

- **GitHub issue:** #249
- **Severity:** low
- **Domain:** widgets-extensions
- **Primary location:** `Foqos/Utils/LiveActivityManager.swift:70`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

startSessionActivity, when currentActivity is non-nil, calls updateSessionActivity(session:) instead of ending and re-requesting. ActivityKit attributes (profile name, message) are immutable; only ContentState is updated. When the active session's profile changes without the app process observing an explicit stop (e.g., the monitor extension replaced session A with scheduled session B while backgrounded, then loadActiveSession runs on foreground and calls startSessionActivity(B)), the lock-screen Live Activity keeps profile A's name with B's timer. It also keeps updating an activity for a profile with enableLiveActivity == false in the same scenario.

## Failure scenario

Manual session for 'Work' is active with a Live Activity; while the app is backgrounded, a scheduled 'Bedtime' profile takes over via the extension; user unlocks the phone and opens the app -> the lock screen and Dynamic Island continue to display 'Work' with Bedtime's elapsed timer until the session fully ends.

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, high] All three elements of the claim verify against the code. (1) startSessionActivity's currentActivity != nil branch (line 70) delegates to updateSessionActivity, which only pushes a new ContentState; the profile name and message live in FoqosWidgetAttributes, which ActivityKit makes immutable after Activity.request, so a stale name persists. (2) The cross-profile session switch without the app observing a stop is a real path: the DeviceActivityMonitor extension (ScheduleTimerActivity.start) ends a different profile's shared session and creates a new one while the app is backgrounded; the extension has no ActivityKit access, so the old Live Activity survives. On foreground, StrategyManager.loadActiveSession picks up the new session via syncScheduleSessions/mostRecentActiveSession and calls startSessionActivity with the new session — no code compares the existing activity's profile/session to the incoming one, and currentActivity is still set (or restored from storedActivityId), so only the timer updates while the name stays the old profile's. (3) The enableLiveActivity check at line 76 sits after the update early-return, so the stale activity keeps updating even if the new profile disabled Live Activities. I could find no guard elsewhere (endSessionActivity callers, stop paths) that handles the profile-changed case. Severity is correctly low: user-visible cosmetic inconsistency that self-heals when the session ends.

## Suggested fix approach

In startSessionActivity, compare the restored/current activity's attributes.name (or store the session/profile id alongside the activity id) and end + re-request the activity when the session's profile differs.

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
