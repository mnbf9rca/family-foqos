# Handover: Cloning an unmigrated V1 profile stamps the clone as schema V2 with all-false triggers, producing a profile that can never start

- **GitHub issue:** #223
- **Severity:** medium
- **Domain:** models-swiftdata
- **Primary location:** `Foqos/Models/BlockedProfiles.swift:673`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

BlockedProfiles.init unconditionally sets profileSchemaVersion = currentSchemaVersion (2) (BlockedProfiles.swift:300). cloneProfile copies source.startTriggers/stopConditions (line 673-674), which for an unmigrated V1 source decode from nil data into all-false defaults, and re-encodes them into the clone. The clone carries the source's blockingStrategyId but is marked V2, so needsMigration is false and TriggerMigration will never translate the strategy into triggers. StartStopActionResolver.determineStartAction returns .cannotStart when stopConditions.isValid is false (Foqos/Utils/StartStopActionResolver.swift:47-49). Unmigrated V1 profiles are reachable: sync from a V1 device creates local profiles at schemaVersion 1 (SyncCoordinator.createLocalProfile line 311), and ProfileMigrationUtil only runs at app launch / session end.

## Failure scenario

A V1 profile syncs in from a device still on v1.x (or migration was deferred), then the user taps Duplicate Profile before the next app launch. The clone is schemaVersion 2 with startTriggers and stopConditions all false; tapping it yields 'No stop conditions configured. Edit the profile to add one.' — the duplicated NFC/QR/timer strategy behavior is silently lost and no future migration pass will repair it.

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, high] Every load-bearing claim checks out in the code. BlockedProfiles.init unconditionally stamps profileSchemaVersion=2; cloneProfile copies source.startTriggers/stopConditions, which for an unmigrated V1 source (nil startTriggersData/stopConditionsData) decode to all-false defaults and are re-encoded into the clone. The clone keeps blockingStrategyId but reports needsMigration=false, so ProfileMigrationUtil, StrategyManager's post-session migration, and migrateToV2IfNeeded (guard profileSchemaVersion < 2) all permanently skip it. HomeView's start path feeds the all-false stopConditions to StartStopActionResolver.determineStartAction, which returns .cannotStart with exactly the claimed message; there is no blockingStrategyId fallback for schema-2 profiles. The precondition (an unmigrated V1 profile existing at duplicate time) is reachable: SyncCoordinator.createLocalProfile preserves synced.profileSchemaVersion (=1 from a v1.x device) with nil trigger data, migration passes run only at app launch / StrategyManager.loadApp / session end (never on sync arrival), and the Duplicate menu is available for such a profile whenever no session is blocking. Attempted refutations failed: BlockedProfileView.onAppear only populates a display-side TriggerConfigurationModel without mutating the model; the trigger getters have no V1 compat layer. The one partial mitigation — Duplicate is hidden while any session is active (isBlocking is global) — blocks only the deferred-active-session sub-scenario, not the sync-from-V1-device scenario. Severity medium is appropriate: the clone is silently non-functional but user-repairable by manually editing its triggers.

## Suggested fix approach

In cloneProfile, either copy source.profileSchemaVersion and let the normal migration path handle the clone, or call cloned.migrateToV2IfNeeded() when the source is V1 before saving.

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
