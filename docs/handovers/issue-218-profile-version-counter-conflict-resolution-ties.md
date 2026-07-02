# Handover: Profile version-counter conflict resolution: ties diverge permanently and stale devices clobber newer cloud data

- **GitHub issue:** #218
- **Severity:** medium
- **Domain:** cloudkit-sync
- **Primary location:** `Foqos/CloudKit/SyncCoordinator.swift:161`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

Pull applies a remote profile only when `syncedProfile.version > existingProfile.syncVersion` (line 161), while pushes (ProfileSyncManager.pushSyncedProfile, lines 435-459, and the unconditional pushLocalData after every full sync, lines 45-96) overwrite the fetched server record's fields with local data without ever comparing the remote version field. Two devices that each edit the same profile from version N produce two divergent N+1 copies: neither device ever accepts the other's copy (not strictly greater), and each full sync's pushLocalData rewrites the cloud record to the last pusher's content. The devices display different profile configurations (schedules, domains, strict mode) forever with no conflict surfaced.

## Failure scenario

Profile at syncVersion 4 on both iPhone and iPad. User edits the schedule on the iPad (v5, pushed) and, before the iPad's change syncs, edits domains on the iPhone (v5, pushed, overwriting the record). Both devices now hold different v5 data; every subsequent pull skips the remote copy (5 is not > 5), and each device's post-pull pushLocalData flips the cloud record back and forth. The iPad blocks per its schedule, the iPhone per its domains — permanently inconsistent blocking with no banner.

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, high] The defect is real. Pull applies remote profile data only when the remote version is strictly greater (SyncCoordinator.swift:161), while every push path writes the CloudKit record without ever reading the server's version: pushSyncedProfile fetches the existing record purely to reuse its change tag and then overwrites all fields including version (ProfileSyncManager.swift:449-459, SyncModels.swift:171). Local edits increment syncVersion without pulling first (SyncCoordinator.pushProfile, line 610), so two devices editing the same profile from base version N each produce a divergent N+1. Neither device ever accepts the other's copy (N+1 is not > N+1), no updatedAt tiebreaker exists for profiles (locations have one at SyncCoordinator.swift:439; profiles do not), and SyncConflictManager surfaces only schema-version conflicts, not sync-version ties. The unconditional pushLocalData after every full sync (SyncCoordinator.swift:45-96, triggered by ProfileSyncManager.swift:354) then ping-pongs the cloud record content between the two devices' tied versions indefinitely. One caveat: the secondary "stale device clobbers newer cloud data" sub-claim is mostly mitigated because performFullSync pulls before pushing, so a strictly-newer remote version is applied locally before the push — clobbering persists only in the tie case. The core failure scenario (permanent silent divergence on concurrent edits with alternating cloud content) is fully supported by the code. Medium severity is appropriate: it needs a concurrent-edit race window, but the resulting inconsistency is permanent and unsurfaced, affecting blocking behavior (schedules/domains/strict mode).

## Suggested fix approach

On push, fetch the server record's version and merge/bump above it (or use CKRecord serverRecordChanged with a merge handler); on version ties compare updatedAt as a tiebreaker and surface a conflict.

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
