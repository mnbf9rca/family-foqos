# Handover: Parent commands (Reset PIN Attempts / Reset Emergency Count) are only processed at child app launch

- **GitHub issue:** #230
- **Severity:** medium
- **Domain:** family-lockcode
- **Primary location:** `Foqos/Utils/LockCodeManager.swift:279`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

processPendingCommands() is called only from fetchSharedLockCodes() (LockCodeManager.swift:201), which runs only via handleModeChange — effectively once per process launch on a child device. No other code path fetches FamilyCommand records: the remote-notification handler only calls ProfileSyncManager.handleRemoteNotification and (parent mode only) refreshHeartbeats (FoqosApp.swift:350-357), and ChildDashboardView's refresh path uses cloudKitManager.fetchSharedLockCodes() which does not process commands.

## Failure scenario

Child hits 10 failed PIN attempts and is locked out for 15 minutes. Parent taps 'Reset PIN Attempts' in ParentDashboardView (FamilyMemberCard.resetLockCodeThrottle) and sees a success checkmark. Nothing happens on the child device — the throttle-reset command sits unprocessed until the child force-quits and relaunches the app, which the child has no reason to know to do. The feature's primary use case (rescuing a locked-out child immediately) silently fails.

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, high] Attempted refutation failed on every candidate path. (1) processPendingCommands and fetchSharedLockCodes are both private with exactly one caller each; the only trigger is the $currentMode Combine sink in the LockCodeManager singleton, which fires once at first access (initial published value) and again only on genuine mode changes — effectively once per process launch on a child device. (2) The scenePhase .active handler cannot re-trigger it: verifySelfFamilyMember returns enforcedMode only on local/CloudKit mode mismatch, so selectMode is not called on normal foregrounds and the publisher does not re-fire. (3) The remote-notification path cannot deliver commands: the app's only CloudKit subscription is a private-DB zone subscription for profile sync; FamilyCommand lives in the shared DB with no subscription, and the notification handler processes only profile sync and parent heartbeats. (4) ChildDashboardView's refresh calls the CloudKitManager-level fetchSharedLockCodes, which fetches lock codes only — it bypasses command processing entirely. (5) fetchPendingCommands has no other callers anywhere. Therefore a Reset PIN Attempts / Reset Emergency Count command sent from ParentDashboardView sits unprocessed until the child app process relaunches (or the app mode changes), exactly as claimed. Severity 'medium' is reasonable: the feature eventually works after relaunch and the PIN lockout also self-expires (max 15 min), but the advertised immediate-rescue use case silently fails while the parent sees a success checkmark.

## Suggested fix approach

Process pending commands on ChildDashboardView refresh and app-foreground in child mode (call a public LockCodeManager method), and/or subscribe the child to a CKQuerySubscription on FamilyCommand so the remote-notification handler triggers command processing.

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
