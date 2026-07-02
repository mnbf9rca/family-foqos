# Handover: StopProfileIntent (Siri/Shortcuts) bypasses the profile's configured stop conditions

- **GitHub issue:** #261
- **Severity:** high
- **Domain:** widgets-extensions
- **Primary location:** `Foqos/Utils/StrategyManager.swift:396`
- **Status:** DISPUTED (verifiers split — investigate before implementing)
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

stopSessionFromBackground (called by StopProfileIntent) checks only disableBackgroundStops and the geofence rule before calling ManualBlockingStrategy.stopBlocking. It never calls StartStopActionResolver.canStop, unlike the deep-link stop path (toggleSessionFromDeeplink, StrategyManager.swift:255-267) and the NFC/QR stop paths (stopWithNFCTag/stopWithQRCode, lines 886/917), which validate stop conditions. A profile whose stopConditions are NFC-only, QR-only, or timer-only (the app UI shows 'This profile can only be stopped when the timer runs out' / 'scan the tag') can be ended instantly from Shortcuts with zero friction, defeating the commitment-device design.

## Failure scenario

User creates a profile that can only be stopped by scanning a specific NFC tag (or only when its timer expires), starts a session, then says 'Hey Siri, stop <profile>' or runs a Shortcuts automation -> session stops immediately without scanning anything, even though every in-app path refuses.

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=false, medium] The code facts are accurate — stopSessionFromBackground never calls StartStopActionResolver.canStop — but this is intended design, not a defect. Background (Shortcuts/Siri) stops are a deliberately orthogonal channel gated by a dedicated per-profile safeguard, `disableBackgroundStops`, exposed in the profile editor's Safeguards section with a description that explicitly tells users shortcuts can stop the profile unless the toggle is on. The stop-conditions model has no shortcuts/background member and StopMethod has no shortcut case, so there is nothing in the conditions vocabulary this path was ever meant to validate; the deep-link path checks canStop(.deepLink) only because deepLink is itself an explicit stop condition. The start side is symmetric (startSessionFromBackground uses forceStart: true, bypassing all start triggers) and the project's as-designed docs document both behaviors as intended, naming disableBackgroundStops as the protection against unauthorized Shortcut-based unblocking. The project's own deviation report audited stopSessionFromBackground, flagged lock-code and geofence gaps (geofence since fixed in the current code), demonstrated awareness of canStop, and did not flag stop-condition bypass. The proposed fix (canStop(.manual)) would break documented behavior for users who intentionally keep background stops enabled on scan-only profiles. Residual issue is only a UX copy inconsistency ("can only be stopped when the timer runs out"), not a high-severity blocking bypass. Confidence is medium because this is a design-intent judgment: the commitment-device messaging genuinely conflicts with the default-off safeguard, so one could argue for a design gap, but it is not a code defect against the documented design.

> [real=true, high] Reproduced the full chain in code: (1) a profile with timer-only/NFC-only stopConditions is refused a manual stop in-app (HomeView.handleStopTap → determineStopAction → .cannotStop) and via deep link/NFC/QR (all call StartStopActionResolver.canStop); (2) StopProfileIntent (Siri/Shortcuts) calls stopSessionFromBackground, which validates only disableBackgroundStops and geofence, never stopConditions, and directly executes ManualBlockingStrategy.stopBlocking; (3) disableBackgroundStops defaults to false, so the bypass works on a default-configured commitment profile. The claimed scenario — "Hey Siri, stop <profile>" instantly ends an NFC-only/timer-only session — holds exactly as described. The disableBackgroundStops toggle is an opt-in partial mitigation but does not make the paths consistent with the stop-condition design enforced everywhere else.

## Suggested fix approach

In stopSessionFromBackground, run StartStopActionResolver.canStop(with: .manual /* or a new .background method */, conditions: profile.stopConditions, ...) and throw a new IntentError when denied, matching the deep-link path.

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
