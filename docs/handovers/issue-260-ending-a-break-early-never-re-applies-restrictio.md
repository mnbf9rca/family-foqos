# Handover: Ending a break early never re-applies restrictions in-process; session left unblocked in permanent 'break' state

- **GitHub issue:** #260
- **Severity:** critical
- **Domain:** strategies-session
- **Primary location:** `Foqos/Utils/StrategyManager.swift:702`
- **Status:** DISPUTED (verifiers split — investigate before implementing)
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

stopBreak() only calls DeviceActivityCenterUtil.removeBreakTimerActivity (which calls DeviceActivityCenter.stopMonitoring) and then reloads the session, with the comment 'break end time was set in a different thread'. The ONLY code that re-activates ManagedSettings restrictions and sets breakEndTime after a break is BreakTimerActivity.stop() in the monitor extension (Packages/FoqosShared/Sources/FoqosShared/Timers/BreakTimerActivity.swift:66-73), which runs from intervalDidEnd. Apple's DeviceActivity does not reliably invoke intervalDidEnd when monitoring is stopped programmatically — callbacks fire at schedule boundaries. The codebase is internally inconsistent about this contract: loadActiveSession (line 102) and activateSession (line 548) re-register the stop-schedule activity via scheduleStopActivity, which calls stopActivities on the live registration mid-interval — if stopMonitoring DID fire intervalDidEnd, StopScheduleTimerActivity.stop would deactivate restrictions and end the active session on every app launch. Both assumptions cannot hold; one flow is broken. In the likely case (no callback on stopMonitoring), ending a break early leaves restrictions permanently lifted, breakEndTime never set (isBreakActive stays true), and the auto-reblock DeviceActivity has just been deleted, so nothing ever re-applies restrictions for the rest of the 'active' session.

## Failure scenario

Child-mode user with a profile that allows breaks starts a session, taps the break toggle (restrictions lift via extension), then immediately taps it again to 'end' the break: removeBreakTimerActivity deletes the DeviceActivity that would have re-blocked at break end, no in-process code re-activates restrictions, and breakEndTime is never written. Apps stay fully unblocked indefinitely while the app shows an active focus session stuck in break state — an unlimited blocking bypass via two taps.

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, high] Attempted to refute and failed. stopBreak() performs no in-process re-blocking: it only stops the DeviceActivity monitor, cancels notifications, and reloads state. The sole code path that re-activates ManagedSettings restrictions and writes breakEndTime is BreakTimerActivity.stop(), reachable only via intervalDidEnd in the monitor extension. DeviceActivityCenter.stopMonitoring does not fire intervalDidEnd (Apple framework behavior), and the repo's own as-built doc explicitly states removeBreakTimerActivity 'prevent[s] the extension from firing intervalDidEnd' — immediately followed by a self-contradictory note claiming restrictions are re-applied by that same stop, documenting the design confusion. The claim's internal-inconsistency argument also checks out: loadActiveSession re-registers the stop-only activity via stopActivities+startMonitoring on every launch mid-interval; if stopMonitoring fired intervalDidEnd, StopScheduleTimerActivity.stop() would deactivate restrictions and end the active session on every app open — so the codebase elsewhere depends on stopMonitoring being silent. Net effect: ending a break early deletes the auto-reblock activity, never sets breakEndTime (isBreakActive stays true), and never re-applies restrictions; apps stay unblocked for the rest of the 'active' session. No compensating guard exists (only caller is HomeView→toggleBreak; foreground sync just copies the unchanged SharedData snapshot; the in-process timer only computes display time). Confidence is high because every code-structure fact was verified directly; the only external fact (stopMonitoring not firing callbacks) is corroborated by the project's own documentation and internal contract.

> [real=false, medium] REPRODUCE trace: Steps 1-2 of the scenario hold exactly as claimed in code. stopBreak() (StrategyManager.swift:690-715) only calls DeviceActivityCenterUtil.removeBreakTimerActivity (line 702) → stopActivities → DeviceActivityCenter.stopMonitoring (DeviceActivityCenterUtil.swift:302-306), then reloads the session. Grep confirms SharedData.setBreakEndTime is called ONLY from BreakTimerActivity.stop() (BreakTimerActivity.swift:72), and the only post-break activateRestrictions call is BreakTimerActivity.swift:68, both reachable only via the monitor extension's intervalDidEnd (DeviceActivityMonitorExtension.swift:37-42). So the outcome rests entirely on step 3: whether stopMonitoring fires intervalDidEnd. That step FAILS to hold under the best available evidence: (a) the only source found that explicitly documents this behavior (habitdoom.com/blog/apple-screen-time-api-guide) states the opposite of the claim — "When you call center.startMonitoring() for a DeviceActivityName that is already being monitored, it first calls stopMonitoring() internally. This triggers intervalDidEnd on your DeviceActivity Monitor extension" — i.e. programmatic stopMonitoring DOES fire intervalDidEnd; (b) the code's paired comments show the author designed for and observed exactly this cross-process contract: startBreak's "break start time was set in a different thread" (line 683) relies on intervalDidStart firing on programmatic startMonitoring mid-interval — which demonstrably works, since that is the ONLY code path that lifts restrictions when a break starts (BreakTimerActivity.start:39) and the break feature functions — and stopBreak's symmetric comment "break end time was set in a different thread" (line 710) relies on intervalDidEnd firing on programmatic stopMonitoring; if the start-side callback fires on programmatic registration, the framework plainly does deliver callbacks for programmatic monitoring changes; (c) this break start/stop flow is inherited unchanged from upstream Foqos (git: "moved break function to simple start/stop"), a shipped App Store app where ending a break early is core UX — a two-tap permanent unblock plus a break toggle stuck forever (isBreakActive stays true so toggleBreak at StrategyManager.swift:140 would loop into stopBreak endlessly) would be an immediately obvious production bug. The claim's internal-inconsistency argument (scheduleStopActivity's stopActivities-then-startMonitoring on every loadActiveSession, StrategyManager.swift:102 / DeviceActivityCenterUtil.swift:117-134, would end the session on launch if the callback fires) is a genuine observation, but it cuts the other way: given the callback DOES fire, the latent defect is in the stop-schedule re-registration path (a different bug than claimed), not in stopBreak. The claimed failure scenario (break never re-blocks, permanent bypass, breakEndTime never written) therefore does not reproduce as written; at worst there is a brief async race where loadActiveSession at line 711 reads a snapshot before the extension writes breakEndTime — transient UI staleness, not the claimed critical bypass. Confidence is medium rather than high because Apple does not document stopMonitoring's callback behavior, community reports are mixed and iOS-version-dependent, and I could not empirically run the extension. Sources: https://habitdoom.com/blog/apple-screen-time-api-guide , https://letvar.medium.com/time-after-screen-time-part-3-the-device-activity-monitor-extension-284da931391b , https://developer.apple.com/forums/thread/721945

## Suggested fix approach

In stopBreak(), perform the break-end work in-process: set session.breakEndTime + SharedData.setBreakEndTime, save context, and call appBlocker.activateRestrictions(for: snapshot) directly, keeping removeBreakTimerActivity only as cleanup. Audit every stopActivities-before-startMonitoring re-registration (loadActiveSession:102, scheduleTimerActivity, scheduleStopActivity) for the opposite assumption and make extension stop() handlers idempotent guards.

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
