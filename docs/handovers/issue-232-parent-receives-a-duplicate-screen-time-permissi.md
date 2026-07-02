# Handover: Parent receives a duplicate 'Screen Time Permissions Lost' notification on every heartbeat refresh

- **GitHub issue:** #232
- **Severity:** medium
- **Domain:** family-lockcode
- **Primary location:** `Foqos/Utils/HeartbeatManager.swift:145`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

scheduleNotification(for:) fires the auth-revoked notification with triggerDate = Date()+1 unconditionally whenever the device isAuthRevoked, with no flag recording that the parent was already alerted. refreshHeartbeats() calls scheduleNotifications() on every invocation when notifications are enabled (HeartbeatManager.swift:82-85), and refreshHeartbeats runs on every CloudKit remote push while in parent mode (FoqosApp.swift:353-356) and on every ParentDashboardView .task/pull-to-refresh (ParentDashboardView.swift:797-799). cancelNotification only removes the still-pending previous request; the already-delivered ones accumulate.

## Failure scenario

A child device reports authorizationStatus "denied". From then on, every profile-sync push notification and every open/refresh of the parent dashboard delivers another immediate 'Screen Time Permissions Lost' banner to the parent — potentially dozens per day for the same unchanged condition — until the parent suppresses or removes the device.

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, high] The defect is confirmed by direct code reading. scheduleNotification(for:) fires an immediate (Date()+1) 'Screen Time Permissions Lost' notification unconditionally whenever device.isAuthRevoked, with no state tracking that the parent was already alerted. isAuthRevoked is a pure computed property (authorizationStatus == "denied") that stays true across refreshes, and updateOrCreateDevice simply overwrites authorizationStatus without any transition detection. refreshHeartbeats() calls scheduleNotifications() on every invocation when notifications are enabled, and it is invoked on every CloudKit remote push in parent mode (FoqosApp.swift:354-356) and on every ParentDashboardView load/pull-to-refresh (ParentDashboardView.swift:797-798). cancelNotification only removes PENDING requests; since the immediate notification delivers 1 second after scheduling, it is no longer pending by the next refresh, and re-adding a request with the same identifier re-presents a banner+sound (NotificationDelegate presents [.banner, .sound] even in foreground). The only escapes are manual suppression or device removal, matching the failure scenario. Minor caveat: reused identifier means delivered notifications replace rather than accumulate in Notification Center, but each delivery still produces a fresh banner/sound, so the repeated-alert defect is real. Severity 'medium' is reasonable for a notification-spam UX bug.

## Suggested fix approach

Track an 'authRevokedNotifiedAt' timestamp on MonitoredDevice and only fire the immediate notification when the status transitions to denied (or after a cooldown), resetting when a heartbeat reports approved again.

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
