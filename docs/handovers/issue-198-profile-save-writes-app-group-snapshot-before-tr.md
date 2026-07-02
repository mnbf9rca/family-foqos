# Handover: Profile save writes app-group snapshot before trigger/schedule edits are applied, so scheduled blocking never starts in the background

- **GitHub issue:** #198
- **Severity:** critical
- **Domain:** views-primary
- **Primary location:** `Foqos/Views/BlockedProfileView.swift:856`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

saveProfile() calls BlockedProfiles.updateProfile()/createProfile(), which write the SharedData ProfileSnapshot (Foqos/Models/BlockedProfiles.swift:462 and :629) BEFORE finalizeSave() runs triggerConfig.saveToProfile(profile) (BlockedProfileView.swift:856), which is what actually writes startTriggers/stopConditions/startSchedule/stopSchedule onto the model. Nothing afterwards re-runs updateSnapshot (finalizeSave only does context.save, scheduleTimerActivity, pushProfile — none snapshot). The FoqosDeviceMonitor extension enforces schedules purely from that snapshot: TimerActivityUtil.getProfile reads SharedData.snapshot (Packages/FoqosShared/Sources/FoqosShared/Timers/TimerActivityUtil.swift:61-63) and ScheduleTimerActivity.start() returns without blocking when snapshot.startTriggersSchedule != true and snapshot.startSchedule/schedule are nil (ScheduleTimerActivity.swift:48-70, logs 'no schedule found'). The snapshot is only refreshed later by StrategyManager.activateSession (session start) or an inbound sync update — neither happens for a schedule-triggered profile waiting for its first activation.

## Failure scenario

Parent creates (or edits) a profile with a Schedule start trigger 21:00-07:00 on the child's device and closes the app. The DeviceActivity interval is registered correctly from the model, but at 21:00 the extension reads the stale snapshot (startTriggersSchedule=false / startSchedule=nil captured before finalizeSave), logs 'no schedule found', and returns — no restrictions are ever applied. The scheduled blocking silently never activates until the app is foregrounded (catchUpMissedScheduleStarts) or a session is started some other way.

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, high] Attempted to refute on every plausible axis and failed. (1) Ordering is exactly as claimed: updateProfile/createProfile write the app-group ProfileSnapshot (BlockedProfiles.swift:462/629) before finalizeSave's triggerConfig.saveToProfile (BlockedProfileView.swift:856) writes startTriggers/startSchedule onto the model — trigger edits are staged in a separate TriggerConfigurationModel @StateObject, not bound to the model, so the snapshot cannot see them. (2) Nothing in finalizeSave re-snapshots: context.save() persists the model (not the snapshot), DeviceActivityCenterUtil.scheduleTimerActivity reads the model and registers the DeviceActivity interval correctly but contains zero snapshot writes, and SyncCoordinator.pushProfile only bumps syncVersion and pushes to CloudKit. (3) The FoqosDeviceMonitor extension enforces purely from the snapshot (TimerActivityUtil.getProfile -> SharedData.snapshot), and ScheduleTimerActivity.start returns without blocking when the snapshot lacks startTriggersSchedule/startSchedule and legacy schedule (logs 'no schedule found'). For a newly created scheduled profile the snapshot has defaults (no schedule); for an edited profile it has the pre-edit trigger state. (4) No guard elsewhere heals it before first activation: the other updateSnapshot call sites are session activation (chicken-and-egg — the extension is what should start the session), inbound sync (guarded by version > local, and the editing device pre-increments its version so its own pushed record loops back as equal and is skipped), session end, and sync reset. catchUpMissedScheduleStarts masks the bug only when the app is foregrounded during the window, and even then builds a transient snapshot without persisting it. The failure scenario — DeviceActivity interval fires at 21:00 with the app backgrounded, extension reads stale snapshot, no restrictions applied — follows directly from the confirmed code paths. Severity as claimed: scheduled blocking silently fails in the background right after profile creation/edit, which is core functionality for a parental-control app.

> [real=true, high] Independently traced the full chain. saveProfile() calls createProfile/updateProfile with schedule:nil; both write the app-group ProfileSnapshot internally (BlockedProfiles.swift:629/:462) before finalizeSave() runs triggerConfig.saveToProfile (BlockedProfileView.swift:856), which is the sole writer of startTriggers/startSchedule/stopSchedule onto the model. For a new profile the snapshot therefore has startTriggersSchedule=false, startSchedule=nil, schedule=nil. finalizeSave's remaining steps (context.save, scheduleTimerActivity, pushProfile) do not re-snapshot — verified by reading each and by exhaustive grep of updateSnapshot/setSnapshot callers (only session activation/end, inbound sync apply guarded by version>local so the device's own push cannot heal it, sync reset, and NFC/QR/shortcut strategy paths). scheduleTimerActivity reads the updated model, so the DeviceActivity interval IS registered; but at interval start the FoqosDeviceMonitor extension resolves the profile exclusively via SharedData.snapshot (TimerActivityUtil.swift:61-63) and ScheduleTimerActivity.start() takes the "no schedule found" early return (ScheduleTimerActivity.swift:68-70) when the stale snapshot lacks both V2 and legacy schedules — no restrictions applied, silently. Edits that change schedule times fail similarly (extension keeps old times). Every step of the claimed scenario holds in the code as written; the proposed fix (re-run updateSnapshot in finalizeSave after saveToProfile) matches the root cause.

## Suggested fix approach

In finalizeSave(), call BlockedProfiles.updateSnapshot(for: profile) after triggerConfig.saveToProfile(profile) and modelContext.save() (or move the snapshot write in updateProfile/createProfile to after trigger persistence).

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
