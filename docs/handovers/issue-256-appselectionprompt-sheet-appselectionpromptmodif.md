# Handover: AppSelectionPrompt sheet, AppSelectionPromptModifier and .appSelectionPrompt() extension are dead — superseded by opening the profile editor

- **GitHub issue:** #256
- **Severity:** low
- **Domain:** structural-debt
- **Primary location:** `Foqos/Components/Sync/AppSelectionPrompt.swift:7`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

In AppSelectionPrompt.swift, struct AppSelectionPrompt (line 7) is referenced only by AppSelectionPromptModifier (line 172), which is referenced only by the View extension appSelectionPrompt(isPresented:profile:) (line 196) — and full-repo grep for 'appSelectionPrompt|AppSelectionPromptModifier' outside this file returns nothing. The live flow instead shows AppSelectionRequiredBanner (BlockedProfileCard.swift:145-152) whose tap sets profileToEdit in HomeView.swift:212-215, opening the full profile editor which clears needsAppSelection on save (BlockedProfileView.swift:921). The dedicated prompt sheet, including its own saveSelection() persistence path (line 131 area, sets needsAppSelection: false at line 137), is unreachable.

## Failure scenario

A maintainer fixing a bug in how synced profiles get local app selection edits AppSelectionPrompt.saveSelection() (a plausible-looking persistence path that writes needsAppSelection = false) and their fix never takes effect, because the real code path is BlockedProfileView.saveProfile — two parallel implementations where only one runs.

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, high] Attempted to refute by grepping the full repo (app target, packages, tests) for any reference to AppSelectionPrompt, AppSelectionPromptModifier, or the appSelectionPrompt() extension outside Foqos/Components/Sync/AppSelectionPrompt.swift — zero hits. Within the file, AppSelectionPrompt is only instantiated by AppSelectionPromptModifier (line 180) and the #Preview (line 202); the modifier is only used by the View extension (line 197), which nothing in the codebase calls. The live flow the claim describes is confirmed: BlockedProfileCard.swift:145-150 shows AppSelectionRequiredBanner when profile.needsAppSelection, its tap calls onAppSelectionTapped, which HomeView.swift:212-214 wires to set profileToEdit, opening BlockedProfileView, whose save clears the flag at BlockedProfileView.swift:921 (needsAppSelection: false). So AppSelectionPrompt.saveSelection() (lines 131-143) is a parallel, unreachable persistence path exactly as claimed. Only AppSelectionRequiredBanner in this file is live; the sheet, modifier, and extension are dead code. Severity 'low' (dead code, no runtime defect) is appropriate.

## Suggested fix approach

Delete AppSelectionPrompt, AppSelectionPromptModifier and the View extension, keeping only AppSelectionRequiredBanner.

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
