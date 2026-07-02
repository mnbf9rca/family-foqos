# Handover: Personal identifiers (real names and email addresses of family-share participants) written to exportable logs

- **GitHub issue:** #252
- **Severity:** low
- **Domain:** cross-cutting
- **Primary location:** `Foqos/CloudKit/CloudKitNetworkService+FamilyMembers.swift:64`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

removeShareParticipant() logs `participant.userIdentity.nameComponents?.formatted() ?? participant.userIdentity.lookupInfo?.emailAddress` via Log.info (CloudKitNetworkService+FamilyMembers.swift:61-64), i.e. the family member's real Apple ID name or raw email address. saveFamilyMember/deleteFamilyMember also log member.displayName (lines 10, 20, 36), which is derived from the CKShare participant's userIdentity.nameComponents (CloudKitNetworkService+Verification.swift:188-190), i.e. a real person's name, not a user-defined profile name. AGENTS.md's logging privacy rules state personal identifiers must never be logged; only profile names, UUIDs, and timestamps are acceptable. The Log framework persists entries to a file that users export and share (Settings -> Diagnostics -> Debug Mode -> Export Logs), so these identifiers — including children's names and participant emails — end up in files sent to support or third parties.

## Failure scenario

A parent removes a family member from sharing (removeShareParticipant runs, logging the child's real name or email), later hits an unrelated bug and uses Export Logs to share diagnostics; the exported log file contains the family members' real names/email addresses — leaking personal identifiers of minors in a file intended to be shared externally, in direct violation of the project's stated privacy logging policy.

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, high] Every element of the claim checks out in code: removeShareParticipant logs the family member's real Apple ID name or raw email address, and saveFamilyMember/deleteFamilyMember log displayName which is derived from CKShare participant nameComponents (a real person's name, e.g. "Emma"), not a user-defined profile name. The Log framework persists the raw interpolated message to files with no sanitization (fileLoggingEnabled=true, minimumLevel=.debug, and %{public}@ in OSLog), and those files are user-exportable via LogExportManager/LogExportView. The code path is reachable from ParentDashboardView's remove-member flow. This directly violates AGENTS.md's privacy rule ("Never log ... personal identifiers"); the email-address fallback is an unambiguous personal identifier. No guard, redaction layer, or unreachability refutes the finding. Severity 'low' is reasonable since exposure requires the user to export and share their own logs.

## Suggested fix approach

Log only non-identifying data: replace the interpolated name/email with the participant's userRecordName or the FamilyMember UUID (both explicitly allowed), e.g. Log.info("Removed participant from share") and Log.info("Saved family member \(member.id)", ...). Same for lines 10, 20, and 36.

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
