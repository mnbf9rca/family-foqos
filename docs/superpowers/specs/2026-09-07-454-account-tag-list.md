# Issue #454: Account-Wide Tag List for Profiles

## Status and scope

Design for issue #454. Base: `main` at `40c3128`. Supersedes `2026-09-07-454-multiple-physical-keys.md` and the implementation in PR #465; the maintainer's rulings of September 7, 2026 replace that design.

Today a profile holds one NFC tag id and one QR code id for starting and one of each for stopping (`startNFCTagId`, `startQRCodeId`, `stopNFCTagId`, `stopQRCodeId` in `Foqos/Models/BlockedProfiles.swift`). This design replaces those four text fields with four lists of references into one account-wide list of named tags. "Tag" below means an NFC tag or a QR code; both use the same mechanism.

In scope: the tag list and its Settings screen, the profile references and their picker, profile schema version 3, the one-time migration, the sync record type, and the matching change. Out of scope: the scanner, the family share, lock codes, and the app-group snapshot.

"Physical unblock" is the V1 name for the tag that must be scanned to stop a profile. The existing V1-to-V2 migration already folds it into the stop condition (`migratePhysicalUnlock` in `Foqos/Utils/TriggerMigration.swift`), and the version-2 editor has no separate physical-unblock role. Version 3 therefore has two roles, start and stop, and the V1 physical-unblock fields reach the stop lists through that existing step.

## Product behaviour

- Settings gains a **Tags** screen. You add a tag by scanning it, give it a name, and can rename or remove it later. A tag that any profile uses cannot be removed; it can still be renamed.
- In the profile editor, choosing "Specific tag" for NFC (or "Specific code" for QR) shows the account's tags of that kind with checkmarks. You tick as many as you like. A "Scan new tag" row adds a tag to the account list and ticks it, so you never have to leave the editor to register a tag.
- Scanning any ticked tag starts or stops the profile. Nothing else about scanning changes.
- The tag list and the references sync between your own devices with your profiles. Nothing crosses the family share.
- There is no lock on the Tags screen. A locked profile cannot be opened for editing on a Child device, so its tag assignments cannot change, and an assigned tag cannot be removed. That is the whole protection.
- A device on the App Store V1 build or an earlier V2 build shows a version-3 profile as "Update app to edit" and hides its Start and Stop actions (`BlockedProfileCard.swift:61`, `:114`; the same gate exists at tag `v1.31.3`). That existing behaviour is the whole compatibility story.

## Data model

### Tag (new SwiftData model `SavedTag`)

| Field | Type | Meaning |
|---|---|---|
| `id` | `String`, `@Attribute(.unique)` | The scanned value: the NFC hardware id (hex, from `NFCScannerUtil`) or the SHA-256 hex of the QR payload (`QRCodeHasher.hash`, applied by `PhysicalReader.readQRCode`). Exactly the value the profile fields hold today. |
| `kind` | `String` | `"nfc"` or `"qr"`. Labels the row and filters the per-role picker. |
| `name` | `String` | User-facing name. |
| `createdAt`, `updatedAt` | `Date` | As `SavedLocation`. |
| `syncVersion` | `Int` | As `SavedLocation`. |

Using the scanned value as the id is what makes deduplication free: `findOrCreate(id:kind:name:in:)` returns the existing row for a value that is already on the list, two devices that migrate the same profile independently produce the same row, and a profile reference is the value itself. Static helpers mirror `SavedLocation`: `fetchAll`, `find(byID:)`, `findOrCreate`, `delete`, plus `assignments(profiles:) -> [String: [String]]` (tag id to the names of the profiles whose four lists contain it), a pure function like `SavedLocationsView.locationsInUse`. Add `SavedTag.self` to the schema list in `Foqos/Utils/AppModelStore.swift`.

### Profile version 3

