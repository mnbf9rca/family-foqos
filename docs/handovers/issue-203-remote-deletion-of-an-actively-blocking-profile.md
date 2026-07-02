# Handover: Remote deletion of an actively-blocking profile never deactivates ManagedSettings restrictions and leaves StrategyManager holding a zombie session

- **GitHub issue:** #203
- **Severity:** high
- **Domain:** models-swiftdata
- **Primary location:** `Foqos/CloudKit/SyncCoordinator.swift:195`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

SyncCoordinator's deletion reconciliation (handleSyncedProfiles, lines 184-197) deletes any local profile missing from the remote set with no check for an active local session — unlike BlockedProfileListView.deleteProfiles, which explicitly blocks deleting the active profile. BlockedProfiles.deleteProfile (Foqos/Models/BlockedProfiles.swift:469-494) ends the session in SwiftData and endSession flushes the SharedData active session, but nothing on this path calls AppBlockerUtil.deactivateRestrictions() or StrategyManager.stopBlocking, so the ManagedSettings shields remain applied. StrategyManager.activeSession still references the now-deleted session model; its timer keeps ticking against a zombie SwiftData object (the exact EXC_BREAKPOINT class SafeQuery/SafeModelView guard against, but manager-held references are unprotected).

## Failure scenario

Same-user device A deletes profile P while device B is actively blocking with P. B's next sync runs handleSyncedProfiles: P has syncVersion > 0 and is absent from remoteProfileIds, so deleteProfile(P) runs. Result on B: apps stay shielded with no session or profile visible in the UI to stop them (stuck blocking until Emergency Unblock or reinstall), and the next timer tick / UI access through strategyManager.activeSession touches a deleted model and can crash with EXC_BREAKPOINT.

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, high] Attempted refutation failed on every front. (1) The reconciliation loop at SyncCoordinator.swift:187-196 has no guard for the profile owning the active session, unlike the local UI delete path. (2) BlockedProfiles.deleteProfile ends and deletes sessions in SwiftData only; exhaustive search of deactivateRestrictions call sites confirms nothing on the sync-deletion path clears ManagedSettings shields. (3) No other mechanism compensates: the CloudKit session record for P is not deleted by ProfileSyncManager.deleteProfile, B ignores its own session record (lastModifiedBy == B), and syncAllProfileSessions can no longer visit P after local deletion — so stopRemoteSession never fires. (4) StrategyManager.activeSession retains the deleted session model and the 1s timer dereferences it (isBreakActive, startTime, blockedProfile relationship) after context.save(), the exact zombie-model EXC_BREAKPOINT class this codebase guards elsewhere with SafeQuery/SafeModelView; manager-held references are unprotected. (5) The scenario is reachable: the deletion that pushes to CloudKit comes from BlockedProfileView (the sole deleteProfileFromSync caller), which has no active-session guard, and device A commonly won't mirror B's session because startRemoteSession bails on needsAppSelection. Minor caveats only: the crash is plausible rather than deterministic (window closes at next loadActiveSession on foreground), and Settings → resetBlockingState is an additional user escape hatch beyond Emergency Unblock; the deterministic outcome remains shields applied with no visible session or profile to stop them.

> [real=true, high] Traced the full failure chain. (1) SyncCoordinator.handleSyncedProfiles deletion reconciliation (lines 184-201) deletes any synced profile absent from remoteProfileIds with no active-session check, then saves the context — unlike BlockedProfileListView.deleteProfiles (136-154) which blocks deleting the active profile. (2) BlockedProfiles.deleteProfile (469-494) ends and deletes sessions but never calls AppBlockerUtil.deactivateRestrictions() or StrategyManager.stopBlocking; endSession only sets endTime and flushes the SharedData snapshot. ManagedSettings shields (set on ManagedSettingsStore "familyFoqosAppRestrictions") are cleared only by deactivateRestrictions, which is unreachable on this path — so apps stay shielded with no profile/session in the UI to stop them. (3) No recovery: loadActiveSession on relaunch finds no active session and ends the Live Activity without deactivating restrictions; applySessionState ignores B's own session record (lastModifiedBy == deviceId, line 377); syncAllProfileSessions no longer iterates the deleted profile. (4) StrategyManager.activeSession is never cleared; the 1s timer loop (180-199) dereferences session.isBreakActive → blockedProfile.breakTimeInMinutes and session.startTime on the deleted @Model each tick — the exact zombie-model EXC_BREAKPOINT class the project's SafeQuery/SafeModelView exist to prevent, and manager-held references are unprotected. (5) Scenario reachable: BlockedProfileView's delete (786-806) has no active-session guard, so device A can delete P while B is blocking, and deleteProfileFromSync removes the CloudKit record so P disappears from remoteProfileIds on B's next pull. Every step of the claim holds as written.

## Suggested fix approach

Before deleting during reconciliation, check whether the profile owns the active session; if so, route through StrategyManager.stopBlocking (or at minimum call appBlocker.deactivateRestrictions() and clear StrategyManager.activeSession) before BlockedProfiles.deleteProfile, or defer the deletion until the session ends like migration does.

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
