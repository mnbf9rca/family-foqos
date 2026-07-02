# Handover: sendCommand fails with serverRecordChanged when a command with the same deterministic recordName is still pending

- **GitHub issue:** #222
- **Severity:** medium
- **Domain:** cloudkit-sync
- **Primary location:** `Foqos/CloudKit/CloudKitNetworkService+Commands.swift:17`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

sendCommand saves a freshly constructed CKRecord (FamilyCommand.toCKRecord builds a new record with a deterministic recordName '<type>-<childId>-<parentId>', FamilyCommand.swift:75-92) via privateDatabase.save with the default ifServerRecordUnchanged policy. If a command of the same type is still pending for that child (child offline, hasn't processed and deleted it yet, and it is younger than the 7-day GC), the new record collides with the existing one and the save fails with CKError.serverRecordChanged. The code comments claim the deterministic name 'prevents duplicate commands when parent taps button multiple times', but instead of idempotently succeeding the call throws CloudKitError.saveFailed, which surfaces as an error alert in ParentDashboardView (lines 1110/1150 catch and show resetErrorMessage).

## Failure scenario

Parent taps 'Reset emergency count' for a child whose device is off. Three days later, unsure it worked, the parent taps it again: sendCommand throws and the dashboard shows 'Failed to save: Server Record Changed', a cryptic error for what should be a no-op/refresh — the parent cannot tell whether the reset is queued.

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, high] Could not refute. FamilyCommand.toCKRecord constructs a fresh CKRecord (no server change tag) with a deterministic recordName '<type>-<childId>-<parentId>' (FamilyCommand.swift:75-79). sendCommand saves it via the async CKDatabase.save API, whose default save policy is .ifServerRecordUnchanged; if a record with that ID already exists on the server (prior command still pending because the child hasn't fetched/deleted it, and it is younger than the 7-day cleanupStaleCommands cutoff), CloudKit rejects the save with CKError.serverRecordChanged. sendCommand has no fetch-before-save, no delete-before-save, and no serverRecordChanged special-casing — it wraps every error as CloudKitError.saveFailed and rethrows (CloudKitNetworkService+Commands.swift:16-22). Both ParentDashboardView call sites (resetEmergencyCount line 1110, resetLockCodeThrottle line 1150) catch and display error.localizedDescription as an alert, so a second tap on an idempotent command surfaces as a cryptic failure rather than a no-op success. The codebase demonstrably knows this failure mode: SessionSyncService.swift:203 and :271 explicitly handle .serverRecordChanged with server-record merge — sendCommand does not. No guard elsewhere prevents the collision: nothing disables re-sending while a command is pending, and cleanupStaleCommands only deletes records older than staleCommandMaxAgeDays (7 days). The code comment at FamilyCommand.swift:33 ('prevents duplicate commands when parent taps button multiple times') describes intent that the default save policy defeats.

## Suggested fix approach

Fetch the existing record first and update it (refresh createdAt), or use a CKModifyRecordsOperation with .allKeys/.changedKeys save policy, or treat serverRecordChanged as success for idempotent commands.

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
