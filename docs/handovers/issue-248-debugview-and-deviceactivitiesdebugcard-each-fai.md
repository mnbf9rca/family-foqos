# Handover: DebugView and DeviceActivitiesDebugCard each fail to recognize one real activity type, reporting 'Unknown' / 'Matches Profile: No' for live activities

- **GitHub issue:** #248
- **Severity:** low
- **Domain:** views-secondary
- **Primary location:** `Foqos/Views/DebugView.swift:281`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

DebugView.activityType/isActivityForProfile (DebugView.swift:281-320) check BreakTimerActivity, StopScheduleTimerActivity and ScheduleTimerActivity prefixes but omit StrategyTimerActivity ('StrategyTimerActivity:<uuid>', FoqosShared/Timers/StrategyTimerActivity.swift:5), so the copied Markdown for an active NFC/QR Timer session lists its own stop-timer activity as 'Unknown' with 'Matches Profile: No'. Conversely, DeviceActivitiesDebugCard (Foqos/Components/Debug/DeviceActivitiesDebugCard.swift:44-80) handles StrategyTimerActivity but omits StopScheduleTimerActivity, so the on-screen list misclassifies stop-schedule activities the same way. The two views also disagree with each other for the same data.

## Failure scenario

User runs an 'NFC + Timer' session and uses Debug Mode -> Copy as Markdown to report a bug: the export claims the profile's strategy timer activity is 'Unknown' and does not match the profile, while the on-screen card says 'Strategy Timer / Matches: Yes' — misleading diagnostics that send bug triage down the wrong path (e.g., concluding the stop timer was never scheduled).

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, high] Attempted refutation failed on every axis. (1) DebugView's activityType/isActivityForProfile genuinely omit the "StrategyTimerActivity" prefix; a name "StrategyTimerActivity:<uuid>" matches none of the three checked prefixes ("Strategy" != "Schedule") and is not a bare UUID, so the Markdown export reports "Unknown" and "Matches Profile: No" for a real, live activity — strategy timer activities are scheduled by the NFC/QR/Shortcut timer strategies which are registered and reachable via StartStopActionResolver. (2) DeviceActivitiesDebugCard symmetrically omits "StopScheduleTimerActivity" (its prefix does not match "ScheduleTimerActivity" since the string starts with "StopS"), so the on-screen card shows "Unknown"/false for stop-schedule activities that DeviceActivityCenterUtil genuinely schedules. (3) Both views render the identical DeviceActivityCenterUtil.getDeviceActivities() list, so they visibly contradict each other for the same data, exactly as the failure scenario describes. No guard elsewhere prevents this; the only error in the claim is a stale file path for StrategyTimerActivity.swift (actual: Packages/FoqosShared/Sources/FoqosShared/Timers/), which is immaterial. Impact is limited to debug diagnostics (misleading bug reports), so the "low" severity is correct.

## Suggested fix approach

Extract a single shared classifier (e.g., in TimerActivityUtil) covering BreakTimer, StopScheduleTimer, ScheduleTimer and StrategyTimer prefixes (checking StopScheduleTimer before ScheduleTimer) and use it from both DebugView.copyToMarkdown and DeviceActivitiesDebugCard.

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
