# Issue #454 Several Named NFC Tags and QR Codes per Profile

## Status and scope

Design for issue #454. Base: `main` at `3034c03`. Revision 1, awaiting the reviewer's adversarial design review.

A profile's start trigger and stop condition each accept one NFC tag id and one QR code hash today. This design lets each of those four slots hold a named list, so a child with a tag at each parent's house, or a spare tag, can use any of them. The tags stay with the profile, which stays in the iCloud account of the device that runs it. Nothing crosses the family share and parents never scan for the child.

Out of scope: the V1-era physical-unblock fields (see Decision 2), sharing tags between profiles, and any change to the family share.

## Decisions

### Decision 1: keep profile schema version 2 and keep the four single-id fields

Every profile record with a schema version above 2 is treated by today's app as read-only and raises a conflict banner (`SyncApplyService.swift:376`, `RecordProvider.swift:74`). Bumping the version would therefore break the owner's other devices until they update. The schema version stays at 2.

The four single-id fields (`startNFCTagId`, `startQRCodeId`, `stopNFCTagId`, `stopQRCodeId`) stay in the model, the sync record and the CloudKit schema. They always hold the first key of the matching list, or nil when the list is empty. A device running today's app keeps matching against that first key. This is the whole compatibility story; no version negotiation is needed.

### Decision 2: the physical-unblock fields are not extended

The issue lists three roles: start, stop and physical unblock. In this codebase the physical-unblock role exists only as V1 data. `migrateToV2IfNeeded` folds `physicalUnblockNFCTagId` and `physicalUnblockQRCodeId` into the stop condition `specificNFC` or `specificQR` with the same id (`BlockedProfiles.swift:811`, `TriggerMigration.swift:60`), and no V2 editor reads or writes those two fields (`BlockedProfileView.swift` only passes them through on save). A V2 profile therefore expresses "physical unblock" as its stop list. Extending the V1 fields would add a third list nobody can edit. They stay exactly as they are, and the migration still writes the migrated id into `stopNFCTagId` or `stopQRCodeId`, which Decision 3 turns into a one-item stop list.

### Decision 3: one Codable value with four lists, stored as one JSON blob

```swift
/// A named NFC tag or QR code. `value` is the NFC hardware id or the SHA-256 hex of the QR payload.
struct PhysicalKey: Codable, Equatable, Identifiable {
  var id: UUID = UUID()
  var name: String
  var value: String
}

struct ProfilePhysicalKeys: Codable, Equatable {
  var startNFC: [PhysicalKey] = []
  var startQR: [PhysicalKey] = []
  var stopNFC: [PhysicalKey] = []
  var stopQR: [PhysicalKey] = []
}
```

Four lists rather than one list with a role and type field: each list maps to exactly one existing toggle (`specificNFC` and `specificQR` on start and stop), the matcher for a slot is `list.contains { $0.value == scanned }`, and no filtering or type enum is needed. One container rather than four separate stored fields: one SwiftData column, one CloudKit field, one equality line, one apply line.

Storage follows the existing `startSchedule` pattern (`BlockedProfiles.swift:170`): a private `physicalKeysData: Data?` column and a computed `physicalKeys: ProfilePhysicalKeys` property that decodes it. Values in a list must be unique; order is the order the user added them.

### Decision 4: migrate on read, materialize on write

`physicalKeys` getter: when `physicalKeysData` is nil, derive the value from the four single-id fields, one item per non-nil id, named "NFC tag" or "QR code". No migration pass, no schema bump, nothing to run at launch. A profile that has never been saved by the new app reads correctly, and its first save under the new app materializes the blob.

`physicalKeys` setter: encode the blob and set each single-id field to the first value of its list, or nil. Every write goes through the setter, so the two representations cannot drift on this device.

### Decision 5: sync reconciliation gives the single-id field the last word

When a record is applied (`SyncApplyService.updateLocalProfile` and `createLocalProfile`), the new field and the four single ids are combined per list with one rule:

```swift
static func reconcile(list: [PhysicalKey], legacy: String?) -> [PhysicalKey] {
  guard let legacy else { return [] }
  return list.contains { $0.value == legacy } ? list : [PhysicalKey(name: defaultName, value: legacy)]
}
```

