# Handover: TODO in FamilyLockCode acknowledges brute-forceable PIN hash that syncs to child-readable CloudKit DB

- **GitHub issue:** #240
- **Severity:** medium
- **Domain:** structural-debt
- **Primary location:** `Foqos/Models/FamilyLockCode.swift:65`
- **Status:** Confirmed by adversarial verification
- **Audit date:** 2026-07-02 (line numbers cited below are from this date's `main`)

## Problem

FamilyLockCode hashes the parent's 4-digit PIN with a single unsalted-iteration SHA256(code+salt) (hashCode, lines 68-73) and stores codeHash+codeSalt in the shared CloudKit database (toCKRecord writes both, lines 125-126) so child devices can verify locally. LockCodeEntryView.swift:309 confirms codes are exactly 4 digits (10,000 possibilities). The TODO at line 65 frames this as optional hardening, but the child's iCloud account has read access to the FamilyLockCode record by design (that is how the code syncs parent->child), so the hash+salt are recoverable by the child outside the app, where the in-app attempt throttle (LockCodeManager) does not apply.

## Failure scenario

A tech-savvy child uses CloudKit web services / a test app signed into their own Apple ID to read the shared-DB FamilyLockCode record, then brute-forces all 10,000 SHA256(code+salt) candidates in under a second offline, recovering the parent PIN and unlocking every locked profile. Note even PBKDF2/Argon2 (the TODO's suggestion) cannot protect a 4-digit keyspace against offline attack; only server-side or Secure-Enclave-gated verification would.

## Adversarial verifier evidence

The following independent verifier analyses confirmed (or, if disputed, contested) this finding. They contain traced code paths and decisive line citations — read them before forming your own plan, then re-verify against current code since lines may have shifted.

> [real=true, high] Every technical premise of the claim is confirmed by the code. (1) hashCode uses a single unsalted-iteration SHA256: `let combined = code + salt; ... let hash = SHA256.hash(data: data)` (FamilyLockCode.swift:68-72) with no PBKDF2/key stretching. (2) Both hash and salt are written to the CloudKit record: `record[RecordKey.codeHash] = codeHash` / `record[RecordKey.codeSalt] = codeSalt` (FamilyLockCode.swift:125-126, mirrored in CloudKitNetworkService+LockCodes.swift:26-27). (3) The record is fetched from the SHARED database, which the child's own iCloud account has read access to by design: `sharedDatabase.records(matching: query, inZoneWith: zone.zoneID)` in fetchSharedLockCodes (CloudKitNetworkService+LockCodes.swift:108) — this is exactly how the code syncs parent->child, so a child signed into their own Apple ID can read the record outside the app. (4) The PIN is exactly 4 digits: `private let codeLength = 4` (LockCodeEntryView.swift:19,276) and "Enter a 4-digit code" (line 309) => 10,000 keyspace, trivially brute-forced offline against SHA256. (5) The in-app throttle (LockCodeManager.swift:339-423, verifyCode/recordFailedAttempt) only gates in-app entry; it does not and cannot protect against an attacker computing 10,000 SHA256(candidate+salt) values offline. (6) The TODO at line 65 does frame PBKDF2/Argon2 as the mitigation, which — as the claim correctly notes — cannot protect a 4-digit keyspace against offline attack. I attempted to refute via: an app-layer share ACL restricting read (none exists; the child must read the record to verify locally), server-side verification (none — verifyCode runs locally in FamilyLockCode.verifyCode:52-54), or a larger keyspace (ruled out by codeLength=4). No guard refutes the finding. The only nuance is severity/framing: this is a documented, accepted-for-v1 tradeoff (comment lines 65-66 say "acceptable for v1 family app use case"), and the threat actor is a determined child with technical skills — but the defect (misleading TODO hiding a real offline-brute-force weakness in a child-readable store) is real as described.

## Suggested fix approach

Track as a security issue rather than a code TODO: either avoid syncing verifiable hash material to child-readable storage (e.g., verify via a CloudKit function/parent-device round trip), or document the threat model explicitly and remove the misleading 'PBKDF2 would fix it' framing.

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
