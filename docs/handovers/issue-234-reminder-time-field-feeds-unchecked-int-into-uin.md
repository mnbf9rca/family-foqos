# Handover: Reminder-time field feeds unchecked Int into UInt32(), crashing on large or negative input at save

- **GitHub issue:** #234
- **Severity:** medium
- **Domain:** views-primary
- **Primary location:** `Foqos/Views/BlockedProfileView.swift:883`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

saveProfile computes `enableReminder ? UInt32(reminderTimeInMinutes * 60) : nil`. reminderTimeInMinutes is a free-form Int bound to `TextField(value:format:.number)` (lines 475-480). The number-pad keyboard doesn't stop hardware-keyboard or paste input, and there is no range clamp anywhere. UInt32(_:) traps for values > 4,294,967,295 or negative values, so any reminder value above 71,582,788 minutes (an 8-9 digit typo) or a pasted negative number crashes the app instead of showing a validation error.

## Failure scenario

User enables Reminder and types 100000000 into the minutes field (or pastes '-15' via an iPad hardware keyboard), taps the checkmark to save → 100000000 * 60 = 6,000,000,000 doesn't fit UInt32 → 'Not enough bits to represent the passed value' fatal error; the app crashes and the profile edits are lost.

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, high] reminderTimeInMinutes is an unclamped Int @State bound to a free-form number TextField; the only other references in the codebase are its declaration, init, and the UInt32 conversion at save. UInt32(_: Int) traps for negative or >4,294,967,295 inputs, and reminderTimeInMinutes >= 71,582,789 (a 9-digit value typeable on the plain number pad, no minus key required) makes minutes*60 exceed UInt32.max, crashing saveProfile before any persistence. No clamp, guard, or validation exists anywhere (triggerConfig.validate() covers only trigger config; the adjacent customReminderMessage field has an onChange clamp but the minutes field does not). LENS 1 refutation attempts failed: the code path is reachable on save and unguarded.

## Suggested fix approach

Clamp/validate before converting, e.g. `let minutes = max(1, min(reminderTimeInMinutes, 1440)); UInt32(minutes * 60)`, or use UInt32(exactly:) and surface a validation error.

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
