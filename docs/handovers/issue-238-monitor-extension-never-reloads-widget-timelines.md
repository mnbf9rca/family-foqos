# Handover: Monitor extension never reloads widget timelines, so the home-screen widget shows stale session state after scheduled starts/stops

- **GitHub issue:** #238
- **Severity:** medium
- **Domain:** widgets-extensions
- **Primary location:** `FoqosDeviceMonitor/DeviceActivityMonitorExtension.swift:34`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

WidgetCenter.shared.reloadTimelines(ofKind: "ProfileControlWidget") is called only from the main app (StrategyManager, EmergencyUnblockManager). When the FoqosDeviceMonitor extension starts or stops a session (ScheduleTimerActivity/StrategyTimerActivity/StopScheduleTimerActivity/BreakTimerActivity), no widget reload is requested. ProfileControlProvider's timeline for the inactive state contains a single entry with policy .atEnd, so after a scheduled session starts in the background, WidgetKit may not re-query for a long time; conversely, an active timeline has 60 minutes of pre-built 'active' entries that keep displaying a running timer after the extension ended the session.

## Failure scenario

Profile has a 09:00-17:00 schedule; app not opened. At 09:00 the extension activates restrictions, but the widget still shows the inactive 'Tap to open' state (and its tap deep-links into the profile toggle URL); at 17:00 the session ends but the widget continues showing a green active timer for up to an hour until its pre-built entries run out.

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, high] Confirmed by exhaustive grep: WidgetCenter.shared.reloadTimelines(ofKind: "ProfileControlWidget") appears only in main-app code (StrategyManager.swift:173,554,591,681,708; EmergencyUnblockManager.swift:226). The FoqosDeviceMonitor extension and the FoqosShared package (TimerActivityUtil + all TimerActivity implementations) contain zero WidgetKit references. intervalDidStart/intervalDidEnd mutate SharedData session state and ManagedSettings restrictions but never trigger a widget reload. The widget provider only re-reads SharedData when WidgetKit re-requests a timeline: the inactive timeline is a single entry with .atEnd (refresh at WidgetKit's discretionary budget, not aligned to the schedule start), and the active timeline pre-builds 60 minutes of static entries embedding a snapshot of activeSession, so after the extension ends a session the widget can display the active state for up to ~an hour. The failure scenario (app not opened; 09:00 scheduled start shows stale inactive widget; 17:00 stop shows stale active timer) follows directly from the code. The fix (calling WidgetCenter from the extension/shared util) is viable since WidgetCenter is available in app extensions. Severity medium (stale UI, no restriction enforcement impact) is appropriate.

## Suggested fix approach

Import WidgetKit in FoqosShared/the monitor extension and call WidgetCenter.shared.reloadTimelines(ofKind: "ProfileControlWidget") at the end of TimerActivityUtil.startTimerActivity/stopTimerActivity.

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
