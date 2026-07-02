# Handover: Child mode can edit locked SavedLocations without a lock code, defeating geofence restrictions

- **GitHub issue:** #199
- **Severity:** critical
- **Domain:** location-nfc-qr
- **Primary location:** `Foqos/Views/AddLocationView.swift:469`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

SavedLocationsView.handleEdit (Foqos/Views/SavedLocationsView.swift:152-156) opens any location for editing with the comment 'In Child mode, AddLocationView will prevent saving changes to locked locations' — but AddLocationView contains no such guard. saveLocation() (AddLocationView.swift:469-513) calls SavedLocation.update unconditionally; the only lock-related logic is showLockToggle (line 46-48) which merely hides the toggle. The lock toggle's own label promises 'Requires lock code to edit or delete' (line 266), and deletion IS gated (SavedLocationsView.swift:158-166), but editing is not. Since a profile's geofence rule references the location by UUID, moving the location or expanding its radius silently moves the fence for every locked profile using it.

## Failure scenario

Child device in Child mode. Parent creates locked location 'Home' (100m) and a managed profile that can only be stopped 'within Home', started on a schedule. Before the scheduled session starts (the in-use guard only disables the card while a session is active), the child opens Settings -> Saved Locations -> taps locked 'Home' -> moves the pin to school (or sets radius to 3.2 km) -> Save succeeds with no lock-code prompt. When the session activates, the child stops the profile from anywhere inside the moved/expanded fence — the parental geofence restriction is bypassed without ever entering the code.

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, high] Attempted to refute by checking every layer that could supply the missing guard: (1) AddLocationView itself — no isLocked/child-mode check anywhere; showLockToggle only hides the Parent Controls toggle, and saveLocation() updates the model unconditionally; (2) the tap path — SavedLocationCard disables the card only when a profile with an ACTIVE session uses the location, not for locked locations, so a child can edit before/after sessions; (3) the model layer — SavedLocation.update applies all fields with no lock validation; (4) reachability — SettingsView presents SavedLocationsView unconditionally in all app modes, so Child mode reaches it. Meanwhile deletion of the same locked location IS gated behind LockCodeEntryView in handleDelete, and the toggle label explicitly promises "Requires lock code to edit or delete" — so the missing edit gate contradicts both the in-code comment in handleEdit and the stated product behavior (AGENTS.md: Child mode is 'Blocked by Locked Items'). The failure scenario works end-to-end: geofence enforcement (LocationManager.checkGeofenceRule) reads latitude/longitude/defaultRadiusMeters live from the SavedLocation by UUID, so moving the pin or expanding the radius silently moves the fence for locked profiles referencing it. Minor caveat only: radius expansion is neutralized if the profile reference sets a custom radius override, but pin-moving always works. The defect is real and the severity assessment (child-mode lock-code bypass of geofence restrictions) is accurate.

> [real=true, high] Reproduced the full chain in code. In Child mode: Settings (SettingsView.swift:81-83, no mode gate) -> Saved Locations -> tap locked location (SavedLocationCard only disables when a profile has an ACTIVE session using it, per SavedLocationsView.swift:24-39; isLocked never disables the card) -> handleEdit opens AddLocationView unconditionally, relying on a guard its own comment claims exists in AddLocationView -> AddLocationView contains zero child-mode/isLocked enforcement: showLockToggle only hides the lock toggle UI; Save is gated solely by canSave (name/location/duplicate); saveLocation() calls SavedLocation.update unconditionally, which writes name/lat/long/radius and saves, then pushes via ProfileSyncManager. Deletion of the same locked location IS gated by LockCodeEntryView (handleDelete), and the toggle label explicitly promises 'Requires lock code to edit or delete' — so the missing edit gate is a genuine defect, not a design choice. Since geofence rules reference locations by savedLocationId, a child can move the pin or expand the radius to 3km before a scheduled session starts, then stop the locked profile from anywhere inside the moved fence without ever entering the lock code. Per AGENTS.md, lock verification prompts should appear in Child mode for locked items being edited or deleted; only delete implements it. The claim is confirmed as written.

## Suggested fix approach

In AddLocationView, when editingLocation?.isLocked == true and AppModeManager.shared.currentMode == .child, require LockCodeEntryView before enabling Save (mirror handleDelete in SavedLocationsView), or disable Save/fields outright as the comment claims.

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
