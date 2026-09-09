# Family-share compatibility implementation plan

> Execute inline in the assigned build1 worktree using the executing-plans workflow.

**Goal:** Implement the approved mixed-version contract in issue #480.
**Architecture:** Classify CKRecords at the existing model boundary; reduce fetch rows in the network service. Keep command execution, replay protection, lock-code writers, and offline cache policy unchanged.
**Tech stack:** Swift, CloudKit, XCTest, existing simulator gate.
**Spec:** ../specs/2026-09-09-family-share-compatibility-design.md

## Constraints

- Existing command strings retain their meaning and required envelope.
- Unsupported command diagnostics include only the discriminator, capped at 64 characters.
- No new shared fields, record types, dependencies, hash/scope writers, or schema deployment.
- Preserve the five three-second probes and seven-day stale cleanup.
- The reviewed spec is approved; PR #481 remains untouched and lands with this implementation.

## Tasks

- [x] Establish the focused XCTest baseline through `scripts/xcode-stream.sh --agent build1 --session collab`.
- [x] Add failing CKRecord tests in `FoqosTests/FamilyShareCompatibilityTests.swift`: malformed known-command envelopes, rejected scope metadata, legacy PIN fixture, cache round-trip. Add pending/absence text regressions to `ParentResetCommandStatusTests`.
- [x] In `FamilyCommand.swift`, add `DecodeResult` (`supported`, `unsupported`, `malformed`) and `decode(_:)`; keep `init?(from:)` executable-only. Validate every envelope field before classifying an unknown type.
- [x] In `CloudKitNetworkService+Commands.swift`, have `resolvePendingCommandFetch(records:hasFailures:hasUserRecordID:)` classify actual row results. Only supported commands enter the returned array. Unsupported records log an inline literal with the capped discriminator and do not disconnect the fetch.
- [x] In `FamilyLockCode.swift`, default to all children only for absent scope; require valid explicit scope metadata otherwise. In `CloudKitNetworkService+LockCodes.swift`, extract `decodeLockCodeRecords(_:)` for the parent fetch and throw `CloudKitError.fetchFailed` on any failed or unreadable row. Keep the child failure/cache path and writers intact.
- [x] Add direct classifier/reducer coverage for known+unknown, unknown-only, malformed, failed-row, zone-failure, and missing-identity outcomes. Exercise the actual parent row decoder for both malformed records and CKError failures, including row-level `unknownItem`.
- [x] Rename parent status `.confirmed` to `.noLongerPending`, use the approved copy, remove green/checkmark success presentation, and retain the probe's early return on absence.
- [x] Run focused tests, formatting, privacy lint, and the version gate; increment project version/build to 2.0.63/81 (adjust only if main advances). Record the live family-device walkthrough as not run if no paired test setup is available.
- [ ] Commit signed, push, open a ready PR into main containing the spec and implementation, and request reviewer approval at the exact head. Address findings with new signed commits. Apply `greptile-review` once after those findings are addressed; send the orchestrator the final head/base/checks/reviewer packet.

## Validation evidence

- Baseline: 56 focused tests passed. New decoder/copy regressions failed against the original implementation (10 assertions), then all 65 focused tests passed with the changes.
- Full recursive Swift formatting lint, log privacy lint (527 sites, no annotations), and diff whitespace checks passed.
- No live paired parent/child CloudKit test setup was available to this stream; the synthetic-command device walkthrough was not run.
- Diff review confirms command application/ledger/deletion, stale cleanup, hash/salt and scope writers, private data boundaries, and schema files are unchanged.
