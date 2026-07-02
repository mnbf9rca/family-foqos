# Handover: Geofence rules referencing deleted locations become permanently unsatisfiable — active profile can never be stopped

- **GitHub issue:** #215
- **Severity:** high
- **Domain:** location-nfc-qr
- **Primary location:** `Foqos/Utils/LocationManager.swift:160`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

checkGeofenceRule skips references whose SavedLocation no longer exists ('continue' at LocationManager.swift:128-130), but the '.outside' branch (line 160) requires unsatisfiedLocations.count == rule.locationReferences.count — a count that includes the skipped dangling references, so the rule can never be satisfied. Similarly, a '.within' rule whose referenced locations were all deleted still passes the rule.hasLocations gate (GeofenceRule.swift:78-79, checks locationReferences not resolvable locations), evaluates with empty satisfiedLocations, and fails forever with the garbled message 'You must be within  to stop this profile.' (empty name list, line 154-155). All stop paths (toggleBlocking, stopWithNFCTag/stopWithQRCode, deep link, background stop) route through this evaluation, so the session is unstoppable except via emergency unblock.

## Failure scenario

Profile has stop restriction 'Must be outside Library'. The Library SavedLocation is deleted out from under the rule (see the sync finding below, or a profile record syncing to a device where the location push previously failed). User starts the profile, then walks miles away and taps stop: unsatisfiedLocations.count is 0 (reference skipped) != locationReferences.count of 1, so the stop is denied with 'You must leave  to stop this profile.' — permanently, everywhere on Earth, until emergency unblocks are spent.

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, high] Attempted refutation failed on every front. (1) The count-mismatch logic is exactly as claimed: dangling references are excluded from both satisfied/unsatisfied buckets but included in rule.locationReferences.count, so an `.outside` rule with any dangling reference is unsatisfiable anywhere on Earth, and the failure message renders with an empty location name. A `.within` rule whose references all dangle passes the hasLocations gate and fails forever. (2) The only mitigation — removeLocationFromProfiles in SavedLocationsView — is local-only: the pruned profiles are never re-pushed to CloudKit, and the sync-side deletion reconciliation in SyncCoordinator deletes locations without pruning any profile rules, while profile pull re-applies the stale rule from the remote record. So a dangling reference genuinely arises on any second device (or via a failed location push). (3) Every stop path (foreground stop, background stop, start-warning, emergency unblock) funnels into LocationManager.checkGeofenceRule via GeofenceEvaluator; when allowEmergencyOverride is false the emergency escape hatch is blocked by the same broken evaluation, making the session completely unstoppable. No other guard, pruning pass, or repair mechanism exists in the codebase.

> [real=true, high] Reproduced the full chain in code. (1) Dangling references are reachable: when device A deletes a SavedLocation, SavedLocationsView.deleteLocation cleans local profile rules via removeLocationFromProfiles (SavedLocationsView.swift:196-213) but never pushes the updated profiles and never bumps profile.updatedAt, while the location deletion itself IS synced (profileSyncManager.deleteLocation, line 181). On device B, pull-side reconciliation deletes the local SavedLocation via SavedLocation.delete (SyncCoordinator.swift:490-494), which is just context.delete + save (SavedLocation.swift:109-112) with NO profile-reference cleanup — leaving device B's profile.geofenceRule with a dangling savedLocationId. (2) The rule is not bypassed: hasLocations checks locationReferences, not resolvable locations (GeofenceRule.swift:78-80). (3) checkGeofenceRule skips unresolvable references with `continue` (LocationManager.swift:128-130), so for an `.outside` rule with one dangling ref, unsatisfiedLocations.count is 0 while rule.locationReferences.count is 1; line 160's equality can never hold, and the failure message at lines 163-164 joins the empty satisfiedLocations into 'You must leave  to stop this profile.' — exactly the claimed permanent, garbled denial. The `.within` variant with all refs dangling likewise fails forever at lines 151-155 with 'You must be within  to stop this profile.'. (4) All stop paths route through this evaluation: StrategyManager.swift:287 and :438 call evaluateGeofenceForStop, GeofenceEvaluator.checkGeofenceAndStop handles the foreground stop (GeofenceEvaluator.swift:73-124), and even emergency unblock hits it when allowEmergencyOverride is false (EmergencyUnblockManager.swift:200-208). Only emergency unblock with the default allowEmergencyOverride=true escapes, matching the claim. The fix sketch (compare against satisfiedLocations.count + unsatisfiedLocations.count, treat fully-unresolvable rules as satisfied) is consistent with the code's stated 'skip references to deleted locations' intent.

## Suggested fix approach

Count only resolvable references: compare unsatisfiedLocations.count against (satisfiedLocations.count + unsatisfiedLocations.count), and treat a rule whose references all fail to resolve as satisfied (or as no-rule), matching the 'skip references to deleted locations' intent.

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
