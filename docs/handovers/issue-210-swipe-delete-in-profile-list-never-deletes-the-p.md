# Handover: Swipe-delete in profile list never deletes the profile from CloudKit, so sync resurrects it

- **GitHub issue:** #210
- **Severity:** high
- **Domain:** views-primary
- **Primary location:** `Foqos/Views/BlockedProfileListView.swift:160`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

BlockedProfileView's delete alert calls BlockedProfiles.deleteProfile() followed by SyncCoordinator.shared.deleteProfileFromSync(profileId) (BlockedProfileView.swift:798-800). BlockedProfileListView.deleteProfiles(at:) (lines 156-165) calls only BlockedProfiles.deleteProfile() and never deleteProfileFromSync. With profile sync enabled, the CloudKit record survives; on the next pull SyncCoordinator.handleSyncedProfiles finds no local profile and re-creates it via createLocalProfile (Foqos/CloudKit/SyncCoordinator.swift:167-169), and other devices never delete it at all.

## Failure scenario

User with Profile Sync enabled opens Manage Profiles, enters edit mode, and swipe-deletes a profile. Minutes later (next sync pull or on relaunch) the deleted profile reappears in the carousel, and it also remains on every other synced device — deletion silently doesn't stick.

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, high] Attempted to refute, but every link in the claimed defect chain checks out. (1) BlockedProfileListView.deleteProfiles(at:) (lines 156-168) calls only `try BlockedProfiles.deleteProfile(profile, in: context)` and `reorderProfiles`; it never calls SyncCoordinator.shared.deleteProfileFromSync. (2) BlockedProfiles.deleteProfile (BlockedProfiles.swift:469-494) is purely local — it ends sessions, deletes snapshot/activities, and calls context.delete(profile); no CloudKit interaction. (3) The parallel delete path in BlockedProfileView.swift:798-800 DOES call `SyncCoordinator.shared.deleteProfileFromSync(profileId)` after local delete, proving the sync-delete step is required and intentionally paired with local deletion. (4) No compensating mechanism exists: pushLocalData (SyncCoordinator.swift:45-100) and pushProfile/pushSyncedProfile only upsert per-profile CKRecords — nothing ever prunes remote records absent locally, so the CloudKit record survives. (5) On the next pull, handleSyncedProfiles hits the `else` branch at SyncCoordinator.swift:167-169 (`findProfile` returns nil → `createLocalProfile(from:in:)`), and createLocalProfile (lines 267-296) has no tombstone/guard, so the deleted profile is recreated locally. Other devices also keep the record because deletion reconciliation (lines 184-201) removes local profiles only when the id is missing from remoteProfileIds, which never happens since the remote record was never deleted. The only mitigating factor is that the bug requires Profile Sync to be enabled (deleteProfileFromSync guards on syncManager.isEnabled), which the finding already states. Severity 'high' is fair: silent, user-visible data-operation failure (deletion doesn't stick).

> [real=true, high] Traced the full failure chain. Swipe-delete in BlockedProfileListView.deleteProfiles calls only BlockedProfiles.deleteProfile (pure local SwiftData/DeviceActivity cleanup, no CloudKit) and never SyncCoordinator.shared.deleteProfileFromSync — which grep confirms is invoked only from BlockedProfileView.swift:800 and is the sole caller of syncManager.deleteProfile. So the CloudKit record survives a swipe-delete. On other devices, deletion reconciliation (SyncCoordinator.handleSyncedProfiles lines 186-197) only removes local profiles absent from remoteProfileIds; the surviving record keeps the ID present, so remote devices never delete it. Each sync cycle then re-pushes all local profiles (ProfileSyncManager.swift:354 → pushLocalData) stamped with the pushing device's originDeviceId, so on the deleting device's next pull the originDeviceId-skip (SyncCoordinator.swift:117) no longer applies, findProfile returns nil, and createLocalProfile (line 169) resurrects the profile locally. Minor nuance: on a strictly single-device account the local resurrection is masked by the same-origin skip, but the claim's stated multi-device scenario holds exactly as described.

## Suggested fix approach

Capture profile.id before deletion in deleteProfiles() and call SyncCoordinator.shared.deleteProfileFromSync(profileId) for each deleted profile, matching BlockedProfileView's delete path.

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