`BlockedProfiles.currentSchemaVersion` becomes 3. Four new stored properties, each `[String]` defaulting to `[]`, hold tag ids: `startNFCTagIds`, `startQRCodeIds`, `stopNFCTagIds`, `stopQRCodeIds`. SwiftData stores string arrays directly (`domains` is the precedent). Order is selection order and has no meaning.

The six legacy single-id properties (`startNFCTagId`, `startQRCodeId`, `stopNFCTagId`, `stopQRCodeId`, `physicalUnblockNFCTagId`, `physicalUnblockQRCodeId`) stay declared on the SwiftData model only because the one-time migration has to read them from rows written by older builds; dropping the columns would destroy that data before the migration runs. After migration they are nil. No code reads them except the migration, and no code writes them except the migration setting them to nil. `SyncedProfile` (`Foqos/CloudKit/SyncModels.swift`) gains the four list fields; `updateCKRecord` writes the six legacy keys only while `profileSchemaVersion < 3` (a V1 profile whose migration is deferred by an active session still uploads as V1, exactly as today) and `init(record:)` still decodes them so an incoming older record can be migrated. `SyncPayloadEquality.profilesPayloadEqual` compares the four lists and drops the six legacy comparisons. `cloneProfile` copies the four lists (the source is migrated first, as today).

### CloudKit additions

All in the per-account private database, `DeviceSync` zone, with the same grants as `SyncedLocation`:

- New record type `SyncedTag`: `tagId STRING QUERYABLE SEARCHABLE`, `kind STRING`, `name STRING QUERYABLE SEARCHABLE SORTABLE`, `generation INT64`, `lastModified TIMESTAMP QUERYABLE SORTABLE`. Record name `SavedTag_<tagId>`; the prefix routes the record in `RecordProvider.materialize` and `SyncEngineController` the way `ProfileSession_` does, because those paths otherwise parse the record name as a UUID.
- `SyncedProfile` gains `startNFCTagIds LIST<STRING>`, `startQRCodeIds LIST<STRING>`, `stopNFCTagIds LIST<STRING>`, `stopQRCodeIds LIST<STRING>`.
- The six legacy `SyncedProfile` fields stay declared: Production schema changes are additive-only.

The builder updates `Foqos/CloudKit/cloudkit-schema.ckdb` and `fastlane/required-prod-schema.txt` and runs the drift reporter and schema checker from `docs/cloudkit-production-schema.md` section 1 (the reporter finds `SyncedTag` automatically because it lives in `SyncModels.swift`). **Production promotion is a maintainer step** (section 2 of that document): import the checked-in schema into Development, deploy the additive diff to Production, run `scripts/check-prod-schema.sh`, all before the first TestFlight build that carries this change.

### Sync touchpoints

`SyncedTag` mirrors `SyncedLocation` at every site; no new mechanism:

| Site | Change |
|---|---|
| `SyncApplyService` | Route `SyncedTag` modifications (client-clock merge: apply when `lastModified > updatedAt`, else no-op) and deletions (delete watermark, then delete the row). Include `SyncedTag` in `generationFieldKey`. **No reference repair on deletion**; see "Running session" below. |
| `RecordProvider.materialize` | `SavedTag_` prefix produces a `SyncedTag` record with the establishment generation. |
| `SyncEngineController` | Add `SyncedTag` to `scopedTypes`, the server-conflict comparison (by `lastModified`), the local-existence check, and `restorableRecordNames` seeding. |
| `MutationFunnel` | `enqueueSave(tagId:)` advances `updatedAt` and enqueues one save; `enqueueDelete(tagId:)` writes the tombstone and enqueues one delete. |
| `SyncEngineControlling`, `SyncEngineController+Cutover`, `ProfileSyncManager` | `enqueueTagSave` / `enqueueTagDelete` with the same pre-attach deferral as locations; the wipe and reset paths delete all tags alongside all locations. |
| `SyncDiagnostics` | `tagApply`, `tagDeletionApplied`, `localTagSaveEnqueued`. |

## Migration

