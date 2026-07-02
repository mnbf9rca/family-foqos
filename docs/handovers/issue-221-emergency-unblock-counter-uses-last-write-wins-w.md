# Handover: Emergency-unblock counter uses last-write-wins with swallowed serverRecordChanged — concurrent use loses decrements, granting extra unblocks

- **GitHub issue:** #221
- **Severity:** medium
- **Domain:** cloudkit-sync
- **Primary location:** `Foqos/CloudKit/ProfileSyncManager.swift:816`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

pushEmergencySettings (lines 792-818) does fetch-then-overwrite-save with no serverRecordChanged handling or retry, and pushes an absolute unblocksRemaining value computed locally (EmergencyUnblockManager.swift:224-266). Two devices that each perform an emergency unblock from the same base state both push count-1 with version+1: either the second save fails with serverRecordChanged (error logged and swallowed at EmergencyUnblockManager.swift:262-264, local version never bumped, so the next pull at SyncCoordinator.swift:515 overwrites the local decrement with the remote value), or it succeeds and overwrites the first decrement. Either way two consumed unblocks collapse into one.

## Failure scenario

Emergency unblocks remaining = 3 (v5) on both iPhone and iPad. The user emergency-unblocks on the iPhone (pushes 2, v6) and shortly after on the iPad (pushes 2, v6 — save fails serverRecordChanged, swallowed; next sync pulls remote 2). Both devices settle at 2 remaining although 2 of the 3 limited unblocks were consumed — the safety limit designed to stop bypassing blocks is under-counted.

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, high] Confirmed lost-update defect. pushEmergencySettings does fetch-then-blind-overwrite with absolute local values (count and version), no server-side merge, no serverRecordChanged/CAS retry. Two devices decrementing from the same base (3, v5) both push (2, v6); whichever save lands second overwrites (or, in the narrower race, fails with a swallowed error), and the v-based LWW guard in SyncCoordinator cannot distinguish the two writes since both claim v6. Result: two consumed emergency unblocks settle as one, under-counting the safety limit. No guard, queue, or pull-before-decrement exists to prevent this. Minor claim inaccuracy: since the push re-fetches the record just before saving, the second save usually succeeds rather than raising serverRecordChanged — but the claim's "either/or" phrasing covers this and both branches lose a decrement. Severity medium is fair: same-user limit, requires near-concurrent use on two devices, but weakens a limit whose purpose is to stop bypassing blocks (and it is parent-lockable via settingsLocked).

## Suggested fix approach

On serverRecordChanged, refetch, apply the decrement as a delta on top of the server value, and re-save (CAS loop like SessionSyncService); or store per-device usage events and derive the count.

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
