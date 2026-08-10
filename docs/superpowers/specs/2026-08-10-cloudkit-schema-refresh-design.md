# CloudKit Schema Refresh Design

## Goal

Refresh `Foqos/CloudKit/cloudkit-schema.ckdb` so the committed reference schema represents every
CloudKit record type required by the current app, document the maintainer-only Production promotion,
and add a small zero-Xcode drift check.

## Sources of Truth

- `fastlane/required-prod-schema.txt` defines the record types and active fields the release gate
  requires, reconciled by hand against code.
- The `CKRecord` encoders in `Foqos/CloudKit/SyncModels.swift`,
  `Foqos/Models/DeviceHeartbeat.swift`, and `Foqos/Models/FamilyCommand.swift` define current fields
  and data types.
- `Foqos/CloudKit/cloudkit-schema.ckdb` remains a checked-in reference artifact. Agents do not
  install it or promote it to Production.

The current manifest has 15 required types. The reference export is missing `DeviceHeartbeat`,
`EmergencyResetEpoch`, `EmergencySettings`, `EmergencyUnblockEvent`, and `SyncEstablishment`.
It also predates the `generation` field on `SyncedProfile` and `SyncedLocation`.

## Schema Changes

Add `DeviceHeartbeat` alongside the shared-family record types, with fields matching its record
encoder. Add the four emergency/establishment record types alongside the private DeviceSync types,
using the same creator-only grants as the existing same-user records. Add `generation INT64` to
`SyncedProfile` and `SyncedLocation`.

Existing deprecated record types remain in the artifact. Production CloudKit schemas are
additive-only, so the consistency check requires every manifest type to exist but does not reject
extra compatibility types. Apple recommends keeping a text schema in source control and using the
CloudKit dashboard to promote schema changes to Production:
[Integrating a Text-Based Schema into Your Workflow](https://developer.apple.com/documentation/cloudkit/integrating-a-text-based-schema-into-your-workflow).

## Drift Check

`fastlane/required-prod-schema.txt` stores both required record declarations (`RECORD TYPE X`) and
required active fields (`RECORD TYPE X.field`). Its header documents the hand-reconciliation ritual
for the two key idioms used by the app: `FieldKey: String` enums and resolved `RecordKey` string
constants. This deliberately keeps the zero-Xcode gate simple and makes the manifest reviewable;
automatic code-to-schema drift detection belongs in a separate Swift test.

`scripts/check-cloudkit-schema-export.sh` normalizes the checked-in `.ckdb` into the same exact
record and record-field entries, then fails when any non-comment manifest line is absent. Required
fields are scoped to their record blocks, so a same-named field on another type cannot satisfy the
check. The comparison remains one-way: extra schema declarations are allowed because Production
is additive-only and retains CloudKit system fields and deprecated compatibility data.

The known-good baseline is 100 fields across 12 active types: `SyncedProfile` (39),
`ProfileSession` (10), `SyncedLocation` (8), `EmergencySettings` (7),
`EmergencyUnblockEvent` (5), `SyncResetRequest` (4), `EmergencyResetEpoch` (2),
`SyncEstablishment` (2), `DeviceHeartbeat` (5), `FamilyCommand` (5), `FamilyLockCode` (7), and
`FamilyMember` (6). `FamilyRoot`, deprecated `SyncedSession`, and built-in `cloudkit.share` remain
type-checked but are not part of the manually reconciled active-field inventory.

`scripts/test-check-cloudkit-schema-export.sh` exercises the real script against disposable
fixtures and proves matching-with-extras passes while missing type, prefix-only type, missing field,
and empty-manifest cases fail closed.

## Maintainer Runbook

Add `docs/cloudkit-production-schema.md` with the exact container identifier, the pre-promotion
repository checks, the CloudKit Console promotion boundary, and post-promotion verification through
`scripts/check-prod-schema.sh`. The note explicitly states that Production deployment is a
maintainer action after the final schema-touching change and before TestFlight; this work does not
perform that action.

## Scope Boundaries

- No CloudKit Console mutation or `cktool` install/deploy.
- No GitHub Actions or other CI wiring.
- No Xcode build or simulator test.
- If the #321 version-gate PR lands first, adjust this branch with a new version-bump commit against
  the updated `main`; never amend or force-push.
