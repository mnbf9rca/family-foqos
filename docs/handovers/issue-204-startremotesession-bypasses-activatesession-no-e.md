# Handover: startRemoteSession bypasses activateSession: no elapsed timer, no Live Activity, no stop-schedule registration, no widget reload

- **GitHub issue:** #204
- **Severity:** high
- **Domain:** strategies-session
- **Primary location:** `Foqos/Utils/StrategyManager.swift:1099`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

startRemoteSession (called from SyncCoordinator.applySessionState when another same-user device starts a session) activates restrictions and creates a session, then sets self.activeSession directly (line 1137). Unlike every other start path, which converges on activateSession() (line 532), it never calls startTimer(), liveActivityManager.startSessionActivity(), DeviceActivityCenterUtil.scheduleStopActivity(for:), WidgetCenter.reloadTimelines, or HeartbeatManager.writeHeartbeat. It also never saves the context.

## Failure scenario

User has two devices; device A starts a profile that has a scheduled-stop condition (stop at 22:00). Device B receives the sync while the app is foregrounded: restrictions activate but the home-screen elapsed timer stays frozen at its previous value, no Live Activity appears, and the widget still shows 'inactive'. Worse, because scheduleStopActivity is never registered on device B, the local DeviceActivity that enforces the 22:00 stop never exists — if the app is backgrounded at 22:00 and the CloudKit stop push is delayed or dropped, device B's restrictions stay on past the scheduled stop with no local enforcement.

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, high] Confirmed by direct code reading. startRemoteSession (StrategyManager.swift:1099-1145) hand-rolls a subset of session activation: it activates restrictions, creates the session, and assigns self.activeSession (line 1137), but omits startTimer(), liveActivityManager.startSessionActivity(), DeviceActivityCenterUtil.scheduleStopActivity(), WidgetCenter.reloadTimelines, HeartbeatManager.writeHeartbeat, and context.save() — all of which activateSession (lines 532-568, explicitly documented as the single source of truth all start paths converge on) performs. Refutation attempts failed: (1) the caller SyncCoordinator.applySessionState (SyncCoordinator.swift:384-396) adds no compensating side effects; (2) loadActiveSession would repair the state (it starts timer, live activity, and re-registers the stop schedule at lines 93-103) but is only called from HomeView lifecycle events (onAppear, scenePhase→active, pull-to-refresh), which do not fire after a CloudKit push arrives while the app is foregrounded or via background fetch (FoqosApp.swift:339-358), so the broken state persists until the next background→foreground transition; (3) the stop-schedule gap is real — scheduleStopActivity is the only local DeviceActivity enforcement of a scheduled stop, so a device that received the remote start and is then backgrounded has no local enforcement and depends entirely on a timely CloudKit stop push, matching the claimed failure scenario. Minor softening only: createSession writes the shared widget snapshot (BlockedProfileSessions.swift:138) so widget data is present (just not reloaded), and SwiftData main-context autosave likely covers the missing explicit save. The core defect (frozen elapsed timer, missing Live Activity, missing stop-schedule registration, missing widget reload on the remote-start path) is real and the proposed fix (call activateSession; sync echo suppressed via processingRemoteChange/shouldSyncSessionChange at lines 52-53 and 489) is consistent with the code.

> [real=true, high] Reproduced the full chain in code: CloudKit push (FoqosApp.swift:341) → ProfileSyncManager.performFullSync → pullProfileSessionRecords (ProfileSyncManager.swift:349) → SyncCoordinator.handleProfileSessionRecords (SyncCoordinator.swift:324) → applySessionState → startRemoteSession (SyncCoordinator.swift:389; StrategyManager conforms to SessionController at StrategyManager.swift:1171). startRemoteSession (StrategyManager.swift:1099-1145) activates restrictions and sets activeSession directly, skipping activateSession() — the documented single source of truth — so no elapsed timer restart (the timer loop has already broken via the guard at line 184 when no session was active), no Live Activity, no local stop-schedule DeviceActivity registration, no widget reload, no heartbeat, no context.save. No compensating mechanism fires while the app is foregrounded: loadActiveSession (which would fix timer/Live Activity/stop schedule at lines 93-103) runs only on scenePhase .active, pull-to-refresh, or profiles onChange; backgrounding only stops the timer. Therefore the claimed scenario holds: on device B the UI timer stays stale, no Live Activity appears, the widget is not reloaded, and — most seriously — the StopScheduleTimerActivity that locally enforces a scheduled stop (DeviceActivityCenterUtil.swift:101-120) is never registered, so if the app is backgrounded at the stop time and the CloudKit stop push is delayed/dropped, restrictions persist past the schedule with no local enforcement until the app is next foregrounded. The fix sketch is also consistent: activateSession is private but startRemoteSession is in the same class, and echo suppression via processingRemoteChange exists (lines 1105-1108). Minor caveat: the missing context.save may be partially mitigated by SwiftData mainContext autosave, but the primary defects stand regardless.

## Suggested fix approach

Have startRemoteSession call activateSession(session, context: context) (sync echo is already suppressed by processingRemoteChange via shouldSyncSessionChange) instead of hand-rolling a subset of its side effects.

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
