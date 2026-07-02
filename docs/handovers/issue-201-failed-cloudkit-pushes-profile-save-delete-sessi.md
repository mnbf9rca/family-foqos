# Handover: Failed CloudKit pushes (profile save/delete, session stop) are logged and dropped with no retry — silent divergence and stuck blocking

- **GitHub issue:** #201
- **Severity:** high
- **Domain:** cloudkit-sync
- **Primary location:** `Foqos/CloudKit/SyncCoordinator.swift:624`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

Every push path swallows errors terminally: SyncCoordinator.pushProfile (lines 621-630) increments and persists syncVersion FIRST, then pushes in a Task whose failure is only logged — the local copy is now permanently 'newer' (version N+1) than the cloud (N), so the next pull's `synced.version > profile.syncVersion` check (line 161) rejects the cloud copy and pushLocalData later overwrites cloud with whatever this device has; deleteProfileFromSync (lines 634-648) swallows delete failures so an offline deletion never reaches other devices and the profile resurrects there; the session-stop CAS result `.error` is logged and dropped in StrategyManager.swift:647 with no retry queue, leaving the authoritative ProfileSession record isActive=true forever (the owning device ignores its own record via the lastModifiedBy check in applySessionState, SyncCoordinator.swift:377).

## Failure scenario

User stops a blocking session on iPhone while in airplane mode. stopSession() returns .error(networkUnavailable), logged and discarded. The CloudKit ProfileSession record stays isActive=true. The iPad pulls it on every sync and keeps (re-)starting the blocking session; because the record's lastModifiedBy is the iPhone, the iPhone never re-processes it either. The iPad remains blocked until the user manually stops it there — impossible without the physical tag under strict mode.

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, high] Attempted refutation failed on the two severity-defining paths. (1) Session stop: on network failure, stopSession returns .error which StrategyManager logs and discards with no persisted retry; the CloudKit record remains isActive=true with lastModifiedBy = the stopping device, which applySessionState permanently ignores (SyncCoordinator.swift:377), while every other same-user device treats the record as authoritative and (re-)starts blocking (line 384). No staleness/expiry mechanism exists in SessionSyncService/SyncCoordinator/ProfileSyncManager (grep for stale/expiry/heartbeat found none in these files). The claimed airplane-mode scenario — iPad stuck blocked until manually stopped there, requiring the physical tag under strict mode — is reachable exactly as described. (2) Deletion: deleteProfileFromSync swallows failure and nothing re-attempts it — pushLocalData only pushes profiles still present locally — so the deletion never propagates, and the profile even resurrects on the deleting device when another device's pushLocalData re-uploads it (createLocalProfile path, line 167-169). (3) The profile-push part of the claim is overstated: pushLocalData at the end of every performFullSync re-pushes all local profiles, so a failed pushProfile IS implicitly retried on next full sync (cold launch, CK push notification, or manual sync), and the local N+1 copy overwriting the cloud is the correct propagation of the newest local edit rather than divergence per se; the residual risk there is a widened concurrent-edit LWW window, since full sync does not run on every foregrounding. That caveat reduces one sub-claim but does not refute the finding: the delete and session-stop paths have zero retry and produce silent divergence / stuck blocking exactly as claimed, matching the high severity.

> [real=true, high] Traced the failure scenario end-to-end and every step holds. (1) Session stop offline: SessionSyncService.stopSession returns .error on the initial fetchSession network failure; StrategyManager.swift:646-647 only logs it. The cloud ProfileSession record remains isActive=true with lastModifiedBy = the stopping device. (2) No recovery: applySessionState (SyncCoordinator.swift:377-379) skips records where lastModifiedBy == own deviceId, so the stopping device never reconciles/re-pushes after reconnecting; no outbox exists, and pushLocalData re-pushes only profiles and locations, never session records. (3) Other devices see isActive=true forever — applySessionState's stop branch (!session.isActive && localActive) never fires and the start branch re-starts blocking — so the iPad stays blocked until manually stopped there (requiring the physical tag in strict mode). Additionally, the stopping device's own next startSession joins the phantom active record (.alreadyActive). The delete-drop sub-claim is also confirmed: local deletion completes first, delete failure at SyncCoordinator.swift:641-645 is swallowed, and no state remains to retry, so the profile resurrects on other devices. The pushProfile sub-claim is mostly confirmed (version incremented and persisted before an unconfirmed push; line 161 then rejects cloud data), with one overstatement: pushLocalData on each full sync does re-push all profiles, so single-editor failures eventually heal — but concurrent edits at the same version number silently diverge exactly as described. The most severe consequence (permanently stuck blocking on peer devices after an offline stop) is fully reproducible in the code as written.

## Suggested fix approach

Persist a pending-operations outbox (profile pushes, deletions, session stops) and drain it on next sync/foreground; only increment syncVersion after a confirmed save, or reconcile via CKRecord server change tags instead of a local counter.

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
