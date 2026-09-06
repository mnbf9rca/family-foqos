# Issue #454 Several Named NFC Tags and QR Codes per Profile

## Status and scope

Design for issue #454. Base: `main` at `3034c03`. Revision 4, after the orchestrator's ruling on the mixed-version fallback and the reviewer's second adversarial round. Changes from revision 3: the orchestrator rejected accepting spare-key loss and ruled the keep-local rule in Decision 5 (new writers always send the list field; a record without it is an old app's write and the reader keeps its local list, applying only the single id); the reader re-enqueues a save in that case so the server regains the field; tests 21 to 28 and device checks 29 to 33 follow the rule. Changes from revision 2: device check 32 expects retained keys with matching disabled, a separate apply test covers a nil single id clearing the list, and Decision 5 says a nil single id means no configured key. Changes from revision 1: key identity is the value, not a generated UUID; the sync rule compares the single id with the first list value, not list membership; the test list covers start matching, QR parity, validation, migration and malformed input.

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
  var name: String
  var value: String
  var id: String { value }
}

struct ProfilePhysicalKeys: Codable, Equatable {
  var startNFC: [PhysicalKey] = []
  var startQR: [PhysicalKey] = []
  var stopNFC: [PhysicalKey] = []
  var stopQR: [PhysicalKey] = []
}
```

Four lists rather than one list with a role and type field: each list maps to exactly one existing toggle (`specificNFC` and `specificQR` on start and stop), the matcher for a slot is `list.contains { $0.value == scanned }`, and no filtering or type enum is needed. One container rather than four separate stored fields: one SwiftData column, one CloudKit field, one equality line, one apply line.

The key's identity is its value. Values within a list are unique, so `Identifiable` needs no generated id, two reads of the same data compare equal, and SwiftUI row identity is stable across reads. A rename does not change identity.

Storage follows the existing `startSchedule` pattern (`BlockedProfiles.swift:170`): a private `physicalKeysData: Data?` column and a computed `physicalKeys: ProfilePhysicalKeys` property that decodes it. Order is the order the user added them. `ProfilePhysicalKeys.normalized()` drops keys whose value is empty after trimming and drops later duplicates of a value; the setter and the sync apply path always store the normalized form.

### Decision 4: migrate on read, materialize on write

`physicalKeys` getter: when `physicalKeysData` is nil, or fails to decode (log the error under `.sync` and treat as nil), derive the value from the four single-id fields, one item per non-nil id, named "NFC tag" or "QR code". The derivation is deterministic: repeated reads return equal values. No migration pass, no schema bump, nothing to run at launch. A profile that has never been saved by the new app reads correctly, and its first save under the new app materializes the blob.

`physicalKeys` setter: encode the blob and set each single-id field to the first value of its list, or nil. Every write goes through the setter, so the two representations cannot drift on this device.

### Decision 5: sync reconciliation, ruled by the orchestrator on September 7, 2026

Two facts drive the rule. New writers always encode `physicalKeysData`, even when every list is empty, so a record without the field was last written by an app that predates this design. Old writers carry only the four single ids, and they only ever change a single id by scanning a new tag; they never clear one (see Decision 8).

When a record is applied (`SyncApplyService.updateLocalProfile` and `createLocalProfile`), for each of the four slots:

```swift
/// `base` is the decoded incoming list when the record carries the field, otherwise the reader's
/// current local list (empty for a profile the reader does not have yet).
static func reconcile(base: [PhysicalKey], legacy: String?) -> [PhysicalKey] {
  guard let legacy else { return [] }
  if base.first?.value == legacy { return base }
  let promoted = base.first { $0.value == legacy } ?? PhysicalKey(name: defaultName, value: legacy)
  return [promoted] + base.filter { $0.value != legacy }
}
```

- Single id nil: no key has ever been stored for this slot; the list is empty. The converse does not hold: switching a specific option off keeps the stored id, so a list can be present while its toggle is off, exactly as the single id is today.
- Single id equals the first value of `base`: nothing changed in this slot; the list is kept whole.
- Single id differs from the first value: an old app scanned a different tag for this slot. That tag becomes the primary key, keeping its name if it was already on the list, and the other keys stay as spares. New writers always set the single id to the first value, so this branch is reached only by an old app's edit.

`base` when the field is absent is the reader's local list, not an empty list, because the old writer did not see the spares and its record says nothing about them. When the field is present it is trusted as written, whether it is fresh from a new app or left on the server by an earlier new-app write that an old app's changed-keys save did not touch. The same function handles both, so the reader never has to know which transport case it is in.

**Regaining the field after an old app's write.** If the field was absent and the reconciled lists differ from what the record alone would yield, the reader enqueues a profile save after applying, following the existing re-enqueue branch in `SyncApplyService` (`local_schema_newer_reenqueue`) and the whitelisted enqueue sites the commit guard enforces. The server record then carries the list again, and a device that fetches the profile fresh does not see a collapsed list. The reader's own echo is dropped by the existing last-modified-by filter, so this cannot loop.

`SyncPayloadEquality.profilesPayloadEqual` compares `physicalKeys` in addition to the single ids. Because identity is the value, an unchanged record compares equal and is a no-op.

**Transport, for the record.** Outgoing records are rebuilt from cached CloudKit system fields (`RecordProvider.materialize`, `CKRecordSystemFieldsCodec`, `CKRecord(coder:)`), which carry the server change tag and no field values, and `SyncedProfile.updateCKRecord` sets only the keys that app version knows. The sync engine saves with change-tag checking (it handles `serverRecordChanged`, `SyncEngineController.swift:266`), and under CloudKit's `ifServerRecordUnchanged` policy only the keys set on the local record object are sent, so an old app's write most likely leaves the field on the server. The rule above does not depend on that: it is correct whether the field survives or is dropped. The device check below confirms the rule; it no longer decides whether any loss is acceptable, because none is.

Stamping a higher schema version on multi-key profiles was considered and rejected: an old app hides the start and stop actions on such profiles (`BlockedProfileCard.swift:61`), which would make the profile unusable on that device.

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
2. Given the same profile, when reading `physicalKeys` twice, then the two values are equal.
3. Given a profile, when assigning two stop NFC keys, then `stopNFCTagId` equals the first value and `physicalKeysData` decodes to both, in order.
4. Given a profile, when assigning an empty stop NFC list, then `stopNFCTagId` is nil.
5. Given a profile whose `physicalKeysData` is not valid JSON, when reading `physicalKeys`, then the value derives from the single ids as in test 1.
6. `normalized()`: drops a key whose value is empty or whitespace; drops the second of two keys with the same value and keeps the first's name.
7. `reconcile`: legacy nil gives empty; legacy equal to the first value keeps the list intact (same values, names and order); legacy equal to a later value gives that single key with its existing name; legacy absent from the list gives a single key with the default name; empty list with legacy set gives that single key.
8. Encoding round trip preserves names, values and order.

`StrategyManagerStopTests` (extend):

9. Given `specificNFC` with two stop values, when stopping with the second, then allowed.
10. Given `specificNFC` with two stop values, when stopping with a value not on the list, then denied with "Scan the correct NFC tag to stop".
11. Given `specificQR` with two stop values, when stopping with the second, then allowed; with a value not on the list, then denied with "Scan the correct QR code to stop".
12. Given `sameNFC`, when stopping with a tag that is on the stop list but is not the session tag, then denied. Same for `sameQR`.

Start matching (new `StrategyManagerStartMatchingTests`, or extend the existing start tests, exercising the matcher `StrategyManager` uses):

13. Given `specificNFC` with two start values, when starting with the second, then it starts; with a value not on the list, then the "doesn't match" error is set and no session starts.
14. Same two cases for `specificQR`.

`BlockedProfilesTriggersTests` (extend):

15. Given `specificNFC` on and an empty start list, when validating, then the "Scan an NFC tag to use as the start trigger" error is present; after adding a key it is absent. Same for the stop list and for QR on both sides.
16. Given a start list with a value, when adding the same value again through the editor's append helper, then the list is unchanged and the duplicate message is reported.
17. Given a key with an empty name, when saving, then the stored name is the default name.

`BlockedProfilesMigrationTests` (extend):

18. Given a V1 profile with `physicalUnblockNFCTagId`, when migrating to V2, then `physicalKeys.stopNFC` has one item with that id.
19. Given a V1 profile with `physicalUnblockQRCodeId`, when migrating to V2, then `physicalKeys.stopQR` has one item whose value is the SHA-256 of that id.

`CloneProfileTests` (extend):

20. Given a profile with two start QR keys, when cloned, then the clone has the same two keys and the same `startQRCodeId`.

Sync (extend the existing apply tests under `FoqosTests` that cover `updateLocalProfile` and `createLocalProfile`):

21. Given no local profile and an incoming record with no `physicalKeysData` and `stopNFCTagId` set, when applied, then the created profile's stop list is that one key with the default name.
22. Given a local profile with stop keys X and Y and an incoming record with no `physicalKeysData` and `stopNFCTagId` X, when applied, then the local stop list is still X and Y in that order, and a profile save is enqueued.
23. Given a local profile with stop keys X and Y and an incoming record with no `physicalKeysData` and `stopNFCTagId` Z, when applied, then the local stop list is Z (default name), X, Y, and a profile save is enqueued.
24. Given an incoming record whose blob has X and Y and whose `stopNFCTagId` is X, when applied, then both keys are kept in order and no save is enqueued.
25. Given an incoming record whose blob has X and Y and whose `stopNFCTagId` is Y, when applied, then the local stop list is Y (with its name from the blob), X.
26. Given an incoming record whose blob has X and Y and whose `stopNFCTagId` is nil, when applied, then the local stop list is empty. Sync is the only path that clears a list; no editor action clears a stored id today.
27. Given an incoming record identical to the local profile, when applied twice, then the second apply is a no-op, no save is enqueued, and `profilesPayloadEqual` is true; it returns false when only a key name differs.
28. Given a new profile with no keys, when materialized as a `SyncedProfile`, then `physicalKeysData` is non-nil and decodes to four empty lists.

Device check, required before the builder reports done, with one device on this build and one on the previous build signed into the same account:

29. On the new build, register two NFC tags for stop. Start a session and stop it with the second tag.
30. On the old build, confirm the profile stops with the first tag.
31. On the old build, rename the profile. On the new build, confirm both keys are still present and that the server record carries `physicalKeysData` afterwards (visible in the CloudKit dashboard for the Development environment).
32. On the old build, change the stop tag to a third tag. On the new build, confirm the stop list is the third tag first, then the original two.
33. On the old build, switch the NFC stop option from the specific tag to "Any" or off. Today's editor keeps the stored id when the option changes (`NFCStopOption.apply` flips only the flags), so on the new build confirm the stop option is off, the list is unchanged, and switching back to the specific option shows the same keys.

## Implementation notes for the builder

- One feature PR from a fresh worktree on `main`, with its own version bump above whatever `main` holds at the time (`scripts/check-version-increment.sh`).
- Run the CloudKit drift reporter and checker from `docs/cloudkit-production-schema.md` and include their output in the PR.
- Add the `greptile-review` label once, when the PR is ready to merge after the reviewer's exact-head findings are addressed, never at open time; each later push triggers a paid re-review.
