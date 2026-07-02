# Handover: Reset Sync race lets deletion reconciliation wipe all local profiles on other devices

- **GitHub issue:** #195
- **Severity:** critical
- **Domain:** cloudkit-sync
- **Primary location:** `Foqos/CloudKit/ProfileSyncManager.swift:831`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

resetSync() deletes every record in the sync zone (deleteAllSyncedData, line 831) BEFORE saving the SyncResetRequest record (line 839). The zone deletions immediately fire zone-change push notifications to other devices. A second device that syncs in that window (or after a partial failure, e.g. modifyRecords throwing limitExceeded mid-way, which aborts resetSync before the request is ever saved) runs performFullSync: pullResetRequests finds no reset request, pullProfiles finds an empty/partial zone, and the deletion reconciliation in SyncCoordinator.handleSyncedProfiles (SyncCoordinator.swift:186-197) deletes every local profile with syncVersion > 0 because it is 'no longer in remote'. The guard at SyncCoordinator.swift:179 only protects the decode-failure case (remoteIds empty AND decoded profiles non-empty), not a legitimately empty query result. Even when the reset request IS seen first, handleSyncReset (SyncCoordinator.swift:552-559) re-pushes profiles in a detached Task while the same performFullSync continues into pullProfiles, so the query returns only the subset re-pushed so far and reconciliation deletes the rest locally.

## Failure scenario

Family with iPhone+iPad, sync enabled, 8 profiles. User taps Reset Sync on iPhone. iPad receives the zone-change notification from the record deletions before the reset-request record is saved, runs performFullSync, sees zero SyncedProfile records and no reset request, and BlockedProfiles.deleteProfile() is called on all 8 local profiles (SyncCoordinator.swift:195) — app selections, session history, and any active blocking configuration on the iPad are destroyed; profiles later recreated from iPhone's re-push arrive with needsAppSelection=true, so blocking silently stops enforcing apps on the iPad.

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, high] Attempted refutation failed on every angle. (1) Order-of-operations is exactly as claimed: resetSync wipes all records (line 831) before saving the SyncResetRequest (839), and the zone-scoped CKRecordZoneSubscription fires on those deletions, inviting other devices to sync inside the window. (2) The claimed protection gap is real: an empty zone yields didReceiveSyncedProfiles([], []) and the guard at SyncCoordinator.swift:179 requires remoteIds empty AND decoded profiles NON-empty, so a legitimately empty pull falls through to reconciliation, which deletes every local profile with syncVersion > 0 (lines 189-195). (3) The failure-mode variant is worse than a race: if the save at 839 throws after the wipe succeeded, no reset request ever exists and the catch block restores nothing, so ANY later sync on another device (unthrottled paths exist: settings manual sync, sync init) deterministically wipes its local profiles. (4) The second claimed race is also confirmed: pullResetRequests dispatches handleSyncReset, which merely spawns an async pushTask to re-push profiles, while the same performFullSync continues synchronously into pullProfiles (ProfileSyncManager.swift:345-348) — the single query will beat N sequential re-push round trips, so reconciliation runs against a partial remote set; re-pushed profiles keep syncVersion > 0 (rePushLocalSyncedData calls syncManager.pushProfile directly, never resetting versions), so the syncVersion guard does not protect them. No reset-in-progress flag, no reentrancy gate on performFullSync, and no empty-pull bail-out exists anywhere. Only minor caveat: the scenario-1 notification window is narrow (one network op wide), but scenarios 2 and the save-failure variant need no tight timing, so the critical severity stands.

> [real=true, high] Independently reproduced the full failure chain in the code as written. (1) resetSync deletes all zone records (ProfileSyncManager.swift:831) before saving the SyncResetRequest (line 839); a mid-way modifyRecords failure in deleteAllSyncedData (868-873, one call per record type) aborts resetSync so the marker is never written and the re-push delegate call at 848 is skipped, leaving the zone empty of profiles indefinitely. (2) Zone deletions fire the CKRecordZoneSubscription (line 210) on other devices, whose handleRemoteNotification (885) runs performFullSync unless the 5-minute throttle happens to apply. (3) performFullSync pulls reset requests first (345) — none exists in the window — then pullProfiles (348) queries the still-existing zone, gets zero records (the zoneNotFound early return at 537 does not trigger for an empty zone), and delivers ([], []) to the coordinator (532). (4) handleSyncedProfiles' guard (SyncCoordinator.swift:179) only skips reconciliation when remoteProfileIds is empty AND decoded profiles are non-empty; with both empty it proceeds and lines 187-196 delete every local profile with syncVersion > 0 via BlockedProfiles.deleteProfile. The secondary mode is also real: pullResetRequests invokes didReceiveSyncReset synchronously, handleSyncReset re-pushes in an unawaited Task (553-559) while the same performFullSync continues into pullProfiles, so reconciliation can run against a partial remote set. No tombstone, zone deletion, or reset-in-progress gate mitigates any of this. The only probabilistic mitigations (5-minute background-sync throttle, small time window) reduce frequency, not existence, and the partial-failure path leaves the dangerous state persistent rather than transient.

## Suggested fix approach

Save the SyncResetRequest before (or atomically with) the zone wipe; never run deletion reconciliation in the same sync pass that processed a reset request; gate reconciliation on a per-device 'reset in progress' flag and on a non-empty successful pull; await the re-push task before pulling profiles.

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
