# Handover: ProfileInsightsUtil reads profile.sessions with no zombie-model filtering — crash if the profile is deleted (e.g. via sync) while the insights sheet is open

- **GitHub issue:** #213
- **Severity:** high
- **Domain:** views-secondary
- **Primary location:** `Foqos/Utils/ProfileInsightsUtil.swift:96`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

ProfileInsightsUtil holds a plain `let profile: BlockedProfiles` (line 68) and every metric/aggregate (computeMetrics line 96, dailyAggregates line 177, hourlyAggregates line 219, break aggregates lines 318/369/422/464/506) iterates raw `profile.sessions` without the `.valid` filter mandated by AGENTS.md for exactly this reason. ProfileInsightsView is presented as a sheet (BlockedProfileView.swift:692, HomeView.swift:319) without SafeModelView protection, and its body calls viewModel.dailyAggregates/hourlyAggregates on every render (ProfileInsightsView.swift:127 etc.). SwiftData automatic CloudKit sync is off, but ProfileSyncManager deletes local profiles when a remote deletion arrives, turning the retained reference into a zombie whose property access raises EXC_BREAKPOINT — the same crash class fixed for other views in #187 with SafeModelView.

## Failure scenario

Child device has the Insights sheet open for profile X. Parent (or the same user on another device) deletes profile X; ProfileSyncManager removes it locally, the underlying @SafeQuery-driven parent view re-renders, the still-presented sheet body re-evaluates, and viewModel.dailyAggregates accesses `profile.sessions` on the deleted model -> EXC_BREAKPOINT crash.

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, high] Every element of the claim checks out against the code. ProfileInsightsUtil retains a plain BlockedProfiles reference and dereferences profile.sessions at 8 sites with zero zombie guards (no isDeleted/modelContext checks, no .valid). ProfileInsightsView is presented as a sheet from HomeView (.sheet(item:)) and BlockedProfileView (plain nil-check `if let validProfile = profile` — a stored reference that stays non-nil after deletion), and unlike its sibling BlockedProfileSessionsView it is not wrapped in SafeModelView. The deletion-via-sync path is real: SyncCoordinator.swift:195 calls BlockedProfiles.deleteProfile when a profile disappears from CloudKit, so a remote deletion while the sheet is open turns the retained reference into a zombie. The codebase's own SafeModelView/@SafeQuery infrastructure (fix #187, commit c8930a8) documents that property access on such zombies raises EXC_BREAKPOINT. Even absent re-render subtleties, interacting with the open sheet (date-range change → setDateRange → computeMetrics → profile.sessions) deterministically dereferences the deleted model. No guard anywhere in the call chain refutes the claim.

> [real=true, high] Full failure chain reproduced in code. (1) ProfileInsightsUtil retains a plain `let profile: BlockedProfiles` and every metric/aggregate iterates raw `profile.sessions` with no zombie guard and no `.valid` filter, violating the AGENTS.md-mandated pattern. (2) SyncCoordinator runs on container.mainContext (FoqosApp.swift:227) and its deletion-reconciliation path (SyncCoordinator.swift:191-195) calls BlockedProfiles.deleteProfile + context.save() when a remote deletion arrives — deleting the exact same instance the open sheet holds. (3) Both presentation sites (HomeView.swift:318-319 `.sheet(item:)`, BlockedProfileView.swift:690-693 `if let validProfile`) keep the sheet presented after deletion and neither uses SafeModelView, unlike sibling views (BlockedProfileListView.swift:58, ChildDashboardView.swift:289). (4) The sheet body reads profile.sessions/createdAt and calls dailyAggregates/hourlyAggregates on every render; deletion mutates the Observable @Model (endSession on sessions) and changes the parent's @SafeQuery results, forcing a re-render whose profile.sessions access hits deleted backing storage → EXC_BREAKPOINT, the same zombie-model crash class the repo already fixed via SafeModelView in #187. Every step of the claimed scenario holds as written.

## Suggested fix approach

Guard all accesses with `profile.modelContext != nil && !profile.isDeleted`, use `profile.sessions.valid`, and/or wrap ProfileInsightsView's content in SafeModelView(profile).

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
