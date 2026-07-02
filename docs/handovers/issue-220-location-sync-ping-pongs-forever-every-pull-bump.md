# Handover: Location sync ping-pongs forever: every pull bumps updatedAt, every sync re-pushes, retriggering the other device

- **GitHub issue:** #220
- **Severity:** medium
- **Domain:** cloudkit-sync
- **Primary location:** `Foqos/CloudKit/SyncCoordinator.swift:439`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

handleSyncedLocations applies a remote location when `syncedLocation.lastModified > existingLocation.updatedAt` (line 439) and calls SavedLocation.update, which sets updatedAt = Date() (SavedLocation.swift:102) — i.e., strictly newer than the remote timestamp just applied. pushLocalData then pushes ALL locations after every full sync with lastModified = updatedAt (SyncModels.swift:434), so the peer device sees a 'newer' record, applies it, bumps its own updatedAt, and pushes again. Unlike profiles (guarded by the version counter equality), locations have no origin-device or version guard, so two synced devices exchange writes indefinitely (one round per throttle window), and clock skew between devices decides whose isLocked/name wins on any real concurrent edit.

## Failure scenario

User with iPhone+iPad edits a saved location once on the iPhone. From then on, every ~5 minutes each device's sync pulls the 'newer' copy, rewrites the local model, saves the SwiftData context, and re-pushes the record — endless CloudKit writes and zone-change notifications that never quiesce, burning battery/quota; a genuinely newer edit made on the device with the slower clock is overwritten by the ping-ponged copy.

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, high] Verified the full ping-pong chain in code. Every full sync ends with pushLocalData, which pushes ALL locations with lastModified = updatedAt; handleSyncedLocations applies any remote copy with lastModified > local updatedAt and SavedLocation.update then sets updatedAt = Date(), strictly newer than what was just applied. pushSyncedLocation always saves the CKRecord even when content is identical (lastModified alone changes), generating a zone-change notification that triggers the peer's throttled full sync, which repeats the apply-bump-push cycle. Unlike profiles (originDeviceId skip + version-equality guard make re-applied records a no-op), SyncedLocation has no originDeviceId or version guard, and location syncVersion is used only for deletion reconciliation, not update gating. So two devices never converge: each sync rewrites the local model and re-pushes, re-triggering the other device (worst case one round per 5-minute throttle window; a notification dropped inside the throttle window merely pauses the loop until the next sync, which resumes it). The clock-skew concern is also valid since the comparison mixes wall clocks from different devices. Severity medium (churn/battery/quota and last-writer-by-clock semantics, not data loss of a whole record) is appropriate.

## Suggested fix approach

Preserve the remote lastModified as updatedAt when applying remote data (don't bump the clock on sync-applied writes), skip pushing locations whose content hasn't changed, and add an originDeviceId/version guard like profiles have.

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
