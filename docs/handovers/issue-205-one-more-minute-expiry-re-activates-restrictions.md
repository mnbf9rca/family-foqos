# Handover: One-more-minute expiry re-activates restrictions in the middle of an active break

- **GitHub issue:** #205
- **Severity:** high
- **Domain:** strategies-session
- **Primary location:** `Packages/FoqosShared/Sources/FoqosShared/Timers/OneMoreMinuteTimerActivity.swift:50`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

OneMoreMinuteTimerActivity.stop() re-applies restrictions whenever oneMoreMinuteStartTime != nil, without checking whether a break is currently active (breakStartTime set, breakEndTime nil). Starting a break is allowed while one-more-minute is running (isBreakAvailable only checks enableBreaks && breakEndTime == nil, HomeView.swift:204 toggleBreak), and startBreak/startOneMoreMinute never clear each other's state, so the 60-second OMM expiry fires during the break and blocks apps that the break is supposed to unblock.

## Failure scenario

Session active on a breaks-enabled profile. User taps 'One more minute' at T (restrictions lifted, OMM DeviceActivity scheduled for T+60s), then at T+30s starts a 15-minute break (restrictions stay lifted, break runs to T+15m30s). At T+60s the OMM intervalDidEnd fires, sees oneMoreMinuteStartTime set, and calls activateRestrictions — the user is re-blocked 14+ minutes into what should be an unblocked break, until the break timer's own intervalDidEnd.

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, high] Verified every link in the claimed chain against source. (1) UI and model allow starting a break while one-more-minute is running: break button gating (ProfileTimerButton.swift:82) uses isBreakAvailable, which checks only enableBreaks && breakEndTime == nil — no OMM condition. (2) StrategyManager.startBreak neither removes the scheduled OMM DeviceActivity nor clears oneMoreMinuteStartTime; SharedData.setBreakStartTime leaves it intact. (3) When the OMM interval ends 60s after OMM started, OneMoreMinuteTimerActivity.stop() re-applies restrictions based solely on oneMoreMinuteStartTime != nil, with no check for an active break — unlike BreakTimerActivity.stop(), which does guard on break state. Result: a user who taps OMM and then starts a break within the 60s window gets re-blocked mid-break at OMM expiry and stays blocked for the rest of the break (BreakTimerActivity.stop at break end also re-activates restrictions). The defect is real; the fix sketch (skip activateRestrictions when a break is active, or remove the OMM activity on break start) matches the code structure.

> [real=true, high] Traced the claimed scenario step by step. (1) startOneMoreMinute (StrategyManager.swift:147-176) schedules a 60s DeviceActivity and lifts restrictions, leaving oneMoreMinuteStartTime set in SharedData. (2) While OMM is active, the break button remains available: ProfileTimerButton.swift:82 gates only on isBreakAvailable, which is enableBreaks && breakEndTime == nil (BlockedProfileSessions.swift:26-29) — no OMM check; StrategyManager.startBreak (663-688) does not remove the OMM DeviceActivity nor clear oneMoreMinuteStartTime (removeOneMoreMinuteActivity is called only at session end, line 597, and in stopBlocking, line 987). (3) BreakTimerActivity.start deactivates restrictions and sets breakStartTime via SharedData.setBreakStartTime (SharedData.swift:429-433), which does not touch OMM state. (4) At T+60s the OMM intervalDidEnd fires in the DeviceActivityMonitor extension, routes through TimerActivityUtil.stopTimerActivity to OneMoreMinuteTimerActivity.stop, whose only guard (line 50) is oneMoreMinuteStartTime != nil — still true — so line 52 calls appBlocker.activateRestrictions(for: profile), re-blocking apps in the middle of the active break until the break's own intervalDidEnd. Every link in the claimed chain is present in the code; the defect is real.

## Suggested fix approach

In OneMoreMinuteTimerActivity.stop(), skip activateRestrictions when activeSession.breakStartTime != nil && activeSession.breakEndTime == nil (still clear oneMoreMinuteStartTime). Alternatively, remove the OMM activity when a break starts.

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
