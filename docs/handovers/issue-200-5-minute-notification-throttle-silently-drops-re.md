# Handover: 5-minute notification throttle silently drops remote session start/stop — other devices stay blocked/unblocked indefinitely

- **GitHub issue:** #200
- **Severity:** high
- **Domain:** cloudkit-sync
- **Primary location:** `Foqos/CloudKit/ProfileSyncManager.swift:889`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

handleRemoteNotification() returns without syncing if lastSyncDate is less than 300s old (lines 888-896). CloudKit silent pushes are the ONLY trigger for cross-device session propagation: full sync otherwise runs only on cold launch (FoqosApp.swift:233) and the manual Settings button (SettingsView.swift:176); scenePhase .active never calls performFullSync or handleSessionSync, and SyncCoordinator.syncAllProfileSessions() has no callers. A dropped notification is never re-delivered and there is no deferred re-poll, so the change is simply lost until an unrelated CloudKit change arrives more than 5 minutes after lastSyncDate or the app is relaunched.

## Failure scenario

User's iPhone and iPad both sync at 10:00 (lastSyncDate=10:00 on iPad). At 10:02 the user stops the blocking session on the iPhone; CloudKit pushes the change to the iPad, which logs 'Skipping background sync' and discards it. No further CloudKit changes occur, so the iPad keeps its shields active indefinitely — with strict mode enabled the user cannot stop it locally without the physical NFC tag/QR code.

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, high] Attempted refutation failed on every axis. (1) The throttle at ProfileSyncManager.swift:889-896 discards the notification with a plain return — there is no deferred sync, timer, or targeted pullProfileSessionRecords. (2) CloudKit silent pushes routed through FoqosApp.swift:352 are the sole automatic cross-device sync trigger while the app is alive: scenePhase .active (FoqosApp.swift:130-143) performs no sync, syncAllProfileSessions/handleSessionSync have no callers, and no BGTask or Timer performs periodic sync (TimersUtil BGTasks are for timer expiry only). (3) The only other performFullSync entry points are cold-launch setupSync, the manual Settings button, and the sync-reset flow — none rescue a dropped notification. Since lastSyncDate updates on every successful full sync, any remote session start/stop occurring within 5 minutes of the receiver's last sync is silently lost until an unrelated CloudKit change arrives after the window or the app is relaunched, leaving shields stuck (unstoppable locally in strict mode). Claim confirmed as a real high-severity defect.

> [real=true, high] Reproduced the failure chain step by step. (1) handleRemoteNotification (ProfileSyncManager.swift:885-900) drops any CloudKit silent push arriving within 300s of lastSyncDate and schedules nothing before returning. (2) That handler is the sole action taken in didReceiveRemoteNotification (FoqosApp.swift:339-362), and the zone subscription uses one-shot content-available silent pushes — CloudKit does not redeliver them. (3) No recovery path exists: scenePhase .active in FoqosApp triggers only account/role/auth checks and reminder rescheduling; HomeView's .active handler calls loadActiveSession which reads local SwiftData only; SyncCoordinator.syncAllProfileSessions() is dead code with zero callers. (4) performFullSync (which pulls ProfileSessionRecords at line 349) runs otherwise only on cold launch (setupSync), the manual Settings sync button, or a sync reset. Therefore a session start/stop pushed from device A within 5 minutes of device B's last sync is silently lost on device B until relaunch, manual sync, or a later unrelated CloudKit change — matching the claimed scenario (10:00 sync, 10:02 stop → 120s < 300s → dropped, shields stay active). Only the incidental strict-mode/NFC detail is unverified; the core defect is confirmed.

## Suggested fix approach

Instead of dropping the notification, schedule a deferred sync for when the throttle window expires (or do a targeted pullProfileSessionRecords, which is cheap); also sync sessions on scenePhase .active.

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