One function, `migrateIfEligible(hasActiveSession:)`, replaces `migrateToV2IfEligible` at its existing call sites (`ProfileMigrationUtil` at launch and from `StrategyManager.swift:147`, `TriggerConfigurationModel.loadFromProfile`, `StrategyManager.swift:953` at session end, `cloneProfile`, `updateProfile`). It runs the existing V1-to-V2 step under the existing rule (skipped while the profile has an active session), then the V2-to-V3 step whenever the profile is at version 2. The V3 step is safe during an active session: it moves the same ids into lists and changes no trigger flag, so a stop check after it reads the same tag.

The V2-to-V3 step, on a profile at version 2 with a `modelContext`:

1. For each of the four pairs (`startNFCTagId` to `startNFCTagIds` kind `nfc` role "start", `startQRCodeId` to `startQRCodeIds` kind `qr` role "start", `stopNFCTagId` to `stopNFCTagIds` kind `nfc` role "stop", `stopQRCodeId` to `stopQRCodeIds` kind `qr` role "stop"): when the legacy value is non-empty, `SavedTag.findOrCreate(id: value, kind:, name: "<profile name> <role> tag")` (or "... code" for QR) and set the list to `[value]`. A value already on the list is reused, so one physical tag used by three profiles is one entry with three references, named after the first profile migrated.
2. Set all six legacy properties to nil.
3. Set `profileSchemaVersion = 3`.

Without a `modelContext` the step logs and returns; the profile stays at version 2 and the next pass retries. Running the step twice is a no-op.

The path is identical for a V1 App Store device updating straight to this build and for a V2 device updating from an earlier build: the V1 step produces version-2 fields (including the physical-unblock tag folded into `stopNFCTagId` or `stopQRCodeId`), and the V3 step consumes them. Every profile on the device is migrated by the launch pass; a profile deferred by an active session is migrated at session end, as today.

**Incoming older records.** A profile created on a device that still runs an earlier build arrives as a version-2 record. `createLocalProfile` and `updateLocalProfile` copy its fields as today and then run the V3 step, so the profile is usable before the next launch. The migrated profile and any tags the step created are appended to `pendingReenqueues` so the server copy becomes version 3 at once, mirroring the existing `local_schema_newer_reenqueue` branch. An older device that later edits that profile hits the existing "local schema newer" branch: conflict banner and auto-heal re-upload, unchanged.

**Upload after the launch pass.** `ProfileMigrationUtil` enqueues a profile save for each profile it migrated and a tag save for each tag the step created, through `ProfileSyncManager`, which already defers both until the engine attaches. Devices that migrate the same profile independently produce the same tag rows and the same references, so the order in which they upload does not matter.

## Matching

Only the comparison site changes, from equality with one id to membership of the profile's list for that role and kind:

- Start: `StrategyManager.startWithNFCTag` checks `profile.startNFCTagIds.contains(tagId)`; `startWithQRCode` checks `profile.startQRCodeIds.contains(codeValue)`. Error messages unchanged.
- Stop: `StartStopActionResolver.canStop` takes `stopNFCTagIds: [String]` and `stopQRCodeIds: [String]` and checks `contains`. Its three callers (`StrategyManager.swift:498`, `:1288`, `:1319`) pass the profile's lists. Messages unchanged. `sameNFC` and `sameQR` still compare with the session's own start tag.
- Validation: `TriggerConfigurationModel` holds four `@Published [String]` instead of four optionals, and `validate` reports the existing "Scan an NFC tag to use as the start trigger" family of errors when a specific toggle is on and its list is empty. A profile can never be saved with a specific toggle on and nothing to scan.

## Running session whose stop tag is unassigned

