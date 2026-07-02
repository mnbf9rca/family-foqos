# Handover: CKQuery-based pull + reconciliation can delete a just-created profile due to query index lag

- **GitHub issue:** #219
- **Severity:** medium
- **Domain:** cloudkit-sync
- **Primary location:** `Foqos/CloudKit/SyncCoordinator.swift:189`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

Deletion reconciliation treats absence from a CKQuery result as remote deletion (lines 186-197). CloudKit query indexes are eventually consistent: a record saved via pushProfile can be missing from a `records(matching:)` query for seconds afterwards. pushProfile (SyncCoordinator.swift:598-631) sets syncVersion=1 and persists it before the push completes, making the profile eligible for reconciliation deletion. There is no change-token (CKFetchRecordZoneChangesOperation) usage anywhere; all pulls are full NSPredicate(value:true) queries, so this window exists on every sync.

## Failure scenario

User creates a profile on the iPhone; pushProfile persists syncVersion=1 and saves the record. Seconds later a zone-change notification (triggered by that very save, or by the iPad's pushLocalData) starts performFullSync; the query index has not yet caught up and omits the new record, so allRemoteProfileIds lacks the new profile's UUID and reconciliation deletes the profile the user just created on the same device.

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, high] The claimed mechanism is fully present in the code. (1) Pulls are CKQuery-based full scans (ProfileSyncManager.swift:471-477 via records(matching:) at 243-246); no change tokens exist anywhere in Foqos/CloudKit, and CKQuery indexes are eventually consistent, so a just-saved record can be absent from query results. (2) Deletion reconciliation (SyncCoordinator.swift:186-196) deletes any local profile with syncVersion > 0 absent from the query-derived ID set. (3) pushProfile (SyncCoordinator.swift:610-618) increments syncVersion to 1 and persists it synchronously BEFORE the async push Task executes, so a just-created profile is immediately eligible for reconciliation deletion — defeating the guard whose own comment says it exists to protect not-yet-pushed profiles. It is invoked on every profile save (BlockedProfileView.swift:864). (4) No guard closes the window: the empty-remote-set check (line 179) only fires when the set is entirely empty; the originDeviceId skip (line 117) applies to updates/creates, not deletion; the 5-minute notification throttle (ProfileSyncManager.swift:888-896) narrows the window but is bypassed by manual sync (SettingsView.swift:176) and app-launch setupSync (ProfileSyncManager.swift:172), and performFullSync pulls before pushing (348 vs 354). The defect is even broader than claimed: the race also triggers if the pushTask simply hasn't executed yet, or if the push fails (syncVersion stays 1 with no remote record, guaranteeing deletion on the next successful sync). Medium severity is fair — timing-dependent edge case, but real data loss of a just-created profile; same pattern applies to locations (SyncCoordinator.swift:484-495).

## Suggested fix approach

Use CKFetchRecordZoneChangesOperation with change tokens instead of queries (gives authoritative deletions), or only reconcile deletions against records absent across two consecutive pulls / confirmed via record(for:) fetch.

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
