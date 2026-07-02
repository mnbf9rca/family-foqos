# Handover: Two divergent lock-code caches: child rejects a newly changed PIN and keeps accepting the old one until app relaunch

- **GitHub issue:** #208
- **Severity:** high
- **Domain:** family-lockcode
- **Primary location:** `Foqos/Utils/LockCodeManager.swift:197`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

Verification in child mode uses LockCodeManager.cachedLockCodes (LockCodeManager.swift:248, 265), which is refreshed ONLY inside the private fetchSharedLockCodes() called from handleModeChange (line 61) — i.e. once per process launch or on an actual mode change. All runtime refresh paths update a different cache instead: ChildDashboardView.onAppear/pull-to-refresh calls cloudKitManager.fetchSharedLockCodes() directly (ChildDashboardView.swift:169), which updates CloudKitManager.sharedLockCodes (used only for UI visibility), never LockCodeManager.cachedLockCodes. FoqosApp share acceptance (FoqosApp.swift:512) does the same.

## Failure scenario

Parent changes the family PIN from 1234 to 5678 while the child's app is running (or has been backgrounded for days). Child pulls to refresh the dashboard — the UI cache updates but the verification cache does not. Child (or parent at the child's device) enters the correct new PIN 5678: rejected, and each attempt increments the failure throttle toward a 15-minute lockout. Meanwhile the revoked old PIN 1234 still unlocks managed profiles until the app is force-restarted.

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, high] Attempted refutation failed on every front. (1) Child-mode verification exclusively reads LockCodeManager.cachedLockCodes. (2) cachedLockCodes is written only inside the private fetchSharedLockCodes(), whose only caller is handleModeChange via the appModeManager.$currentMode Combine sink — which fires once at singleton init (launch) and on actual mode changes. The per-foreground verifySelfFamilyMemberRecord() does NOT re-fire it: it returns enforcedMode:nil unless localMode != cloudKitMode, so a device already in child mode never re-triggers the refresh. (3) All runtime refresh paths (ChildDashboardView .refreshable/.onAppear, FoqosApp share acceptance) call CloudKitManager.fetchSharedLockCodes() directly, which updates only CloudKitManager.sharedLockCodes — a separate cache used purely for UI visibility strings; LockCodeManager never observes it. (4) Remote CloudKit notifications route only to ProfileSyncManager/HeartbeatManager, never to lock codes. (5) FamilyLockCode is a value-type struct whose updateCode() regenerates salt+hash, so the child's cached copy keeps validating the revoked old PIN and rejecting the new one; each rejection increments the persistent failure throttle (recordFailedAttempt) toward a 15-minute lockout. The failure scenario (parent changes PIN while child's app process is alive; pull-to-refresh updates only the UI cache) is reachable and unguarded. Only app relaunch or a genuine mode change resyncs the verification cache.

> [real=true, high] Reproduced the full chain in code. (1) cachedLockCodes is populated exactly once per process (LockCodeManager init subscribes to $currentMode, initial emission triggers handleModeChange -> private fetchSharedLockCodes) and again only on an actual mode change; verifySelfFamilyMemberRecord on scenePhase .active returns enforcedMode:nil when local and CloudKit modes match, so no re-emission on foreground; remote pushes route only to ProfileSyncManager/heartbeats. (2) Child dashboard pull-to-refresh and onAppear (and FoqosApp share flow) call CloudKitManager.fetchSharedLockCodes directly, updating only CloudKitManager.sharedLockCodes, which is used exclusively for UI visibility — never the verification cache. (3) Child-mode verifyCode/validateCode read cachedLockCodes, so after a parent PIN change the new PIN is rejected and the old PIN still verifies until app relaunch. (4) Each rejected (correct new) PIN calls recordFailedAttempt, escalating to lockouts up to 15 minutes. Every step in the claimed scenario holds as written; severity 'high' is fair given the child can be locked out with the correct PIN while the revoked PIN keeps unlocking managed profiles.

## Suggested fix approach

Make LockCodeManager the single owner of the shared-code cache: route ChildDashboardView/share-acceptance refreshes through a public LockCodeManager.refreshSharedCodes() that updates cachedLockCodes (and processes pending commands), or have LockCodeManager observe CloudKitManager.$sharedLockCodes.

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
