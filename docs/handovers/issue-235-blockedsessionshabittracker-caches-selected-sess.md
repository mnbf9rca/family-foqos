# Handover: BlockedSessionsHabitTracker caches selected sessions in @State and later dereferences session.blockedProfile — zombie crash after deletion

- **GitHub issue:** #235
- **Severity:** medium
- **Domain:** views-secondary
- **Primary location:** `Foqos/Components/Dashboard/BlockedSessionsHabitTracker.swift:250`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

handleDateTap (line 143) stores `selectedSessions = sessionsForDate(date)` in @State. Unlike the `sessions` parameter (which HomeView refreshes from @SafeQuery on each render), this cached array is never revalidated. sessionRowView (line 250) accesses `session.blockedProfile.name` and sessionDurationForDate on those cached models, and none of the accessors use the `.valid` extension AGENTS.md requires for components holding model arrays. If the sessions (or their profile, cascading to sessions) are deleted while the day-details panel is expanded, the next render dereferences zombie models -> EXC_BREAKPOINT.

## Failure scenario

User taps a day square on the Home screen's 4 Week Activity tracker to expand session details, then deletes that profile (or a remote sync deletion arrives). HomeView re-renders; the tracker's cached selectedSessions still reference the cascade-deleted BlockedProfileSession objects, and sessionRowView's `session.blockedProfile.name` crashes the app.

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, high] The component caches SwiftData model objects in @State at tap time (line 143) and later renders them (lines 225-250) without any revalidation, `.valid` filtering, or SafeModelView wrapping — violating the codebase's own AGENTS.md rule for components holding model arrays. Profile deletion explicitly deletes all its sessions (BlockedProfiles.deleteProfile, lines 481-482), and the user can trigger it while the day-details panel is expanded (edit sheet over HomeView, or remote sync deletion). On the next render the cached zombie sessions are dereferenced (`session.id`, `session.blockedProfile.name`), producing the EXC_BREAKPOINT crash class this codebase has repeatedly fixed elsewhere (SafeQuery, SafeModelView, commit c8930a4). No guard exists in this component or its caller; @State persists across re-renders due to stable view identity. All refutation attempts failed.

## Suggested fix approach

Don't cache model objects in @State — derive sessionsForDate(selectedDate) in body from the fresh `sessions` parameter, or filter with `.valid` (and guard blockedProfile access) before rendering.

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