Why this rule and not "list wins when present": a device on today's app materializes its outgoing record from cached system fields and sets only the keys it knows (`RecordProvider.swift`, `SyncedProfile.updateCKRecord`). Depending on how the server merges, the server record may or may not still carry a stale `physicalKeysData` from an earlier new-app write. The rule is correct either way. If the old device changed the tag, the new value is not in the stale list and becomes the sole item. If the old device cleared the tag, the list empties. If a new-app device wrote the record, the first list item equals the single id and the list is kept whole. Extra keys are lost only when a device on the old app edits that slot, and in that case the user asked for that one tag.

`SyncPayloadEquality.profilesPayloadEqual` compares `physicalKeys` in addition to the single ids.

### Decision 6: matching

- Start: `StrategyManager.startWithNFCTag` and `startWithQRCode` (`StrategyManager.swift:1257`) check `profile.physicalKeys.startNFC` or `.startQR` for the scanned value.
- Stop: `StartStopActionResolver.canStop` takes `stopNFCValues: [String]` and `stopQRValues: [String]` instead of two optionals and checks `contains`. Its three callers (`StrategyManager.swift:499`, `:1290`, `:1321`) pass `physicalKeys.stopNFC.map(\.value)` and the QR equivalent.
- `sameNFC` and `sameQR` keep matching the session's own start tag. The list plays no part there.
- `TriggerConfigurationModel.validate` reports the existing "Scan an NFC tag ..." errors when a specific toggle is on and its list is empty, so a profile can never be saved with a specific mode and nothing to scan.

### Decision 7: a running session whose stop key is removed

Editing is disabled while the profile is blocking on this device or on another of the owner's devices (`ProfileEditGate.editingDisabled`, `isBlocking` includes `remotelyActiveProfileIds`), so a key cannot normally be removed under a running session. If an edit and a session start race across devices, the stop check runs at scan time against the profile's current list: a removed key no longer stops the session, the remaining keys do, and the list cannot be empty while the specific toggle is on (Decision 6). Emergency Unblock remains the backstop exactly as today. No new code.

### Decision 8: editor

`StartTriggerSelector` and `StopConditionSelector` replace their single `scanRow` with a key list shown when the matching specific option is chosen:

- One row per key: a `TextField` bound to the key's name (placeholder "Name"), plus a secondary caption "NFC tag" or "QR code". Rows support swipe to delete. The whole list is disabled by the existing `disabled` flag.
- Below the rows, a bordered button "Scan tag" or "Scan code" (label becomes "Scan another tag" or "Scan another code" once the list is non-empty). It calls the existing `onScanNFCTag` or `onScanQRCode` closure.
- The scan closures in `BlockedProfileView` (`:349`, `:389`, `:762`, `:775`) append `PhysicalKey(name: "Tag N" or "Code N", value:)` where N is the list count plus one. A value already in that list is not appended; the existing error alert shows "This tag is already on the list" or the QR equivalent.
- Empty names are replaced with the default name on save.

The bindings change from `Binding<String?>` to `Binding<[PhysicalKey]>`. `TriggerConfigurationModel` replaces its four `@Published String?` with four `@Published [PhysicalKey]`, loads them from `profile.physicalKeys`, and saves by assigning `profile.physicalKeys` once.

Lock gating is inherited: the list lives inside the same editor, which a locked profile in Child mode opens only after the code is verified (`BlockedProfileView.swift:260`). No new gate.

### Decision 9: everything else

- `BlockedProfiles.cloneProfile` copies `physicalKeysData` alongside the four single ids.
- `SyncedProfile` gains `physicalKeysData: Data?`, written and read in `updateCKRecord` and `init(record:)`.
- CloudKit schema: one new field `physicalKeysData BYTES` on `SyncedProfile` in `Foqos/CloudKit/cloudkit-schema.ckdb` and `fastlane/required-prod-schema.txt`, using the routine workflow in `docs/cloudkit-production-schema.md`. Production promotion is a maintainer step before the first TestFlight build that carries this change.
- `SharedData.ProfileSnapshot` and the widget do not change; neither reads the start or stop ids.
- Debug surfaces (`ProfileDebugCard`, `DebugView`) show only the count of keys per list and their names, never values. Logs never contain key values (`Log` privacy invariant).
- The `.deepLink` stop path is untouched apart from the call-site signature change.

## Files touched

