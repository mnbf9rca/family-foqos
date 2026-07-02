# Handover: App-group key migration clobbers newer values written by extensions before first app launch

- **GitHub issue:** #217
- **Severity:** high
- **Domain:** cross-cutting
- **Primary location:** `Foqos/Utils/UserDefaultsMigration.swift:58`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

migrateAppGroupIfNeeded() unconditionally copies each legacy app-group key over the new prefixed key (`defaults.set(value, forKey: new)` at Foqos/Utils/UserDefaultsMigration.swift:58) and only runs in the main app (FoqosApp.init, FoqosApp.swift:102). Meanwhile the FoqosDeviceMonitor extension and FoqosWidget write through SharedData, whose setters write ONLY the new keys and never clear the legacy keys (SharedData.swift:358-364 for activeScheduleSession, :342-348 for completedScheduleSessions), while its getters fall back to legacy keys (SharedData.swift:120-133). SharedData.swift:108-110 explicitly documents that extensions may run before the app migrates — but only the read path was handled, not the write path, so the app-side migration can later overwrite fresh extension-written state with stale legacy values.

## Failure scenario

User on the pre-rename app version has a schedule-based profile with an active session (legacy key "activeScheduleSession" holds the session). The app updates via the App Store overnight. The DeviceActivity schedule interval ends before the user opens the app: DeviceActivityMonitorExtension.intervalDidEnd -> ScheduleTimerActivity.stop (ScheduleTimerActivity.swift:88-110) deactivates restrictions and calls SharedData.endActiveSharedSession(), which appends the completed session under the NEW key and removes only the NEW active-session key — the legacy "activeScheduleSession" still holds the session. The user then opens the app: migrateAppGroupIfNeeded() copies the stale legacy session over the new key, resurrecting the already-ended schedule session as 'active' (app UI shows blocking active while ManagedSettings restrictions are off), and overwrites the new-key completedScheduleSessions list with the legacy list, permanently losing the just-completed session record (missing from stats/insights and session sync).

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, high] Every link in the claimed chain is confirmed by code. The app-group migration (main-app-only, FoqosApp.swift:102) copies each legacy key over the new key unconditionally, guarded only by a one-time flag that is unset until the first launch after update. Meanwhile the FoqosDeviceMonitor extension can run in that window (DeviceActivity schedules persist across updates; the code comment at SharedData.swift:108-110 explicitly anticipates this) and writes ONLY the new keys via SharedData setters, which never remove the legacy keys. Concretely, intervalDidEnd → ScheduleTimerActivity.stop deactivates restrictions and endActiveSharedSession() appends the completed session under the new completedScheduleSessions key and removes only the new activeScheduleSession key; the legacy "activeScheduleSession" still holds the session. On first app launch the migration then copies that stale legacy session over the new key (resurrecting an already-ended session as active while restrictions are off) and copies the legacy completed-sessions list over the new list (losing the just-completed session, when a legacy completed list existed pre-update). I attempted refutation: no guard in the migration, no migration call in extensions, no legacy-key cleanup anywhere in SharedData, and the extension-before-first-launch window is real and acknowledged in the code. The fix sketch (copy old→new only when the new key is absent; have setters also remove legacy keys) is correct. Severity high is justified: wrong blocking state shown to the user and permanent loss of a session record on the upgrade path the migration was written to support.

> [real=true, high] Reproduced the full failure chain in the code as written. (1) The pre-rename app stored the active schedule session under legacy unprefixed key "activeScheduleSession" (verified in git history at c1c9d2b^, Foqos/Models/Shared.swift). (2) After an overnight App Store update, if the DeviceActivity interval ends before first app launch, DeviceActivityMonitorExtension.intervalDidEnd → TimerActivityUtil.stopTimerActivity → ScheduleTimerActivity.stop finds the session via SharedData's legacy-fallback getter, deactivates ManagedSettings restrictions, and calls endActiveSharedSession(), which appends the completed session under the NEW prefixed key and clears only the NEW active key — the legacy "activeScheduleSession" value (still lacking endTime) is never removed, because SharedData setters write only new keys. (3) On first app launch, migrateAppGroupIfNeeded() (called only from FoqosApp.init) unconditionally copies every existing legacy value over the new key: the stale "active" session resurrects over the new active-session key, and the stale legacy completedScheduleSessions list overwrites the new list containing the just-completed session. (4) StrategyManager.syncScheduleSessions then upserts the phantom session as active in SwiftData (UI shows blocking active while restrictions are off) and even pushes a session-start to CloudKit sync, while the real completed-session record is permanently lost from getAndFlushCompletedSessionsForScheduler. Every step holds; the code comment at SharedData.swift:108-110 shows the pre-migration extension window was known but only the read path was handled. The proposed fix (copy old→new only when new key is absent, plus clearing legacy keys on write) is correct.

## Suggested fix approach

In migrateAppGroupIfNeeded(), only copy old->new when the new key is absent: `if defaults.object(forKey: new) == nil, let value = defaults.object(forKey: old) { defaults.set(value, forKey: new) }; defaults.removeObject(forKey: old)`. Additionally (belt and braces) have SharedData setters remove the legacy key on every write so legacy values can never shadow or resurrect state.

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
