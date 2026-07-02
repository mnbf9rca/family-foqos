# Handover: syncShareParticipantsToFamilyMembers deletes a child's FamilyMember record when the participant's userRecordID is unresolved

- **GitHub issue:** #241
- **Severity:** low
- **Domain:** cloudkit-sync
- **Primary location:** `Foqos/CloudKit/CloudKitNetworkService+Sharing.swift:229`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

currentParticipantRecordNames is built only from accepted participants whose userIdentity.userRecordID is non-nil (lines 199-201); participants with a nil userRecordID are routed to 'pending' (lines 210-213) but their existing FamilyMember record cannot match the set, so the removal loop (lines 226-240) deletes it as if the child had left the share. CKShare participant identities can come back with nil userRecordID transiently (identity not yet resolved on this fetch). The child re-registers on its next verifySelfFamilyMember pass, but in the interim the parent dashboard shows the child as unenrolled/pending and lock codes scoped to .specificChild(childId) no longer match an enrolled member.

## Failure scenario

Parent opens the dashboard while CloudKit returns the child participant with an unresolved identity: the child's FamilyMember record is deleted from the policy zone, the child disappears from the family list and appears as a 'pending' participant, and a specific-child lock code stops resolving to them until the child device next runs verification and re-registers.

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, medium] The defect is confirmed by direct code reading. In syncShareParticipantsToFamilyMembers, the removal set is built with compactMap over userIdentity.userRecordID?.recordName (lines 199-201), so an accepted participant whose identity is unresolved (nil userRecordID) is silently dropped from the set. The very same function acknowledges this state is reachable: lines 210-214 route accepted participants with nil userRecordID into 'pending'. But the removal loop (lines 226-240) then deletes that participant's FamilyMember record from the policy zone because their userRecordName (set from the child's container userRecordID during self-registration in CloudKitNetworkService+Verification.swift:14,45) cannot be in the set. Result: the same participant is simultaneously reported as 'pending self-registration' and treated as having left the share — an internal contradiction with a destructive server-side delete. No guard exists elsewhere: the sole caller (CloudKitManager.swift:208-212) just publishes the result to the dashboard. Recovery via the child's next verifySelfFamilyMember pass (FoqosApp.swift:135) matches the claim, supporting the 'low' severity. Confidence is medium rather than high only because whether CloudKit actually returns nil userRecordID for an .accepted participant in production cannot be proven from code alone — though the code's own pending branch was written on exactly that premise, and if that branch is reachable the deletion bug is certain.

## Suggested fix approach

Only delete FamilyMember records for participants that are affirmatively absent from share.participants (or not accepted); skip removal whenever any accepted participant has a nil userRecordID.

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
