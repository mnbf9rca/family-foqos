# Handover: Remote location deletion via sync leaves dangling geofence references in profiles (local delete cleanup is never replicated)

- **GitHub issue:** #216
- **Severity:** high
- **Domain:** location-nfc-qr
- **Primary location:** `Foqos/CloudKit/SyncCoordinator.swift:493`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

The local delete path strips the location from every profile's geofenceRule (SavedLocationsView.removeLocationFromProfiles, SavedLocationsView.swift:196-213) before deleting. The sync reconciliation path does not: SyncCoordinator.handleSyncedLocations (SyncCoordinator.swift:484-499) calls SavedLocation.delete for any synced local location missing from the remote set, with no equivalent cleanup of BlockedProfiles.geofenceRule. Additionally, removeLocationFromProfiles on the deleting device saves the cleaned profiles locally but never pushes them to ProfileSyncManager, so other devices' profile records retain the stale reference even after their location record is reconciled away. This directly manufactures the dangling-reference state exploited by the LocationManager evaluation bug above.

## Failure scenario

Devices A and B sync the same Apple ID. Profile P ('Must be outside Library') and location 'Library' exist on both. On A the user deletes Library — A cleans its own profiles, pushes the location deletion. B's next sync deletes its local Library via reconciliation (line 490-494) but P on B still references the dead UUID. When P is active on B, every stop attempt is denied ('You must leave  to stop this profile.'), and B may even push P's stale rule back, re-corrupting A.

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, high] Every element of the claim checks out in code. (1) The sync reconciliation deletion path (SyncCoordinator.handleSyncedLocations, lines 487-494) deletes local SavedLocation records with bare SavedLocation.delete and performs no profile geofenceRule cleanup; a repo-wide grep confirms the only reference-stripping code is in SavedLocationsView.removeLocationFromProfiles, which runs only on the deleting device's local UI path. (2) That local path never pushes the cleaned profiles (pushProfile is only invoked from profile save, schema auto-heal, and reset re-push), so remote profile records retain the stale location reference indefinitely. (3) The dangling reference is genuinely harmful: hasLocations counts references (not resolvable locations), and checkGeofenceRule skips dead references, so an .outside rule whose only reference is dead yields unsatisfiedLocations.count(0) != locationReferences.count(1) and permanently returns .failed with the exact empty-name message claimed ("You must leave  to stop this profile."); .within fails equally. Stops on the other device are therefore permanently denied while the profile is active. (4) updateLocalProfile blindly applies synced.geofenceRule, so a later edit on the stale device pushes the corrupt rule back. No guard, sanitizer, or alternate cleanup exists anywhere to refute the claim.

> [real=true, high] Reproduced the full chain step by step. (1) Local delete on device A: SavedLocationsView.deleteLocation (168-194) calls removeLocationFromProfiles (196-213), which strips the location from every profile's geofenceRule and saves locally — but it never bumps profile.syncVersion/updatedAt and never calls SyncCoordinator.shared.pushProfile; only profileSyncManager.deleteLocation(locationId) is pushed. Profiles are pushed only from BlockedProfileView.saveProfile:864, the reset re-push, and the schema auto-heal — so the cleaned profiles never reach CloudKit; the remote profile records keep the stale location reference. (2) Remote reconciliation on device B: SyncCoordinator.handleSyncedLocations (423-507) deletes local synced locations absent from the remote set via SavedLocation.delete at line 493 with zero geofenceRule cleanup anywhere in the function (the only reference-stripping code in the entire repo is the one in SavedLocationsView, confirmed by grep). B's profile P now holds a dangling savedLocationId, and geofenceRule.hasLocations remains true because locationReferences is non-empty. (3) Harm at stop time: StrategyManager (287-294) blocks stop when GeofenceEvaluator.evaluateGeofenceForStop returns unsatisfied; evaluateGeofenceForStop (44-48) only short-circuits when hasLocations is false, then delegates to LocationManager.checkGeofenceRule. There, dangling references are skipped (128-130: 'continue // Skip references to deleted locations'), so for an .outside rule unsatisfiedLocations.count (0) can never equal rule.locationReferences.count (1) — line 160 — producing the exact claimed message with an empty name at line 164: "You must leave  to stop this profile." (.within rules fail identically at 154-155). The stop is permanently denied since the location no longer exists to satisfy. (4) Re-corruption of A is also possible: if P is later edited/saved on B, pushProfile increments syncVersion and A applies the stale geofenceRule via updateLocalProfile (SyncCoordinator.swift:233 'profile.geofenceRule = synced.geofenceRule'). Every element of the claim is confirmed in code as written.

## Suggested fix approach

Before SavedLocation.delete in handleSyncedLocations, run the same reference-stripping as SavedLocationsView.removeLocationFromProfiles; and have the local delete path push the updated profiles so remote copies converge.

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
