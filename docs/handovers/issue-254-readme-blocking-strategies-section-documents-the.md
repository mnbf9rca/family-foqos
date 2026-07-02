# Handover: README 'Blocking Strategies' section documents the removed V1 strategy-selection system as current behavior

- **GitHub issue:** #254
- **Severity:** low
- **Domain:** structural-debt
- **Primary location:** `README.md:115`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

Commit 41ff702 'replace blocking strategy system with V2 trigger-based profiles' removed user-facing strategy selection; profiles are now configured via ProfileStartTriggers/ProfileStopConditions, and strategy classes survive only as legacy-compat shims routed through StartStopActionResolver (V2 paths always pass bypassStrategy and use ManualBlockingStrategy, StrategyManager.swift:833-836, 971-974). README lines 27-28 ('Mix & Match Strategies: Manual, NFC, QR, NFC + Manual, ...') and the whole section at lines 115-156 describe picking these seven strategies per profile, including setting physicalUnblockNFCTagId/physicalUnblockQRCodeId, which V2 replaced with startNFCTagId/stopNFCTagId etc.

## Failure scenario

A new user or contributor reads the README, looks for the documented strategy picker (e.g., 'NFC + Timer strategy') in the app or code, finds no such UI, and configures/expects behavior (physicalUnblock* fields) that new V2 profiles never use — user-visible inconsistency between docs and shipped behavior.

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, high] The README's 'Blocking Strategies' section (lines 115-156) and feature bullet (line 28) document a user-selectable seven-strategy system and physicalUnblockNFCTagId/physicalUnblockQRCodeId fields as current behavior, but commit 41ff702 replaced this with V2 trigger-based profiles. Verified: (a) no strategy-picker UI exists anywhere in Foqos/Views or Foqos/Components — BlockedProfileView hard-codes blockingStrategyId (nil on update, NFCBlockingStrategy.id on create), so users cannot choose 'NFC + Timer' etc.; (b) StrategyManager comments explicitly call the strategy classes 'legacy strategies' bypassed by the V2 trigger system via ManualBlockingStrategy; (c) BlockedProfiles.swift labels blockingStrategyId 'Version 1: Legacy' and V2 uses startNFCTagId/stopNFCTagId; (d) TriggerMigration.swift converts physicalUnblock* fields into V2 stop conditions, and no UI edits them (only DebugView displays them). A reader following the README would look for a strategy picker and physicalUnblock configuration that no longer exist. Severity is correctly low (documentation only), but the finding is accurate.

## Suggested fix approach

Rewrite the section around start triggers / stop conditions and mark the strategy classes as legacy V1 migration compatibility only (issue #59 already tracks removing the field).

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
