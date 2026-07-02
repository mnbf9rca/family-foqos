# Handover: Location Restrictions selector is not disabled for locked managed profiles, unlike all other trigger selectors

- **GitHub issue:** #251
- **Severity:** low
- **Domain:** location-nfc-qr
- **Primary location:** `Foqos/Views/BlockedProfileView.swift:363`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

StartTriggerSelector and StopConditionSelector are disabled with `isBlocking || (isManagedProfile && !isUnlockedForEditing)` (BlockedProfileView.swift:337, 377), but BlockedProfileGeofenceSelector (line 359-364) is only disabled by `isBlocking`. On a locked managed profile in Child mode the child can open the GeofencePicker, change rule type/locations/emergency override, and tap Done — the sheet accepts the edits into local @State, but the Save toolbar button is hidden (editingDisabled, line 650), so the changes are silently discarded on dismiss.

## Failure scenario

Child opens a locked managed profile: NFC/QR/schedule triggers appear locked, yet 'Location Restrictions' is fully interactive. The child edits the geofence, taps Done, sees the summary update, closes the profile — and the edit vanishes with no explanation, presenting an inconsistent and misleading lock state.

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, high] Confirmed by reading the code. StartTriggerSelector (line 337) and StopConditionSelector (line 377) pass `disabled: isBlocking || (isManagedProfile && !isUnlockedForEditing)`, but BlockedProfileGeofenceSelector (line 363) passes only `disabled: isBlocking`. There is no Form-level `.disabled(editingDisabled)` or any other guard: the geofence row's buttonAction (line 362) directly sets `showingGeofencePicker = true`, and the sheet (lines 674-679) presents GeofencePicker bound to local @State `geofenceRule` with no lock verification. For a locked managed profile in Child mode, `editingDisabled` (lines 129-133) is true, which hides the Save toolbar button (line 650 `if !editingDisabled`), so any geofence edits the child makes are held in @State and silently discarded on dismiss — exactly the claimed failure scenario. The component itself (BlockedProfileGeofenceSelector.swift:28-37) confirms the button is interactive whenever the passed `disabled` flag is false. Minor caveat: the claim's framing 'unlike ALL other selectors' overstates slightly — several CustomToggles (lines 303, 311, 328, 404, 424) and the app/domain selectors are also only gated by isBlocking, so the lock-gating inconsistency is broader than just the geofence row — but that makes the defect larger, not refuted. Severity 'low' (user-visible inconsistency, no data corruption since edits cannot be saved) is appropriate.

## Suggested fix approach

Pass the same `disabled: isBlocking || (isManagedProfile && !isUnlockedForEditing)` condition to BlockedProfileGeofenceSelector.

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
