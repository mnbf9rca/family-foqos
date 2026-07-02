# Handover: Profile reorder is never pushed to sync, so remote updates revert the user's ordering

- **GitHub issue:** #233
- **Severity:** medium
- **Domain:** views-primary
- **Primary location:** `Foqos/Views/BlockedProfileListView.swift:176`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

moveProfiles() calls BlockedProfiles.reorderProfiles(), which rewrites `order` on every profile and saves (Foqos/Models/BlockedProfiles.swift:546-554) but does not bump syncVersion, push via SyncCoordinator.pushProfile, or update SharedData snapshots. The order field IS part of the sync payload: SyncCoordinator.updateLocalProfile applies synced.order whenever an inbound profile has a higher syncVersion (SyncCoordinator.swift:215-217). So local reorders never propagate to other devices, and any subsequent edit of a profile on another device pushes back that profile's stale order value, silently moving it back and creating duplicate/gapped order values locally.

## Failure scenario

User reorders profiles on their iPhone (sync enabled). On their iPad they rename one profile; when the iPhone pulls that update, updateLocalProfile overwrites the renamed profile's `order` with the iPad's stale value and the carousel/list order jumps back, showing two profiles with the same order index (tie-broken by createdAt).

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, high] Confirmed against the code. reorderProfiles (BlockedProfiles.swift:548-556) rewrites `order` on every profile and saves, but does not bump syncVersion, call SyncCoordinator.pushProfile, or update snapshots. The only caller of pushProfile from UI is BlockedProfileView.saveProfile (BlockedProfileView.swift:864); moveProfiles in BlockedProfileListView (line 176) does not push. `order` is part of the sync payload (SyncModels.swift:25/142/259) and updateLocalProfile applies synced.order whenever the inbound version is higher (SyncCoordinator.swift:161, 219). I attempted two refutations: (a) periodic pushLocalData does push all profiles to CloudKit after a reorder, but it does so without incrementing syncVersion, so receiving devices skip the update at the `synced.version > existingProfile.syncVersion` gate — the reorder still never propagates; (b) the origin-device filter (SyncCoordinator.swift:117) does not protect the reordering device from a later inbound edit from another device. Therefore the claimed failure scenario holds: device A reorders (no version bump anywhere), device B later edits/renames one profile via saveProfile → pushProfile bumps version and pushes B's stale order; device A applies it (version is higher), reverting that profile's order and potentially creating duplicate/gapped order values. Severity medium is appropriate: user-visible ordering revert/corruption, only when multi-device sync is enabled, no crash or data loss.

## Suggested fix approach

After reorderProfiles succeeds, push each affected profile (or a batch) through SyncCoordinator so syncVersion increments and remote copies learn the new order; also refresh snapshots if widgets consume order.

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