- On this device it cannot happen. The editor is disabled while the profile is blocking here or on another of the account's devices (`ProfileEditGate.editingDisabled`; `isBlocking` includes `remotelyActiveProfileIds`), and the Tags screen refuses to remove a tag that any profile references.
- If another device edits the profile before it learns the session started, the applied record replaces the lists, and the stop check reads the current list at scan time, exactly as it reads the single id today. Validation keeps the list non-empty while the specific toggle is on. Emergency Unblock remains the backstop. No new code.
- If another device removes a tag from the list while its copy of the profiles was stale, the tag row is deleted here but the profile keeps the id in its list. Scanning that physical tag still stops the session, because the check compares scanned values with the list, not with tag rows. This is why the remote-deletion path does not repair references the way location deletion does (`SyncApplyService.deleteLocalLocation`): a repair could strip the only stop tag from a running profile. The editor shows such an id as a "Removed tag" row that the user can untick when the profile is next editable.

## Settings: Tags screen

Presented as a sheet from a new **Tags** section in `SettingsView`, directly below the Location section, following `SavedLocationsView`. No lock code, no mode check.

```
Settings
┌────────────────────────────────────────────┐
│ Location                                   │
│  📍 Saved Locations                      › │
├────────────────────────────────────────────┤
│ Tags                                       │
│  🏷 Tags                                 › │
│  Name the NFC tags and QR codes your       │
│  profiles start and stop with.             │
└────────────────────────────────────────────┘
```

List, empty and populated:

```
✕  Tags                                    +

┌────────────────────────────────────────────┐
│                                            │
│              ⊘  No Tags                    │
│   Scan an NFC tag or QR code to add it.    │
│                                            │
│            [ + Add Tag ]                   │
└────────────────────────────────────────────┘

✕  Tags                                    +

Your Tags
┌────────────────────────────────────────────┐
│ Kitchen                                  › │
│ NFC tag · Used by Homework, Bedtime        │
├────────────────────────────────────────────┤
│ Dad's house                              › │
│ NFC tag · Used by Homework                 │
├────────────────────────────────────────────┤
│ Printed card                             › │
│ QR code · Not used                         │
└────────────────────────────────────────────┘
Tags a profile uses can be renamed but not
removed. Edit the profile to stop using a tag.
```

Add and name flow. The `+` button (or the empty-state button) offers the two scanners; on a successful scan the name sheet opens prefilled with "NFC tag N" or "QR code N", where N is one more than the number of tags of that kind. Save creates the tag, saves the context, and enqueues a tag save. Scanning a value that is already on the list shows an alert instead of the name sheet.

```
      ┌──────────────────────────┐
      │  Scan NFC tag            │
      │  Scan QR code            │
      │  Cancel                  │
      └──────────────────────────┘
            │ (existing NFC or QR scanner)
            ▼
Cancel  Name Tag                         Save
┌────────────────────────────────────────────┐
│ Name   [ NFC tag 3                      ]  │
└────────────────────────────────────────────┘
NFC tag. Pick a name you will recognise on
the profile screen.

      ┌──────────────────────────────┐
      │  Already added               │
      │  This tag is already on your │
      │  list as "Kitchen".          │
      │             OK               │
      └──────────────────────────────┘
```

Rename and remove. Tapping a row opens the edit sheet. Save renames (enqueues a tag save). Remove asks for confirmation, then deletes through the funnel (`enqueueTagDelete`, with the same not-attached and sync-disabled fallbacks as `SavedLocationsView.deleteLocation`). When any profile uses the tag, the Remove button is disabled and the footer names the profiles.

```
Cancel  Edit Tag                         Save
┌────────────────────────────────────────────┐
│ Name   [ Printed card                   ]  │
└────────────────────────────────────────────┘
QR code · Not used by any profile
┌────────────────────────────────────────────┐
│              Remove Tag                    │   (red)
└────────────────────────────────────────────┘

Cancel  Edit Tag                         Save
┌────────────────────────────────────────────┐
│ Name   [ Kitchen                        ]  │
└────────────────────────────────────────────┘
NFC tag · Used by Homework, Bedtime
┌────────────────────────────────────────────┐
│              Remove Tag                    │   (greyed out)
└────────────────────────────────────────────┘
This tag cannot be removed while Homework and
Bedtime use it. Edit those profiles first.

      ┌──────────────────────────────┐
      │  Remove "Printed card"?      │
      │  Profiles cannot use it      │
      │  afterwards.                 │
      │      Cancel      Remove      │
      └──────────────────────────────┘
```

