# Handover: Setting a lock code in Individual mode claims to make the device a parent device but never switches the mode

- **GitHub issue:** #244
- **Severity:** low
- **Domain:** family-lockcode
- **Primary location:** `Foqos/Views/Components/LockCodeEntryView.swift:316`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

LockCodeSetupView displays 'This makes your device a parent device' (LockCodeEntryView.swift:316) and LockCodeManager.setLockCode permits Individual mode (guard is only against .child, LockCodeManager.swift:70), but no code path calls appModeManager.selectMode(.parent) when a code is set — selectMode(.parent) only ever happens via share acceptance (FoqosApp.swift:500) or CloudKit mode enforcement. Per the AGENTS.md mode table, Individual mode should have no lock code and cannot create locked items; showManagedToggle requires currentMode == .parent (BlockedProfileView.swift:139).

## Failure scenario

An Individual-mode user opens Settings > Family Controls Dashboard and sets a lock code. The card flips to 'Lock Code Set — active and shared with all parents', but the device remains in Individual mode: no 'Parent-Controlled' toggle ever appears on any profile and no parent-mode behavior activates, contradicting both the on-screen promise and the documented mode table.

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, high] Every factual element of the claim checks out and no refuting mechanism exists. The setup sheet promises "This makes your device a parent device" (LockCodeEntryView.swift:316), but the only caller of LockCodeSetupView (ParentDashboardView.swift:161-176) just calls lockCodeManager.setLockCode() in onSave — no selectMode(.parent). setLockCode permits Individual mode (LockCodeManager.swift:70 guards only against .child; line 68 comment confirms Individual-mode use is intentional). I searched for any indirect promotion path: selectMode(.parent) occurs only via share acceptance (FoqosApp.swift:499-500, invitees only) and CloudKit enforcedMode (CloudKitManager.swift:201-202). The enforced-mode path requires a FamilyMember record in the SHARED database zone, which only share participants have; the share owner is explicitly excluded from participant sync (CloudKitNetworkService+Sharing.swift:194-196 filters `$0.role != .owner`), so the Individual-mode owner who sets the code is never promoted. AppMode.currentMode is stored, not derived (AppMode.swift:57-85), so nothing computes parent-ness from hasAnyLockCode. Consequence confirmed: the "Parent-Controlled" toggle requires currentMode == .parent (BlockedProfileView.swift:139, AddLocationView.swift:47), so the user gets none of the promised parent behavior. Corroborating: ModeSelectionView.swift:15 comment says "Parent mode can be activated later from Settings > Family Controls Dashboard" but no code in the dashboard activates it, and LockCodeManager.swift:456-458 (canCreateManagedProfiles: != .child) contradicts the == .parent gate in the views. This is a genuine mode/UI inconsistency; severity low is fair since lock codes set in Individual mode still sync to and function on child devices.

## Suggested fix approach

Either call appModeManager.selectMode(.parent) after a successful first setLockCode from the dashboard, or reword the setup copy and restrict code creation to parent mode per the AGENTS.md table.

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
