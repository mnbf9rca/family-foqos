# CloudKit Schema Refresh Design

## Goal

Refresh `Foqos/CloudKit/cloudkit-schema.ckdb` so the committed reference schema represents every
CloudKit record type required by the current app, document the maintainer-only Production promotion,
and add a small zero-Xcode drift check.

## Sources of Truth

- `fastlane/required-prod-schema.txt` defines the record types the release gate requires.
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

`scripts/check-cloudkit-schema-export.sh` reads the manifest and the checked-in `.ckdb`, then fails
if either input is empty/unreadable or any required `RECORD TYPE` declaration is absent. It allows
extra declarations such as deprecated `FamilyPolicy`.

`scripts/test-check-cloudkit-schema-export.sh` exercises the real script against disposable
fixtures and proves matching-with-extras passes while missing, prefix-only, and empty-manifest
cases fail closed.

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