## Profile editor: picker per role

`StartTriggerSelector` and `StopConditionSelector` replace their single `scanRow` with the same tag rows, shown when the matching specific option is chosen. The rows list the account's tags of that kind (passed in from `BlockedProfileView`'s query as `(id, name)` values, the way `savedLocations` is passed to the geofence selector), tick the ids in the bound list, and end with a "Scan new tag" row. Tapping a row toggles the id. Tapping "Scan new tag" runs the existing scanner closure; on success the profile view calls `SavedTag.findOrCreate` with the auto name, enqueues the tag save, and appends the id to the bound list. An id in the list with no matching tag row renders as "Removed tag". The whole block honours the existing `disabled` flag.

```
Start by...
┌────────────────────────────────────────────┐
│ Tap to start                          [ON] │
│ NFC                       Specific tag  ⌄  │
│   ✓ Kitchen                                │
│   ✓ Dad's house                            │
│     Spare tag                              │
│   ✓ Removed tag                            │   (id kept from a tag deleted elsewhere)
│   + Scan new tag                           │
│ QR                                None  ⌄  │
│ Schedule                             [OFF] │
│ Written NFC / printed QR             [OFF] │
└────────────────────────────────────────────┘

Continue until...
┌────────────────────────────────────────────┐
│ Tap to stop                          [OFF] │
│ Timer                                [OFF] │
│ NFC                       Specific tag  ⌄  │
│     Kitchen                                │
│     Dad's house                            │
│     Spare tag                              │
│   + Scan new tag                           │
│ QR                       Specific code  ⌄  │
│   ✓ Printed card                           │
│   + Scan new code                          │
│ Schedule                             [OFF] │
└────────────────────────────────────────────┘
  Scan an NFC tag to use as the stop condition   (red; list is empty)
```

Lock gating is inherited: a locked profile in Child mode opens the editor only after the code is verified (`BlockedProfileView.swift:264`). No new gate.

## Everything else

- `ProfileDebugCard` and `DebugView` show the count of tags per list and their names, never ids. Logs never contain tag ids (`Log` privacy invariant; `NFCScannerUtil` already redacts). The `DebugRedaction` helpers for the physical-unblock ids lose their callers and are deleted.
- `SharedData.ProfileSnapshot` and the widget do not change; the snapshot's physical-unblock fields are nil for migrated profiles, which only lowers the widget's cosmetic "enabled options" tally by one for profiles that had a V1 unblock tag.
- The `.deepLink` stop path changes only at its `canStop` call.

## Files touched

| File | Change |
|---|---|
| `Foqos/Models/SavedTag.swift` (new) | Model, `findOrCreate`, `assignments`, delete |
| `Foqos/Utils/AppModelStore.swift` | Add `SavedTag.self` |
| `Foqos/Models/BlockedProfiles.swift` | Four list properties, version 3, `migrateIfEligible`, V3 step, clone |
| `Foqos/Utils/ProfileMigrationUtil.swift` | Call the new function; enqueue profile and tag saves |
| `Foqos/Models/TriggerConfigurationModel.swift` | Four lists, load, save, validation |
| `Foqos/Utils/StartStopActionResolver.swift` | `canStop` takes lists |
| `Foqos/Utils/StrategyManager.swift` | Start matching, three `canStop` call sites, session-end migration call |
| `Foqos/CloudKit/SyncModels.swift` | `SyncedTag`; four list fields on `SyncedProfile`; legacy keys written only below version 3 |
| `Foqos/CloudKit/SyncEngine/SyncApplyService.swift` | Tag modification and deletion; V3 step after create/update; re-enqueue |
| `Foqos/CloudKit/SyncEngine/RecordProvider.swift`, `SyncEngineController.swift`, `SyncEngineController+Cutover.swift`, `SyncEngineControlling.swift`, `MutationFunnel.swift`, `SyncPayloadEquality.swift` | `SyncedTag` at each site listed above |
| `Foqos/CloudKit/ProfileSyncManager.swift` | `enqueueTagSave`, `enqueueTagDelete`, deferral, wipe and reset |
| `Foqos/CloudKit/cloudkit-schema.ckdb`, `fastlane/required-prod-schema.txt` | `SyncedTag`; four fields |
| `Foqos/Views/TagsView.swift` (new), `Foqos/Views/EditTagView.swift` (new) | Tags screen, name and edit sheets |
| `Foqos/Views/SettingsView.swift` | Tags section and sheet |
| `Foqos/Components/BlockedProfileView/StartTriggerSelector.swift`, `StopConditionSelector.swift`, `TagPickerRows.swift` (new) | Picker rows |
| `Foqos/Views/BlockedProfileView.swift` | Query tags; scan-new closures create a tag and append its id |
| `Foqos/Components/Debug/ProfileDebugCard.swift`, `Foqos/Views/DebugView.swift`, `Foqos/Components/Debug/DebugRedaction.swift` | Counts and names |
| `FoqosTests/...` | Tests below |

