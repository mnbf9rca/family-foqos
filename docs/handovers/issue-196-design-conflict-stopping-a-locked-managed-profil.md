# Handover: Design conflict: stopping a locked (managed) profile is un-gated, but ChildDashboardView copy promises the lock code is required to stop

- **GitHub issue:** #196
- **Severity:** low (downgraded 2026-07-02 — copy fix only)
- **Domain:** family-lockcode
- **Primary location:** `Foqos/Views/HomeView.swift:518`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Maintainer decision (2026-07-02) — READ FIRST

The design question is RESOLVED: the as-designed behavior stands. *"Lock code only gates editing profile settings and deleting profiles. Stopping blocking sessions should work identically to unmanaged profiles"* (deviation report #7). **Implement Option B only**: fix the footer copy in `ChildDashboardView.swift:576` to say "edit or delete", and audit for any other copy promising that stopping is gated. Do NOT add lock-code checks to any stop path.

## Problem

A child can stop an active session on a locked (managed) profile with one tap and no lock code: HomeView is the root view in all app modes (FoqosApp.swift:252), the carousel shows every profile with no isManaged filter, and the stop path onStopTapped -> strategyButtonPress -> handleStopTap (HomeView.swift:518) -> StartStopActionResolver.determineStopAction -> strategyManager.toggleBlocking contains no isManaged, child-mode, or lock-code check (verified by grep: zero isManaged hits in HomeView, StrategyManager, or StartStopActionResolver).

HOWEVER, this appears to be intentional: docs/codebase-analysis/deviation-report.md deviation #7 (user-confirmed, 2026-02-09) records the as-designed behavior as 'Lock code only gates editing profile settings and deleting profiles. Stopping blocking sessions should work identically to unmanaged profiles', and the previously existing lock checks on the stop path were removed per that deviation's fix.

The defect that definitely exists today is the contradiction: ChildDashboardView.swift:576 ('Select Profiles to Lock' footer) promises 'Locked profiles require the lock code to edit, delete, or stop.' Either the design has since changed and stopping must be re-gated (making this a real parental-control bypass), or the UI copy (and any similar copy) is wrong and must be fixed. A maintainer decision is required before implementation.

## Failure scenario

Parent sets a lock code and marks a profile isManaged on the child's device; a blocking session for that profile is active. Child opens the app (lands on HomeView), taps the Stop button on the managed profile's card. With default stop conditions the session ends immediately and all apps are unblocked — no PIN was ever requested. Parental blocking is defeated with one tap.

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, high] I attempted to refute the claim via every plausible guard location and found none. HomeView is the root view in all app modes including child (FoqosApp.swift:249-252). Its @SafeQuery fetches every profile with no isManaged filter and hands them to BlockedProfileCarousel; the card's Stop button fires onStopTapped unconditionally when a session is active. The stop path (handleStopTap → determineStopAction → toggleBlocking → stopBlocking) inspects only profile.stopConditions — with manual stop enabled (the common default) it returns .stopImmediately and ends the session. Grep across HomeView, StrategyManager, StartStopActionResolver, and the card components shows zero references to isManaged, LockCodeManager, or child-mode gating in this path; the one currentMode==.child check in StrategyManager only writes a heartbeat. Meanwhile edit and delete of managed profiles ARE correctly gated in BlockedProfileView with LockCodeEntryView, and ChildDashboardView's UI text explicitly promises that locked profiles require the code to "edit, delete, or stop" — proving stop-gating is intended but missing. A child can therefore end an active managed blocking session with one tap and no PIN, defeating parental blocking. The finding is real and critical.

> [real=true, high] Reproduced the full failure chain in the code as written. FoqosApp routes ALL modes (including child) to HomeView. HomeView's @SafeQuery has no isManaged filter and passes the full profile list to BlockedProfileCarousel, so a child sees managed profiles with stop buttons. The stop path (onStopTapped -> strategyButtonPress -> handleStopTap -> StartStopActionResolver.determineStopAction) inspects only profile.stopConditions and, for manual-stop profiles (which V1 migration sets to manual=true), immediately calls strategyManager.toggleBlocking — ending the blocking session. Grep confirms zero references to isManaged, LockCodeManager, or child-mode checks anywhere in HomeView's stop path, StrategyManager, StartStopActionResolver, or the card components. Meanwhile edit/delete ARE gated in BlockedProfileView via isManagedProfile && currentMode == .child checks, and ChildDashboardView's UI explicitly promises 'Locked profiles require the lock code to edit, delete, or stop.' — a promise the stop path does not implement. A child can therefore end a parent-locked blocking session with one tap and no PIN.

## Suggested fix approach

Option A (re-gate stopping): in handleStopTap and the deep-link/intent stop paths, if profile.isManaged && currentMode == .child && !isUnlocked(profile.id), present LockCodeEntryView and only stop on success. Option B (copy fix): change ChildDashboardView footer text to 'edit or delete' and audit other copy for the same promise. Decide A or B with the maintainer first; do not implement both.

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
