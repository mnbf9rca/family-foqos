# Handover: Emergency unblock schedules the post-session reminder twice, producing duplicate notifications

- **GitHub issue:** #242
- **Severity:** low
- **Domain:** strategies-session
- **Primary location:** `Foqos/Utils/StrategyManager.swift:482`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

emergencyUnblock's onUnblock closure calls manualStrategy.stopBlocking (which fires the .ended callback in getStrategy — that callback already calls self.scheduleReminder(profile:) at line 585) and then calls self.scheduleReminder(profile: sess.blockedProfile) again at line 482. Both notifications get random UUID identifiers, so neither replaces the other; the .ended callback's timersUtil.cancelAll() runs before either is scheduled, so both survive.

## Failure scenario

Profile with a reminder time set (e.g., 30 minutes) is emergency-unblocked. Thirty minutes later the user receives two identical '<Profile> time!' notifications.

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, high] The emergencyUnblock onUnblock closure calls manualStrategy.stopBlocking, and ManualBlockingStrategy.stopBlocking synchronously fires onSessionCreation?(.ended(...)) (ManualBlockingStrategy.swift:58). getStrategy (StrategyManager.swift:570) unconditionally wires that callback, whose .ended branch calls timersUtil.cancelAll() (line 581) then scheduleReminder (line 585). Control then returns to the closure which calls scheduleReminder again (line 482). Both calls happen after cancelAll, and scheduleReminder→TimersUtil.scheduleNotification generates a fresh UUID identifier per call (TimersUtil.swift:220) with no dedup, so two identical pending notifications survive. EmergencyUnblockManager invokes the closure exactly once on success (EmergencyUnblockManager.swift:219). Result: any profile with reminderTimeInSeconds set that is emergency-unblocked gets two identical '<Profile> time!' notifications. Could not refute: callback is synchronous, always wired, nothing cancels between the two schedules.

## Suggested fix approach

Remove the scheduleReminder/endSessionActivity/stopTimer calls from the emergencyUnblock closure — the .ended callback wired by getStrategy already performs all of them.

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