## Tests

Pin time per the test invariant where a date is involved; none of these need one.

`SavedTagTests` (new):

1. Given an empty list, when `findOrCreate` runs with a value, then one row exists with that id, kind and name; when it runs again with the same value and a different name, then the same row is returned and the name is unchanged.
2. Given three profiles whose lists share one id and one profile with a different id, when `assignments` runs, then the shared id maps to the three profile names and the other id to one name; an id in no list is absent.

`BlockedProfilesMigrationTests` (extend):

3. Given a version-2 profile with all four single ids set, when migrated, then each list holds its id, four tag rows exist with the expected kinds and auto names, the six legacy fields are nil, and the version is 3.
4. Given two version-2 profiles with the same `stopNFCTagId`, when both are migrated, then one tag row exists and both stop lists hold its id.
5. Given a version-1 profile with `physicalUnblockNFCTagId` and no active session, when migrated, then `stopConditions.specificNFC` is on, `stopNFCTagIds` holds that id, and the version is 3. Same for `physicalUnblockQRCodeId`, with the SHA-256 hex of the value.
6. Given a version-1 profile with an active session, when migrated, then it stays at version 1 (existing deferral). Given a version-2 profile with an active session, when migrated, then it reaches version 3.
7. Given a version-3 profile, when migrated again, then nothing changes.
8. Given a version-2 profile with no `modelContext`, when migrated, then it stays at version 2.
9. Existing `isNewerSchemaVersion` tests updated for version 3 as current.

