# Handover: Debug Mode (reachable in Child mode without lock code) displays and copies the physical-unblock NFC tag UID

- **GitHub issue:** #247
- **Severity:** low
- **Domain:** views-secondary
- **Primary location:** `Foqos/Views/DebugView.swift:182`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

DebugView is reachable in any app mode with no lock-code gate: from the Home version footer whenever a profile is active (VersionFooter.swift:11-17, HomeView.swift:343) and from Settings -> Diagnostics (SettingsView.swift:325-335, 442). copyToMarkdown (DebugView.swift:181-187) and ProfileDebugCard (Foqos/Components/Debug/ProfileDebugCard.swift:55) expose `physicalUnblockNFCTagId` in full. This is the raw NFC hardware UID (NFCScannerUtil.swift:190 hexEncodedString of tag identifier) that NFCTimerBlockingStrategy.stopBlocking compares against (NFCTimerBlockingStrategy.swift:68) to enforce 'only this tag can unblock'. The QR value is only a SHA-256 digest, but the NFC UID is directly cloneable onto UID-writable ('magic') tags.

## Failure scenario

A parent configures a strict profile that can only be stopped by scanning a specific NFC tag the parent keeps. During an active session, the child taps 'Debug mode' on the Home footer (no lock code required), reads/copies the NFC Tag ID, writes it to a UID-changeable NFC tag, and can thereafter stop the restricted session at any time without the parent's tag.

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, high] Every link in the claimed chain is confirmed in code. (1) DebugView is reachable without any lock-code or app-mode gate: HomeView presents it from the VersionFooter whenever a profile is active, and SettingsView presents it from the Diagnostics section unconditionally; grep finds no appModeManager/lockCode check on either path. (2) DebugView.copyToMarkdown emits the full raw physicalUnblockNFCTagId, and ProfileDebugCard renders it on screen. (3) That value is the literal credential: it is set from NFCScannerUtil's tag.id, which is the hardware UID hex (tagBox.identifier.hexEncodedString()), and NFCTimerBlockingStrategy/NFCManualBlockingStrategy/NFCBlockingStrategy stopBlocking each do a direct string equality check against it before ending the session — no additional lock-code verification exists in that stop path. V2 migration copies the same raw string (unhashed, unlike QR which goes through QRCodeHasher.hash) into stopNFCTagId and does not clear the legacy field, so it also matches the V2 stopWithNFCTag validation for migrated profiles. A child who reads/copies this UID during an active session and writes it to a UID-changeable tag can stop the restricted session. Minor scope caveat: profiles created purely under V2 populate only stopNFCTagId (which DebugView does not display) and leave physicalUnblockNFCTagId nil, so exposure is limited to legacy/migrated profiles or any profile with the legacy field set — this narrows but does not refute the finding, consistent with its 'low' severity.

## Suggested fix approach

Redact or truncate physicalUnblockNFCTagId in DebugView/ProfileDebugCard when appModeManager.currentMode == .child (or store/compare a hash as done for QR codes), and/or gate Debug Mode behind the lock code in Child mode.

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
