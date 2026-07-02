# Handover: AddFamilyMemberView and EnrollFamilyMemberButton are dead duplicate enrollment UIs

- **GitHub issue:** #257
- **Severity:** low
- **Domain:** structural-debt
- **Primary location:** `Foqos/Views/Parent/ParentDashboardView.swift:1283`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

Full-repo grep (all app targets, extensions, tests, Packages) shows AddFamilyMemberView is declared at ParentDashboardView.swift:1283 and never instantiated anywhere; EnrollFamilyMemberButton is declared at ShareCoordinator.swift:197 and likewise never instantiated. The live enrollment path calls shareCoordinator.enrollFamilyMember(role:) directly from ParentDashboardView (lines 451 and 487) with the sheet attached at line 190. Both dead types contain their own copies of the enrollment call (lines 1365, 203) and their own .enrollFamilyMemberSheet attachments (lines 1389, 213).

## Failure scenario

Three parallel implementations of 'enroll a family member' exist; a developer changing invitation behavior (e.g., adding a role confirmation or fixing the sheet presentation) edits AddFamilyMemberView or EnrollFamilyMemberButton — the ones with descriptive names — and ships a change that never runs, while the real buttons at ParentDashboardView:451/487 keep the old behavior.

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, high] Attempted to refute by grepping every .swift file in the repo (app, extensions, tests, packages) for both type names. Each name appears exactly once — at its declaration site — with zero instantiations, zero #Preview usages, and zero test references. Since these are SwiftUI structs, there is no string-based/Objective-C runtime instantiation path that grep could miss. The live enrollment flow is confirmed to bypass both types: ParentDashboardView's coParentsSection and childrenSection buttons call shareCoordinator.enrollFamilyMember(role:) directly (lines 451 and 487), with the enrollment sheet attached once at line 190 via .enrollFamilyMemberSheet(coordinator: shareCoordinator). Both dead types contain their own duplicate enrollFamilyMember calls and their own .enrollFamilyMemberSheet attachments (each even creating its own @StateObject ShareCoordinator, divergent from the live shared-coordinator pattern), so the claimed failure scenario — a developer editing the descriptively-named dead type and shipping a no-op change — is plausible. The finding is accurate as claimed; severity 'low' (dead code / maintenance hazard, no runtime defect) is appropriate.

## Suggested fix approach

Delete AddFamilyMemberView (ParentDashboardView.swift:1283+) and EnrollFamilyMemberButton (ShareCoordinator.swift:197+).

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
