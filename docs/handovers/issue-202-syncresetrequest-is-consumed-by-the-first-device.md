# Handover: SyncResetRequest is consumed by the first device that sees it and never cleaned up by the origin — missed resets and stale resets that wipe app selections

- **GitHub issue:** #202
- **Severity:** high
- **Domain:** cloudkit-sync
- **Primary location:** `Foqos/CloudKit/ProfileSyncManager.swift:402`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

pullResetRequests deletes the request record immediately after the FIRST non-origin device processes it (line 402), so in a 3+ device setup the remaining devices never receive the reset (they keep stale data and never clear app selections when clearRemoteAppSelections=true). Conversely, the origin device skips its own request (line 387) and never deletes it, so on a single-device account the record lingers forever: any device that enables sync later — months on — processes the stale reset and executes handleSyncReset(clearAppSelections: true), wiping selectedActivity on all its configured profiles (SyncCoordinator.swift:535-549).

## Failure scenario

User has iPhone only, taps Reset Sync with 'clear app selections'; the request record stays in the zone forever. A year later they set up sync on a configured iPad that previously had sync disabled: its first performFullSync pulls the stale reset, sets needsAppSelection=true and clears the FamilyActivitySelection on every profile — all blocking profiles on the iPad silently stop restricting any apps.

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, high] Both failure modes are directly visible in the code. (1) Consume-on-first-read: pullResetRequests deletes the reset record immediately after the first non-origin device processes it, with no per-device acknowledgment, so in a 3+ device account the other devices never receive the reset and never clear app selections when clearRemoteAppSelections=true. (2) Origin never cleans up: requests where originDeviceId == deviceId are skipped via `continue` and never deleted; on a single-device account the record persists indefinitely (only a subsequent resetSync's deleteAllSyncedData would remove it). (3) No TTL: requestedAt is written to the record but never read or checked anywhere. When sync is later enabled on another device, the $isEnabled sink runs setupSync() → performFullSync() → pullResetRequests() as the very first step; the stale request (different deviceId) is processed, and SyncCoordinator.handleSyncReset sets needsAppSelection=true and selectedActivity = .init() on ALL local profiles and saves — clearing every FamilyActivitySelection so blocking profiles stop restricting apps until the user reselects. Grep confirms the only deletion sites for SyncResetRequest are line 402 and deleteAllSyncedData, and requestedAt appears only in the model. No guard elsewhere refutes the scenario. Minor caveat: the wipe is not entirely silent (needsAppSelection presumably surfaces UI), but the blocking gap is real.

> [real=true, high] Reproduced both legs of the claim by tracing the actual code. (1) First-consumer-wins: pullResetRequests iterates all SyncResetRequest records; for each non-origin device it dispatches the reset and then immediately deletes the CloudKit record (ProfileSyncManager.swift:396-402). There is no per-device ack, no processed-list, and the `requestedAt` field is stored but never read for expiry anywhere in the codebase. So with 3+ devices, whichever non-origin device runs performFullSync first consumes the record; the remaining devices never receive the reset and never clear their app selections when clearRemoteAppSelections=true. (2) Stale lingering reset: the origin skips its own record via `continue` at line 387-389 and never deletes it; the only other deletion path is deleteAllSyncedData (line 865), which runs only during a future resetSync. On a single-device account the record therefore persists indefinitely. deviceId is a per-device random UUID persisted in app-group UserDefaults (SharedData.swift:468-480), so a device that later enables sync has a different deviceId, and setupSync → performFullSync (ProfileSyncManager.swift:172, 345) runs pullResetRequests first, processing the stale request. That calls didReceiveSyncReset → SyncCoordinator.handleSyncReset (SyncCoordinator.swift:529-549), which for clearAppSelections=true sets needsAppSelection=true and replaces selectedActivity with an empty FamilyActivitySelection on EVERY local profile, then saves — silently un-restricting all apps on that device. Every step of the claimed failure scenario holds in the code as written; severity 'high' is justified since the stale-reset path silently disables blocking.

## Suggested fix approach

Give reset requests a TTL/expiry check against requestedAt; have each device mark the request as processed (per-device record or processedBy list) instead of deleting it, with the origin garbage-collecting after all known devices ack or after expiry.

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
