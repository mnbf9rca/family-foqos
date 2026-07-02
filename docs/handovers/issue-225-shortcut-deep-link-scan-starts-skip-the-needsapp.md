# Handover: Shortcut/deep-link/scan starts skip the needsAppSelection check, creating an 'active' session that blocks nothing

- **GitHub issue:** #225
- **Severity:** medium
- **Domain:** strategies-session
- **Primary location:** `Foqos/Utils/StrategyManager.swift:376`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

startRemoteSession refuses to start a profile with needsAppSelection == true (line 1117-1122), because profiles synced from another device carry no local FamilyActivitySelection tokens. But startSessionFromBackground (App Intents/Shortcuts, lines 354-381), toggleSessionFromDeeplink (lines 306-323), and startWithTag (line 942) all start such profiles anyway: activateRestrictions is called with an empty snapshot selection, so nothing is actually restricted while the app, widget, and Live Activity all report an active focus session.

## Failure scenario

User's profile 'Homework' syncs to a second device where apps were never re-selected (needsAppSelection = true). A Shortcut automation or NFC deep link starts 'Homework' on that device: a session is created, the UI shows blocking active, but zero apps are blocked — silent no-op blocking that the user believes is enforced.

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, high] Verified all three cited entry points (startSessionFromBackground via StartProfileIntent, toggleSessionFromDeeplink via HomeView deep-link handler, startWithTag via startWithNFCTag/startWithQRCode) create sessions and call activateRestrictions without checking profile.needsAppSelection. A repo-wide grep confirms no upstream or downstream compensating guard — the only enforcement points are the startRemoteSession guard at line 1117 and passive UI banners. Profiles synced from another device are created with needsAppSelection=true and an empty FamilyActivitySelection (tokens are device-local and not synced), so activateRestrictions assigns empty shield token sets and blocks no apps while a session is created and reported active. This exactly matches the claimed failure scenario. Minor caveats: synced web domains would still be filtered, and allow-mode profiles would over-block rather than no-op, but both remain wrong blocking behavior; severity medium is appropriate.

## Suggested fix approach

Add the same needsAppSelection guard (with errorMessage / IntentError) to startSessionFromBackground, toggleSessionFromDeeplink, and startWithTag before creating a session.

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
