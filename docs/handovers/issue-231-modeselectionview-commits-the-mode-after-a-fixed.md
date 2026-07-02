# Handover: ModeSelectionView commits the mode after a fixed 1-second wait, racing the FamilyControls authorization prompt

- **GitHub issue:** #231
- **Severity:** medium
- **Domain:** family-lockcode
- **Primary location:** `Foqos/Views/ModeSelectionView.swift:124`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

continueWithSelectedMode() calls requestAuthorizer.requestAuthorization(for:) — which spawns an unawaited Task wrapping the async AuthorizationCenter.requestAuthorization call (RequestAuthorizer.swift:46-70) — then checks requestAuthorizer.isAuthorized after a hard-coded DispatchQueue.main.asyncAfter of 1.0s. Child authorization presents a system consent flow that takes far longer than 1 second, and isAuthorized is seeded from the pre-existing AuthorizationCenter status at init.

## Failure scenario

(a) Fresh device, user selects 'Child' and taps Continue: after 1s the system dialog is still up, isAuthorized is false and authorizationError is nil, so neither branch runs — the screen silently does nothing and the user must tap Continue again after approving. (b) Device already holds an approved individual authorization (persists across reinstall): user selects 'Child'; at +1s the stale isAuthorized==true causes selectMode(.child) and onboarding completes in child mode even though the .child authorization request later fails — leaving the device in child mode without child authorization until AuthorizationVerifier later force-reverts it with an 'Authorization Lost' alert.

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, high] The defect is real and confirmed by direct code reading. continueWithSelectedMode() (ModeSelectionView.swift:117-134) fires a non-blocking authorization request (RequestAuthorizer wraps the async AuthorizationCenter call in an unawaited Task) and then decides the outcome after a hard-coded 1.0-second delay. Scenario (a) holds: on a fresh device the interactive system consent flow is still in progress at +1s, so isAuthorized is false and authorizationError is nil — neither branch executes, the spinner stops, and the screen silently does nothing; the user must tap Continue again after approving. Scenario (b) holds: AuthorizationStatus is a single tri-state (.notDetermined/.denied/.approved) with no individual-vs-child distinction, so a device with pre-existing individual approval seeds isAuthorized=true at init; selecting Child then commits selectMode(.child) at +1s regardless of whether the pending .child authorization request succeeds. The only mitigation is AuthorizationVerifier's later verification (FoqosApp.swift:449/538, ChildDashboardView.swift:145), which is exactly the after-the-fact revert the claim already acknowledges — it does not prevent the race. No caller-side guard exists (HomeView.swift:308-312 just dismisses the onboarding cover). The medium severity is appropriate: scenario (a) is a recoverable UX failure, scenario (b) is a transient wrong-mode commit later corrected.

## Suggested fix approach

Make requestAuthorization(for:) async (or completion-based) and await its actual result before calling appModeManager.selectMode; drop the fixed 1s delay.

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
