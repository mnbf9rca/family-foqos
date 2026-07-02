# Handover: Duplicated (cloned) profile never gets a SharedData snapshot, so its schedule fires into a nil profile and does nothing

- **GitHub issue:** #209
- **Severity:** high
- **Domain:** views-primary
- **Primary location:** `Foqos/Views/BlockedProfileView.swift:730`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

The 'Duplicate Profile' flow calls BlockedProfiles.cloneProfile() then DeviceActivityCenterUtil.scheduleTimerActivity(for: clonedProfile) (BlockedProfileView.swift:726-731). cloneProfile (Foqos/Models/BlockedProfiles.swift:636-684) copies all V2 trigger data and saves the context but never calls updateSnapshot(for: cloned) — unlike createProfile which snapshots explicitly 'so extensions can read it immediately' (BlockedProfiles.swift:628-630). scheduleTimerActivity registers the DeviceActivity from the model, but when the interval fires the extension resolves the profile via SharedData.snapshot(for:) (TimerActivityUtil.swift:61-63) which returns nil for the clone, so startTimerActivity guards out silently.

## Failure scenario

User duplicates a schedule-based profile ('School Hours Copy'). The DeviceActivity for the clone fires at the scheduled start, TimerActivityUtil.getProfile returns nil (no snapshot in the app group), and blocking never starts for the cloned profile — with no error shown. Also the clone is never pushed to CloudKit sync until its first manual edit.

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, high] I tried to refute this and could not. cloneProfile (BlockedProfiles.swift:636-684) inserts and saves the clone but never calls updateSnapshot, unlike createProfile which does so explicitly "so extensions can read it immediately". The clone flow (BlockedProfileView.swift:726-731) then registers a DeviceActivity schedule for the clone. When that interval fires, the DeviceActivityMonitor extension (a separate process with no SwiftData access here) resolves the profile exclusively via SharedData.snapshot(for:) in the app-group UserDefaults; with no snapshot present, TimerActivityUtil.startTimerActivity guards out silently and blocking never starts. I verified every updateSnapshot call site in the codebase — none fires for a freshly cloned profile (sync handlers only snapshot remote-originated profiles, and the clone is never pushed to CloudKit since pushProfile is only called from saveProfile). The clone also gets a fresh UUID, so the source's snapshot cannot mask the bug. The only partial mitigation, catchUpMissedScheduleStarts, runs on app foreground and reads the model directly — it does not fix the background schedule fire, which is the primary purpose of a schedule trigger. The secondary claim (clone not pushed to CloudKit until first manual save) is also correct. Both the missing-snapshot and missing-push halves of the finding are confirmed against concrete code.

> [real=true, high] Every step of the claimed chain reproduces in the code as written. (1) The Duplicate flow calls cloneProfile then scheduleTimerActivity (BlockedProfileView.swift:727-730). (2) cloneProfile (BlockedProfiles.swift:636-684) copies schedule and all V2 trigger fields and saves, but never calls updateSnapshot — in contrast to createProfile (line 629, with the explicit comment 'Create the snapshot so extensions can read it immediately') and updateProfile (line 462). (3) The ONLY writer of SharedData snapshots is BlockedProfiles.updateSnapshot (BlockedProfiles.swift:541); I enumerated all its call sites — SyncCoordinator (remote-pull/apply paths at 262, 315, 542, not triggered by a local clone; the clone is also never pushed, since pushProfile is only called from the save path at BlockedProfileView.swift:864, and cloneProfile resets syncVersion to 0), StrategyManager 365/540 and BlockedProfileSessions:91 (session lifecycle, requires a session to have started), and NFC/QR timer strategies (session start). None run for a freshly cloned profile. (4) scheduleTimerActivity registers the DeviceActivity from the live model, so monitoring IS scheduled for the clone. (5) When the interval fires, DeviceActivityMonitorExtension.intervalDidStart (line 34) calls TimerActivityUtil.startTimerActivity, which resolves the profile solely via SharedData.snapshot(for:) (TimerActivityUtil.swift:61-62); with no snapshot the guard at lines 7-11 returns silently and blocking never starts, with no user-visible error. The extension has no SwiftData fallback. The only mitigation is PreActivationReminderScheduler.catchUpMissedScheduleStarts (line 37-59), which rebuilds a snapshot from the model — but it runs only when the main app is foregrounded during the active window, so the primary background schedule-fire (the whole point of scheduled blocking) fails silently until the user opens the app or manually edits/starts the clone. The claimed defect, failure scenario, and the secondary 'never pushed to CloudKit until first edit' point are all real.

## Suggested fix approach

Call updateSnapshot(for: cloned) at the end of cloneProfile (after trigger data is copied), and optionally SyncCoordinator.shared.pushProfile(cloned) in the clone flow.

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