`StrategyManagerStartTests` (extend, from PR #465):

10. Given `specificNFC` with two ids in `startNFCTagIds`, when starting with the second, then it starts; with an id not in the list, then the "doesn't match" error is set and no session starts.
11. Same two cases for `specificQR` and `startQRCodeIds`.

`StrategyManagerStopTests` (extend, from PR #465):

12. Given `specificNFC` with two ids, when stopping with the second, then allowed; with an id not in the list, then denied with "Scan the correct NFC tag to stop".
13. Same for `specificQR` with "Scan the correct QR code to stop".
14. Given `sameNFC`, when stopping with a tag that is in the stop list but is not the session tag, then denied. Same for `sameQR`.

`BlockedProfilesTriggersTests` (extend):

15. Given `specificNFC` on and an empty `startNFCTagIds`, when validating, then "Scan an NFC tag to use as the start trigger" is present; after appending an id it is absent. Same for the stop list and for QR on both sides.
16. Given a model loaded from a version-3 profile, when saved to another profile, then the four lists round-trip.

`CloneProfileTests` (extend):

17. Given a profile with two ids in `startQRCodeIds`, when cloned, then the clone has the same two ids.

`SyncApplyServiceTests` (extend):

18. Given no local profile and an incoming version-2 record with `stopNFCTagId` X, when applied, then the created profile is version 3 with `stopNFCTagIds == [X]`, a tag row X exists, and the profile and the tag are re-enqueued.
19. Given a local version-3 profile and an incoming version-2 record (an older device's stale edit), when applied, then the existing "local schema newer" branch runs: conflict recorded, local re-enqueued, local lists untouched.
20. Given an incoming `SyncedTag` record newer than the local row, when applied, then the name updates; when older or equal, then no-op.
21. Given an incoming `SyncedTag` deletion for a tag that a local profile references, when applied, then the row is deleted, the profile's list still holds the id, and nothing is re-enqueued.
22. Given identical version-3 records, when applied twice, then the second apply is a payload-equal no-op; `profilesPayloadEqual` is false when one list differs.

`RecordProviderTests` and `SyncEngineControllerTests` (extend):

23. Given a local tag, when materialized for `SavedTag_<id>`, then a `SyncedTag` record with the establishment generation is produced; `restorableRecordNames` includes it.
24. Given a version-1 profile whose migration is deferred, when materialized, then the record carries the legacy keys; given a version-3 profile, then it carries the four lists and none of the six legacy keys.

`MutationFunnelTests` (extend):

25. `enqueueSave(tagId:)` advances `updatedAt` and enqueues one save; `enqueueDelete(tagId:)` writes the tombstone and enqueues one delete; a missing tag throws `entityNotFound`.

`CloudKitCodeSchemaDriftTests`, `check-cloudkit-schema-export` harness: updated for the new type and fields; reporter prints `OK: no CloudKit schema drift.`.

Device check, required before the builder reports done, two devices on this build signed into the same account:

26. Add a tag on device A; it appears on device B with the same name. Rename on B; A updates.
27. Assign the tag to a profile on A; on B the Tags screen shows it as used and Remove is disabled. Untick it on A; B can remove it; A's list no longer shows it.
28. Register two stop tags for a profile; start a session and stop it with the second tag.
29. Update a device from the previous build with a profile that had a stop tag: after launch the profile is version 3, the tag is on the Tags screen with the auto name, and scanning it still stops the profile.
30. On a device left on the previous build, the version-3 profile shows "Update app to edit" with no Start action.

## Reuse from PR #465

Reusable as-is or with a rename only: the `StrategyManagerStartTests` cases (set `startNFCTagIds` instead of `physicalKeys`), the `StrategyManagerStopTests` signature update (`stopNFCTagIds: [String]` instead of `stopNFCValues`), the `StartStopActionResolver.canStop` list signature and its three call-site edits, the `startWithNFCTag` and `startWithQRCode` `contains` checks, the validation-error test shape in `BlockedProfilesTriggersTests`, and the `ProfileDebugCard` and `DebugView` counts-and-names change.

Adapted, not as-is: the scan closures in `BlockedProfileView` keep their structure (`nfcScanner.onTagScanned`, the two QR scanner sheets) but their bodies now create a `SavedTag` and append its id.

Not reusable: `PhysicalKey` and `ProfilePhysicalKeys` (per-profile named keys in a JSON blob), `PhysicalKeyRows` (per-profile name fields; replaced by the picker), `TriggerConfigurationModel.appendKey`, the `reconcile` function and every sync-reconciliation change in `SyncApplyService`, `SyncPayloadEquality` and `MutationFunnel`, `PhysicalKeyTests`, the `SyncApplyServiceTests` additions, and the migration tests about a materialized blob.

## Implementation notes for the builder

- One feature PR from a fresh worktree on `main`, with its own version bump above whatever `main` holds at the time (`scripts/check-version-increment.sh`).
- Run the CloudKit drift reporter and checker from `docs/cloudkit-production-schema.md` and include their output in the PR. Production promotion is the maintainer's step before the first dependent TestFlight build.
- Add the `greptile-review` label once, when the PR is ready to merge after the reviewer's exact-head findings are addressed, never at open time; each later push triggers a paid re-review.
