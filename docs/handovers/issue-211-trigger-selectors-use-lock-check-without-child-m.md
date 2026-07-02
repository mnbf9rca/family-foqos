# Handover: Trigger selectors use lock check without child-mode guard, permanently disabling start/stop trigger editing for Parent (and Individual) mode

- **GitHub issue:** #211
- **Severity:** high
- **Domain:** views-primary
- **Primary location:** `Foqos/Views/BlockedProfileView.swift:337`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

StartTriggerSelector (line 337) and StopConditionSelector (line 377) are disabled with `isBlocking || (isManagedProfile && !isUnlockedForEditing)` — missing the `appModeManager.currentMode == .child && lockCodeManager.canVerifyCode` qualifiers that the view's own editingDisabled property (lines 129-133) and the unlock banner (line 251) apply. isUnlockedForEditing is only ever true after entering the lock code (LockCodeManager.isUnlocked, Foqos/Utils/LockCodeManager.swift:330), and the Unlock button is shown only in child mode. So in Parent mode (full access per the AGENTS.md mode table) a Parent-Controlled profile shows an editable form with a Save button, but its 'Start by...' and 'Continue until...' sections are permanently disabled with no way to unlock them. Same for child mode before the lock code has synced (canVerifyCode false): everything else is editable but triggers are not.

## Failure scenario

Parent enables 'Parent-Controlled' on a profile, saves, then reopens it (device still in Parent mode) to change the schedule start time: the Schedule toggle, NFC/QR pickers, and Configure buttons in both trigger sections are greyed out, no unlock prompt exists in Parent mode, and the parent cannot edit the profile's triggers at all.

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, high] The trigger selectors' disabled expressions omit the child-mode and canVerifyCode qualifiers that the view's own editingDisabled property applies. In Parent mode, isUnlockedForEditing can never become true: grantTemporaryUnlock is only called from handleLockCodeSuccess via the LockCodeEntryView sheet, and both triggers for that sheet are child-mode-gated (the Unlock banner requires currentMode == .child && canVerifyCode; the delete path checks currentMode == .child). ParentDashboardView's lock entry sets an unrelated isDashboardUnlocked flag, and BlockedProfileView is presented from HomeView/BlockedProfileListView with no prior unlock. The scenario is reachable because the isManaged toggle is shown only in Parent mode (showManagedToggle), so a parent-mode device necessarily holds managed profiles; reopening one shows an editable form with a Save button (editingDisabled == false) while both StartTriggerSelector and StopConditionSelector are permanently disabled (the components apply .disabled(disabled) to all controls) with no unlock affordance. The secondary claim also holds: in child mode before lock codes sync (canVerifyCode false), editingDisabled is false and the unlock banner is hidden, yet triggers remain disabled. This violates the AGENTS.md rule that only Child mode should be blocked by lock codes.

> [real=true, high] Reproduced the full failure chain in code. (1) Parent mode can mark a profile managed: showManagedToggle requires `currentMode == .parent` (BlockedProfileView.swift:136-140) and the toggle at 437-443 binds $isManaged. (2) On reopen, isManagedProfile is true (118-120). (3) isUnlockedForEditing can never become true in Parent mode: it calls lockCodeManager.isUnlocked (123-126), true only when unlockedProfileId == profileId (LockCodeManager.swift:330-332), set only by grantTemporaryUnlock, whose sole call site is handleLockCodeSuccess (BlockedProfileView.swift:827); the lock-code sheet is triggered only from the Unlock button inside the child-mode-only banner (251-271) and the delete path guarded by `currentMode == .child` (624-626). (4) Lines 337 and 377 disable StartTriggerSelector/StopConditionSelector with `isBlocking || (isManagedProfile && !isUnlockedForEditing)` — true in Parent mode — and StartTriggerSelector.swift applies .disabled(disabled) to every control (lines 23-117). (5) Meanwhile editingDisabled (129-133) adds the `.child && canVerifyCode` qualifiers, so in Parent mode the Save button (650) and all other sections remain editable while both trigger sections are permanently greyed out with no unlock path — exactly the AGENTS.md anti-pattern (Parent mode must never be blocked by lock codes). The secondary child-mode-before-sync claim (canVerifyCode false) also holds by the same expression mismatch. The claim's fixSketch (reuse editingDisabled) matches the surrounding code's intent.

## Suggested fix approach

Change both disabled expressions to `isBlocking || (isManagedProfile && !isUnlockedForEditing && appModeManager.currentMode == .child && lockCodeManager.canVerifyCode)` — i.e., reuse editingDisabled.

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
