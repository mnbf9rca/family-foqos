# Handover: ChildAuthorizationRequiredView (and SetupStepRow) is dead code — the Family Sharing setup guidance is never shown

- **GitHub issue:** #255
- **Severity:** low
- **Domain:** structural-debt
- **Primary location:** `Foqos/Views/Child/ChildAuthorizationRequiredView.swift:5`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

Full-repo grep for 'ChildAuthorizationRequiredView' across Foqos, FoqosWidget, FoqosShieldConfig, FoqosDeviceMonitor, FoqosTests and Packages matches only this file (declaration at line 5 and its own #Preview at line 143); it is never instantiated or presented. Its doc comment says it is 'shown when a CloudKit share invitation cannot be accepted because the device is not set up as a child' — but the current acceptance flow in FoqosApp.swift:432-481 auto-detects role via AuthorizationVerifier and treats .notChildDevice/.notAuthorized as parent role, so the failure state this 140-line screen (plus SetupStepRow) was built for no longer exists.

## Failure scenario

No runtime failure — but a maintainer changing invitation-failure UX edits this screen expecting it to appear on child devices, tests the invite flow, and never sees their change because the view is unreachable; the detailed 4-step Family Sharing setup guidance it contains is silently lost to users who could benefit from it.

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, high] I attempted to refute the claim and could not. (1) A full-repo grep for `ChildAuthorizationRequiredView` and `SetupStepRow` across all Swift sources (app, widget, shield config, device monitor, tests, packages) matches only Foqos/Views/Child/ChildAuthorizationRequiredView.swift itself — the declaration (line 5), internal SetupStepRow uses (lines 43-61), the SetupStepRow declaration (line 112), and the file's own #Preview (line 143). It is never instantiated, presented as a sheet, or referenced anywhere else. (2) The old trigger mechanism is gone: grep for `childAuthorizationFailed`, `setChildAuthorizationFailure`, and `childAuthorizationRequired` returns zero Swift hits, so no presentation path exists even indirectly. (3) The current share-acceptance flow in FoqosApp.swift (acceptCloudKitShare, lines 432-481) confirms the claim's mechanism: `.notChildDevice` and `.notAuthorized` verification results are mapped to `detectedRole = .parent` and the flow proceeds to a confirmation dialog — the 'device is not set up as a child' failure state the view was built for no longer occurs. (4) The project's own completed plan doc (docs/plans/completed/2026-02-09-parent-share-acceptance.md:458) explicitly documents that the sheet's trigger was removed and the view was deliberately left in place ('does no harm and might be useful if we add other child auth checks later'), corroborating that it is dead code. Additionally, the as-built docs (docs/codebase-analysis/as-built/feature-onboarding-and-authorization.md:339 etc.) still describe the view as reachable, which reinforces the claimed maintainer-confusion failure scenario. Severity 'low' and category 'dead code' are appropriate — there is no runtime failure, only a 140-line unreachable view plus stale documentation.

## Suggested fix approach

Either wire it into the share-acceptance error path (e.g., when a child-role invite is accepted on a non-child account) or delete the file.

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