| File | Change |
|---|---|
| `Foqos/Models/PhysicalKey.swift` (new) | `PhysicalKey`, `ProfilePhysicalKeys`, `reconcile`, default names |
| `Foqos/Models/BlockedProfiles.swift` | `physicalKeysData` column, `physicalKeys` computed property, clone copy |
| `Foqos/Models/TriggerConfigurationModel.swift` | four lists, load, save, validation |
| `Foqos/Utils/StartStopActionResolver.swift` | `canStop` takes value arrays |
| `Foqos/Utils/StrategyManager.swift` | start matching, three `canStop` call sites |
| `Foqos/CloudKit/SyncModels.swift` | `physicalKeysData` field and key |
| `Foqos/CloudKit/SyncEngine/SyncApplyService.swift` | reconcile on apply |
| `Foqos/CloudKit/SyncEngine/SyncPayloadEquality.swift` | compare `physicalKeys` |
| `Foqos/CloudKit/cloudkit-schema.ckdb`, `fastlane/required-prod-schema.txt` | one field |
| `Foqos/Components/BlockedProfileView/StartTriggerSelector.swift`, `StopConditionSelector.swift` | key list UI |
| `Foqos/Views/BlockedProfileView.swift` | scan closures append |
| `Foqos/Components/Debug/ProfileDebugCard.swift`, `Foqos/Views/DebugView.swift` | counts and names |
| `FoqosTests/...` | tests below |

## Tests

Pin time per the test invariant where a date is involved; none of these need one.

`PhysicalKeyTests` (new):

1. Given a profile with only `stopNFCTagId` set and no blob, when reading `physicalKeys`, then `stopNFC` has one item with that value and the default name, and the other three lists are empty.
2. Given a profile, when assigning two stop NFC keys, then `stopNFCTagId` equals the first value and `physicalKeysData` decodes to both.
3. Given a profile, when assigning an empty stop NFC list, then `stopNFCTagId` is nil.
4. `reconcile`: legacy nil gives empty; legacy in list keeps the list intact (same ids and order); legacy not in list gives a single item with the legacy value.
5. Encoding round trip preserves `id`, `name`, `value` and order.

`StrategyManagerStopTests` (extend):

6. Given `specificNFC` with two stop values, when stopping with the second, then allowed.
7. Given `specificNFC` with two stop values, when stopping with a third, then denied with "Scan the correct NFC tag to stop".
8. Same two cases for QR.
9. Given `sameNFC`, when stopping with a tag that is on the stop list but is not the session tag, then denied (the list plays no part in same-tag mode).

`BlockedProfilesTriggersTests` (extend):

10. Given `specificNFC` on and an empty start list, when validating, then the "Scan an NFC tag to use as the start trigger" error is present; after adding a key it is absent.
11. Given a start list with a value, when adding the same value again through the editor's append helper, then the list is unchanged.

`BlockedProfilesMigrationTests` (extend):

12. Given a V1 profile with `physicalUnblockNFCTagId`, when migrating to V2, then `physicalKeys.stopNFC` has one item with that id (the existing migration plus Decision 4).

`CloneProfileTests` (extend):

13. Given a profile with two start QR keys, when cloned, then the clone has the same two keys and the same `startQRCodeId`.

Sync (extend the existing apply tests under `FoqosTests` that cover `updateLocalProfile`):

14. Given an incoming record with no `physicalKeysData` and `stopNFCTagId` set, when applied, then the local stop list is that one key.
15. Given an incoming record with two stop keys and `stopNFCTagId` equal to the first, when applied, then both keys are kept.
16. Given an incoming record with two stop keys and `stopNFCTagId` equal to neither, when applied, then the local stop list is the single legacy key.
17. `profilesPayloadEqual` returns false when only the key names differ.

Manual check on device before the builder reports done: register two NFC tags for stop, start a session, stop it with the second tag; then with a device on the previous build signed into the same account, confirm the profile still stops with the first tag.

## Implementation notes for the builder

- One feature PR from a fresh worktree on `main`, with its own version bump above whatever `main` holds at the time (`scripts/check-version-increment.sh`).
- Run the CloudKit drift reporter and checker from `docs/cloudkit-production-schema.md` and include their output in the PR.
- Add the `greptile-review` label once, when the PR is ready to merge after the reviewer's exact-head findings are addressed, never at open time; each later push triggers a paid re-review.
