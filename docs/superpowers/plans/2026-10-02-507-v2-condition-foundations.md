# V2 condition foundations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. `build1` implements in its assigned feature worktree; fleet review runs through `reviewer`. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver #507's first reservation row: #520 single-value tag stops, #511 independent editor selections, #493 save/clone rules, #509 saved timer settings, and authoritative V1 conversion.

**Architecture:** Keep stop-owned settings in the existing `ProfileStopConditions` JSON blob, normalize at its decoder, and reuse the existing validator, editor and migration paths. Defer invalid sync over an active profile through the existing durable failed-apply retry mechanism so its current stop routes survive. Derive invalid-profile status from the complete configuration, preserving invalid records and raw unreadable data. Extend the existing private-sync and app-group projections rather than adding another persistence system or strategy hierarchy.

**Tech Stack:** Swift, SwiftUI, SwiftData, FoqosShared, existing XCTest target and CloudKit DeviceSync JSON fields; no new dependency.

**Spec:** [V2 conditions rulebook](../specs/2026-10-02-508-v2-conditions-rulebook.md), merged in PR #522. Plan baseline: `origin/main` `c4dc064`. The latest human comments on [#507](https://github.com/mnbf9rca/family-foqos/issues/507) and [#521](https://github.com/mnbf9rca/family-foqos/issues/521) govern conflicts. The rulebook's pre-merge status paragraphs are historical; the dispatch supplies the merged authority.

## Global Constraints

- **R1:** V2 start and stop conditions are independent and combine freely. No pairing logic and no reuse of V1 strategy behaviour.
- **R2:** Every profile needs a stop condition, enforced in the editor and checked at every start (including synced, scheduled and link starts).
- **R4:** "Same tag" means the tag that started this session. It does not apply to sessions started any other way. If a profile can start any other way, it must also have a stop that does not rely on the same tag (editor save rule).
- **R9:** NFC and QR stop kinds (None, Any, Same, Specific) are a single choice per tag type and must be stored as a single value, not separate flags; normalise incoming synced data.
- Duration is an integer in `DeviceActivityLimits.minimumIntervalMinutes...maximumTimerMinutes` (currently 15...1439 minutes). No clamp, silent default or decoding through `StrategyTimerData.toStrategyTimerData` in V1 conversion.
- **V2 has not shipped to the App Store.** Protect genuinely unmigrated V1 records, active sessions and legacy physical keys. No TestFlight-only repair, old V2 reader shim, telemetry or #59 removal cutoff.
- All new user-facing copy is verbatim C1–C25 from the rulebook. Retain existing lock, selection, Screen Time and mode rules; Child adjustment at start is deferred, not newly restricted.
- Keep `BlockedProfiles.currentSchemaVersion == 3`: the existing V1→V2→V3 migration remains; this unreleased V2 blob change needs no new SwiftData or CloudKit record field. Keep newer-schema profiles read-only.
- New signed commits only; never amend or force-push. `build1` uses `--agent build1 --session collab` for every simulator command. No mass formatting outside reserved files.

## Slice boundary

This slice ends at a persisted, validated configuration and its projections. It enforces editor Save and Duplicate, derives stored-profile invalid status, and transfers V1 settings. It does **not** claim that a stored Timer counts down yet or that every runtime entrance refuses invalid profiles.

Later #493/#509–#513 work consumes the stored settings and validation result, validates actual-origin applicability at all start boundaries, removes `hasUsableStop`, offers the session-only manual adjustment, registers/publishes/cancels timers and guards expiry by exact session. Later #512/#521 owns typed tag identity, origin sync, delivery classification, written-tag admission, Link stop runtime removal and A→B switching. Later #514–#519 owns background-veto removal, schedule registration/callback/catch-up changes and card/widget summaries. Release-note integration is later release work.

Hide the old Link stop control now. Its Boolean/runtime remains a **temporary uncompleted #521 item**, not a valid stop for new Save/Duplicate or an R4 escape. Keep the legacy `ProfileStopConditions.isValid` behavior for existing runtime consumers until the admission/#521 slice; the new complete validator alone excludes Link. Do not turn it into Any NFC/QR, change Link starts or rewrite the resolver in this slice. Existing conservative editor checks for equal clocks and paired windows shorter than 15 minutes remain until #515–#517 changes registration and save rules together. This slice adds schedule completeness, not recurrence-rule relaxation. The unused snapshot invalid marker is likewise deferred to admission with its consumer. Genuine active V1 handling remains at its existing version boundary. Do not publish V2 as epic-complete from this foundations PR.

## Exact file reservations

These are proposed exclusive `build1` edits, subject to orchestrator confirmation; everything else is read-only. The planner's only artifact is this document.

| Production path | Responsibility |
| --- | --- |
| `Packages/FoqosShared/Sources/FoqosShared/ProfileStopConditions.swift` | Canonical tag kinds, saved timer duration/option, decoding and compatibility projections |
| `Foqos/Models/TriggerValidator.swift` | One pure, data-aware Save/stored-configuration validator |
| `Foqos/Models/TriggerConfigurationModel.swift` | Independence, load/edit/save validation and full settings transfer |
| `Foqos/Models/TriggerPickerOptions.swift` | Canonical stop-kind bindings; always offer Same |
| `Foqos/Models/BlockedProfiles.swift` | Raw JSON access, derived invalid status, snapshot projection, clone guard, migration transfer and editor-save boundary |
| `Foqos/Views/BlockedProfileView.swift` | Timer editor sheet, complete configuration before persistence, errors before publication |
| `Foqos/Components/BlockedProfileView/StopConditionSelector.swift` | All four choices, Same explanations, saved Timer settings controls |
| `Foqos/Components/Strategy/TimerDurationView.swift` | Reuse picker with saved initial minutes; exact integer range and explicit confirmation |
| `Foqos/Utils/TriggerMigration.swift` | Exact eight-strategy/nil/unknown mapping and strict V1 duration conversion |
| `Foqos/Utils/ProfileMigrationUtil.swift` | Existing deferral/save-before-enqueue flow, only if needed for revised conversion |
| `Foqos/CloudKit/SyncModels.swift` | Normalize valid blob projections; preserve unreadable raw blobs on export |
| `Foqos/CloudKit/SyncEngine/SyncApplyService.swift` | Apply normalized/raw incoming settings; defer invalid updates over active sessions |
| `Foqos/CloudKit/SyncEngine/SyncPayloadEquality.swift` | Canonical semantic comparison, with raw-byte comparison for unreadable/absent condition blobs |

Reserve these **existing** tests under `FoqosTests/`: `ProfileStopConditionsTests.swift`, `ProfileSnapshotStopConditionsTests.swift`, `TriggerValidatorTests.swift`, `TriggerConfigurationModelTests.swift`, `TriggerPickerOptionsTests.swift`, `TriggerMigrationTests.swift`, `BlockedProfilesMigrationTests.swift`, `BlockedProfilesTriggersTests.swift`, `CloneProfileTests.swift`, `ProfileSaveSnapshotTests.swift`, `BlockedProfileSaveValidationTests.swift`, `MigrationSnapshotTests.swift`, `SyncApplyServiceTests.swift`, `SyncPayloadEqualityTests.swift`, `ShortcutsStatusTests.swift`, `TimerDurationSnapTests.swift`. No new test file or project source entry is planned.

`FamilyFoqos.xcodeproj/project.pbxproj` is **excluded until orchestrator transfers it**. Dispatch reported build2 held it for #502; during planning #502 completed its compile evidence without edits and returned the reservation to orchestrator, while build2 began #503 evidence work. Before build1's non-docs PR is merge-ready, orchestrator must transfer its exclusive reservation for the mandatory marketing/build increments. Base the bump on then-current main, not numbers copied from c4dc064. Any #322 Swift fix in the paths above requires orchestrator arbitration before either stream edits it.

## Review Focus

- Canonical kind present but unknown/null/wrong-type alongside permissive old flags: unreadable configuration, no fallback (Task 1).
- A newer synced record carries bad/missing JSON over an existing valid local profile: retain incoming invalid data while idle; defer it durably while active so the original stops remain usable (Task 2).
- Two Same kinds with NFC+QR starts, or Link with Same: require a well-formed non-Same stop, including when the additional selected stop has missing keys (Task 2).
- V1 invalid/missing duration with Any versus Timer-only, and unknown/nil strategy IDs: retain approved mappings without inventing stops or durations (Task 3).
- Save failure or invalid clone: no published candidate snapshot, schedule registration or sync enqueue; source and authoritative active state remain intact (Task 4).

## Task 1: Canonical stop blob and saved timer settings

**Files:** `ProfileStopConditions.swift`; tests `ProfileStopConditionsTests.swift`, `TriggerPickerOptionsTests.swift`.

**Interfaces:** Add public `TagStopKind: String, Codable, CaseIterable, Equatable` with `.none`, `.any`, `.same`, `.specific`; `ProfileStopConditions.nfc: TagStopKind`, `.qr: TagStopKind`, `.timerDurationMinutes: Int?`, `.allowChangingTimerBeforeStart: Bool` (default false). Keep `.manual`, `.timer`, `.schedule`. Add `requiresEditingAfterConversion: Bool = false` in this same blob solely for the nil-ID conversion exception: unlike malformed configurations, that retained mapping can otherwise become valid through a schedule/physical modifier without the required user edit. Missing field defaults false; no separate CloudKit/SwiftData field or schema bump. The `deepLink` legacy member and legacy `isValid` semantics remain until admission/#521, for existing runtime gates. The new data-aware validator excludes Link from real stops.

Existing `anyNFC/specificNFC/sameNFC/anyQR/specificQR/sameQR` callers may remain as **computed** projections backed exclusively by `nfc`/`qr`: true selects that kind; false clears only that selected kind. Retain the existing initializer labels for source compatibility, normalizing simultaneous initializer flags by the approved precedence. This saves unrelated runtime/test churn; no additional flags are stored or emitted. Add canonical initializer arguments without making the empty initializer ambiguous. App mutation paths changed in this slice use `nfc`/`qr` directly.

- [ ] Add `testLegacyTripletsNormalizeIndependently` covering all eight Boolean triples per modality: Specific > Same > Any > None, then assert canonical encoded JSON contains `nfc`/`qr` and **no six legacy flag keys**. Add `testCanonicalKindWinsAndMalformedKindThrows`: known canonical beats flags, absent canonical falls back to triplet, present null/unknown/non-string throws even beside `anyNFC: true`. When canonical is absent, malformed legacy Boolean also throws, not Any. No selected stop/data changes based on starts.
- [ ] Add `testTimerSettingsRoundTripWithoutDefault`: exact `37` and `1439` minutes, option true/false, missing duration stays nil, missing option is false; non-integer/wrong-type duration fails decoding, numeric out-of-range remains available for validation rather than being clamped. Update tests that construct contradictory stored flags to use raw decoder fixtures; exercise computed setters as single-choice projections.
- [ ] Run `scripts/xcode-stream.sh --agent build1 --session collab -- xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -only-testing:FoqosTests/ProfileStopConditionsTests -only-testing:FoqosTests/TriggerPickerOptionsTests`. Expected red on missing canonical fields/normalization. A compile-baseline failure is not the expected red: report it to orchestrator; #502 owns baseline fixes.
- [ ] Implement custom Codable: canonical fields only for the six tag flags' replacement; legacy flag decoding only at this boundary. Keep existing selected-family meaning of `isValid` unchanged and separate from the new complete data-aware validator; exclude Link only in the latter. Duration/option ride in this blob through existing sync/snapshot Codable. Do not require duration in Codable: an inert converted V1 Timer must be representable.
- [ ] Rerun the command and confirm green, then `git add` the listed files and `git commit -S -m "feat: store canonical tag stops and timer settings"`.

## Task 2: Complete validation and lossless projections

**Files:** `TriggerValidator.swift`, `BlockedProfiles.swift`, `SyncModels.swift`, `SyncApplyService.swift`, `SyncPayloadEquality.swift`; tests `TriggerValidatorTests.swift`, `SyncApplyServiceTests.swift`, `SyncPayloadEqualityTests.swift`, `ProfileSnapshotStopConditionsTests.swift`.

**Interfaces:** Replace auto-fixing rule machinery with `TriggerValidator.validate(start: ProfileStartTriggers, stop: ProfileStopConditions, startNFCTagIds: [String], startQRCodeIds: [String], stopNFCTagIds: [String], stopQRCodeIds: [String], startSchedule: ProfileScheduleTime?, stopSchedule: ProfileScheduleTime?, settingsReadable: Bool = true, forSave: Bool = true) -> [String]`. Default the four key arrays to `[]` and both schedules to nil where existing simple callers need them. `forSave: false` derives stored admission validity and treats selected Timer with nil duration as inert; `forSave: true` requires its valid duration even alongside another stop. Non-nil bad durations remain invalid in both modes. Stored validation reports C12 when `requiresEditingAfterConversion` is true; a deliberate editor Save validates the draft ignoring that conversion-only marker, then clears it before persistence. Duplicate checks stored validity as well as save validity and cannot clear the marker.

Add `BlockedProfiles.conditionSettingsReadable: Bool` and `conditionValidationErrors(forSave: Bool) -> [String]`; `hasInvalidConditionSettings: Bool` is the stored-validation result's nonemptiness. Add `SyncedProfile.conditionValidationErrors(forSave: Bool) -> [String]` as an adapter to the **same** validator, using the legacy scalar keys for schema 2 and arrays for schema 3. Missing V1 blobs are expected; missing/undecodable supported V2 blobs are invalid. These results do not enforce originating starts in this slice, replace later actual-origin checks or touch restored active restrictions. No new snapshot marker or `SharedData.swift` edit: canonical stop structs already carry duration/option.

In `applyDecodedProfile`, after schema/LWW selection but **before an accepted incoming update mutates the model**, fetch the durable active session (using the existing fetch seam). If it owns this profile and the incoming supported V2 configuration has stored-validation errors, throw a scoped error through the existing `applyProfileModification` catch/`FailedApply(.upsert)` path. Keep the whole local record, sync version, system fields, profile snapshot and session unchanged; do not acknowledge success or upload the old data as a repair. Existing controller retry re-fetches on launch/next fetch cycle: while active it defers again, after completion it applies the retained invalid remote configuration. A newer valid payload may supersede the invalid one normally. This is a bounded deferral for **invalid** imports, not a new pending-payload store, rejection of valid profile sync or a change to stop matching. An active-session fetch failure fails apply rather than assuming idle.

In `SyncPayloadEquality`, add private `decodedConditionDataEqual<T: Decodable & Equatable>(_ lhs: Data?, _ rhs: Data?, as type: T.Type) -> Bool`: compare semantic decoded values when both decode, otherwise compare raw optional Data. Use it for start/stop condition and schedule blobs, preserving existing tie-break/version rules and other payload comparisons. This distinguishes two bad blobs and bad-versus-absent without treating canonical-versus-legacy equivalent stops as different.

- [ ] Add `testSaveRequiresRealWellFormedStop`: no starts→C5, no real stops/Link-only→C6, unreadable stored settings/Duplicate→C12, missing or blank Specific keys→C8 for start and stop. Any, Manual, operational Timer or valid Schedule can provide non-Same coverage; emergency unblock and a selected but invalid stop cannot. Keys must be nonempty usable strings in the existing UID/QR namespace; do not change identity format or hash migrated NFC IDs.
- [ ] Add `testSameCoverageMatrix`: sole NFC→Same NFC passes, sole QR→Same QR passes; Manual/Shortcuts/Schedule/opposite tag plus Same-only fails C7; NFC+QR with two Same fails; Link+Same fails the C7 Link variant; Same with no matching tag start plus valid Manual passes. A valid additional Specific stop passes even with keys different from start keys. Use the exact C7 NFC/QR/Link wording below; Link takes precedence for a Link coverage failure, then NFC, then QR.
  The minimal Same regression pins the message as well as the refusal:

  ```swift
  func testManualAndNFCWithSameOnlyNeedsAnotherStop() {
    let errors = TriggerValidator().validate(
      start: ProfileStartTriggers(manual: true, anyNFC: true),
      stop: ProfileStopConditions(sameNFC: true)
    )
    XCTAssertEqual(errors, ["Same NFC tag only works after an NFC start. Add another stop for other starts."])
  }
  ```

- [ ] Add `testOwnedScheduleAndTimerValidation`: empty days, unknown decoded weekday, nil selected schedule, hour outside 0...23 or minute outside 0...59 fails C9/unreadable C12 as appropriate. Keep the old editor same-clock/minimum-window checks outside this new completeness validator until the schedule slice; retain their existing helper/test oracle in this PR, using C10 for the existing equal-clock refusal without changing when it fires. Timer 15,37,1439 passes; nil,0,-1,14,1440 fails C11 on Save; nil with Any passes stored validation but nil Timer-only is invalid; invalid non-nil Timer never counts as coverage. Pin one `now` per test.
- [ ] Add `testIncomingBadSettingsReplaceValidSettingsAsInvalid` for both SyncApply insert/update: unknown kind, bad JSON and absent V2 blob are retained, not skipped by `if let synced.stopConditions`; selected Specific-without-keys stays Specific and invalid. Export→apply→export retains unreadable raw bytes; valid triplet data is canonicalized independently per type on application. No fallback to previous settings or invented stops. Add `testInvalidActiveProfileUpdateDefersAndReplays`: with an active profile, apply missing/bad/unknown/Specific-without-keys/new empty-stop data, assert `.failed`, existing Manual/tag/Schedule settings, keys and snapshot unchanged, unchanged session/restrictions/version/system fields, and a durable failed-upsert entry. Reapply while active stays deferred; end the session and reapply the record as the existing retry does, then assert retained bad raw settings, invalid status and cleared failed entry. Recreate the store between attempts to prove the retry entry survives relaunch. Fetch failure also defers. Use existing resolver and `BackgroundStopPolicy.evaluate` assertions to prove the retained Manual/tag/Schedule routes still allow the original stop, not merely that the session exists. A valid newer update and unrelated idle invalid profile apply normally.
- [ ] Add `testSnapshotCarriesCanonicalSettings`: profile→snapshot Codable round-trip preserves tag kinds, 37 minutes and option; an idle malformed model blob yields derived invalid status and a safe empty decoded stop projection, with no malformed raw bytes written into the snapshot. Add a raw old snapshot-dictionary fixture containing all ten old stop flags and another valid profile: both entries must decode and normalize. Never let one malformed canonical struct enter `SharedData.profileSnapshots`, whose dictionary-wide decoder would otherwise drop every profile. Existing V1 snapshots without stop conditions continue decoding.
- [ ] Add `testConditionBlobEqualityPreservesMalformedDifferences`: canonical versus equivalent triplets compares equal; different invalid blobs and invalid-versus-nil compare unequal for all four fields; keep deterministic equal-version remote/local winner tests.
- [ ] Run `scripts/xcode-stream.sh --agent build1 --session collab -- xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -only-testing:FoqosTests/TriggerValidatorTests -only-testing:FoqosTests/SyncApplyServiceTests -only-testing:FoqosTests/SyncPayloadEqualityTests -only-testing:FoqosTests/ProfileSnapshotStopConditionsTests`. Confirm each new assertion's expected red, then implement the interfaces. Provide narrowly scoped internal raw-data access for the four condition/schedule blobs so SyncApply and SyncedProfile preserve malformed/missing data; successful decode re-encodes canonical stops. Preserve V1 missing blobs and existing sync generation/LWW/newer-schema rules. Remove the pre-commit snapshot calls from SyncApply insert/update: publish normalized settings only after the accepted record commit and any required migration succeed; a failed apply leaves the previous snapshot unchanged. Do not log raw key data or decoder messages containing personal identifiers.
- [ ] Rerun the same focused tests green and make a new signed commit, `feat: validate complete V2 profile settings`.

## Task 3: Exact V1 conversion without V1 runtime authority

**Files:** `TriggerMigration.swift`, `BlockedProfiles.swift`, `ProfileMigrationUtil.swift` if required; tests `TriggerMigrationTests.swift`, `BlockedProfilesMigrationTests.swift`, `MigrationSnapshotTests.swift`, `SyncApplyServiceTests.swift`.

**Interfaces:** Keep `TriggerMigration.migrateFromStrategy(_ strategyId: String?) -> (ProfileStartTriggers, ProfileStopConditions)` and physical/schedule conversion signatures. Add `TriggerMigration.validTimerDuration(from data: Data?) -> Int?`, using throwing `JSONDecoder().decode(StrategyTimerData.self, from:)` and `DeviceActivityLimits` range. Transfer valid duration into the returned stop settings in `BlockedProfiles.migrateToV2IfNeeded()` only for a Timer strategy; option defaults false. Final invalid status uses Task 2 after all modifiers and array/key migration.

| Strategy ID | Starts (all other flags off) | Stops before modifiers |
| --- | --- | --- |
| `ManualBlockingStrategy` | Manual, Shortcuts, Link | Manual |
| `NFCBlockingStrategy` | Any NFC | Same NFC |
| `NFCManualBlockingStrategy` | Manual, Shortcuts, Link | Any NFC |
| `NFCTimerBlockingStrategy` | Manual, Shortcuts, Link | Any NFC, Timer |
| `QRCodeBlockingStrategy` | Any QR | Same QR |
| `QRManualBlockingStrategy` | Manual, Shortcuts, Link | Any QR |
| `QRTimerBlockingStrategy` | Manual, Shortcuts, Link | Any QR, Timer |
| `ShortcutTimerBlockingStrategy` | Manual, Shortcuts, Link | Timer |
| unknown non-nil | Any NFC | Same NFC |
| nil | Shortcuts, Link; no button or tag start | None; retained invalid until edited, including after modifiers |

For nil ID set Task 1's `requiresEditingAfterConversion` marker, including after modifiers. Retain Link/Shortcuts as data, no invented button start, and no dependence on the legacy ID after conversion. Only a deliberate valid editor save clears this exception marker. Other converted invalid configurations derive their errors from actual missing/malformed settings, not a second persistent validity flag.

- [ ] Add `testConversionMatrixPreservesEntrances` with exact start/stop assertions for all eight IDs, unknown non-nil and nil. Assert only plain NFC/QR (and unknown fallback) disable Link/Shortcuts, and the six other strategies enable them; no NFC/QR scan strategy acquires an immediate Manual start. Give Timer-family profile fixtures valid encoded 37-minute strategy data; assert every valid fully converted output's complete stored validator is empty and invalid records remain fetchable.
- [ ] Add `testV1TimerTransfersOnlyStrictValidDurations`: nil/bad JSON/missing integer/0/-1/14/1440 yields selected Timer+nil duration; 15,37,1439 survives migration and JSON/snapshot reconstruction with option false. NFC/QR Timer remains valid through Any; ShortcutTimer-only is invalid; valid physical/schedule modifier supplies another operational stop. Next edit still requires C17/C11; no silent 15-minute default.
- [ ] Add `testPhysicalAndScheduleModifiers`: same-modality physical key replaces Any/Same with Specific, opposite-modality key adds Specific; both legacy physical fields retain existing NFC-first precedence. Preserve uppercase NFC UID, existing QR hashing and SavedTag V3 arrays. Active valid schedule adds independent start/stop recurrences; disabled schedule enables neither. Invalid keys/recurrences remain invalid, not changed to Any/default times. Include nil/unknown IDs and final validator checks after modifiers. The nil marker remains true even with otherwise valid physical/schedule stops.
- [ ] Extend migration failure/active-session tests: V1 active profile stays schema 1 with untouched settings/restrictions; migration after end persists schema 3 before snapshot/upload. Save failure restores version, blobs and tags through existing rollback. Duplicate of an active V1 source may convert its candidate without migrating or altering the source; Task 4 validates that candidate before publication.
- [ ] Run `scripts/xcode-stream.sh --agent build1 --session collab -- xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -only-testing:FoqosTests/TriggerMigrationTests -only-testing:FoqosTests/BlockedProfilesMigrationTests -only-testing:FoqosTests/MigrationSnapshotTests -only-testing:FoqosTests/SyncApplyServiceTests` and confirm meaningful red. Implement mappings and strict transfer, keeping `migrateIfEligible`'s persistence-before-enqueue and active V1 boundary. No eager V2/TestFlight remapping, legacy column deletion or decoder changes to genuinely active V1 strategies.
- [ ] Rerun green and make a new signed commit, `fix: convert V1 profiles to independent V2 settings`.

## Task 4: Independent selectors and enforceable Save/Duplicate

**Files:** `TriggerConfigurationModel.swift`, `TriggerPickerOptions.swift`, `BlockedProfiles.swift`, `BlockedProfileView.swift`, `StopConditionSelector.swift`, `TimerDurationView.swift`; tests `TriggerConfigurationModelTests.swift`, `TriggerPickerOptionsTests.swift`, `BlockedProfilesTriggersTests.swift`, `CloneProfileTests.swift`, `ProfileSaveSnapshotTests.swift`, `BlockedProfileSaveValidationTests.swift`, `TimerDurationSnapTests.swift`, `ShortcutsStatusTests.swift`.

**Interfaces:** Keep `startTriggersDidChange()` and `stopConditionsDidChange()`; starts revalidate and may clear only their own abandoned Specific start assignments. Keep the existing stop-assignment cleanup only when the user explicitly changes that stop kind. `NFCStopOption/QRStopOption.from` and `apply(to:)` map directly to canonical kinds; `availableOptions(forStart:)` always returns all four choices. Remove autoFix/availability restrictions, preserving compatibility query wrappers as always available if needed.

`TriggerConfigurationModel.validate()` delegates to Task 2 with all draft-owned data. Add `TimerDurationView` initializer input `initialDurationMinutes: Int? = nil`, retaining its existing V1 callback API and V1 default for genuinely new picker presentation. The editor passes the saved value explicitly; unconfigured Timer stays nil until the user confirms. Preserve the existing schedule picker/paired-window guards until the schedule slice; there is no new collision helper here. Editor `validate()` uses draft fields with `settingsReadable: true`; unreadable stored blobs load as empty starts/stops/nil recurrences and become repairable through normal C5/C6/C9 selection. Do not carry stored `settingsReadable == false` into a draft Save: a valid confirmed draft replaces those raw bytes.

At the actual editor save boundary, allow `BlockedProfiles.createProfile`/`updateProfile` to receive the complete validated `TriggerConfigurationModel` as an optional trailing argument `triggerConfiguration: TriggerConfigurationModel? = nil`. A supplied editor configuration is validated before any profile-field mutations. On update, run any eligible legacy migration **before those mutations and before applying the draft**: the current migration can save the entire context, so it must not persist/overwrite an unvalidated draft. Then apply all draft/profile fields, save once for this edit and publish its snapshot only after success. `saveToProfile` becomes assignment-only and clears the conversion-only marker after successful draft validation. Name `BlockedProfileView.finalizeSave` explicitly: remove its second save/log-only failure path; it registers schedules/enqueues sync only after the create/update single edit save returns successfully. Persistence errors propagate to the existing error surface and stop downstream work. Nil leaves existing headless callers for the later admission slice; no claim of universal creator enforcement. Clone builds the candidate without inserting it; immediately restore `candidate.blockingStrategyId = source.blockingStrategyId` (including nil) before conversion, avoiding the initializer's nonoptional NFC fallback. Restore a nil incoming SyncedProfile ID the same way before V1 conversion. For V1 candidates call the existing **no-save** `migrateToV2IfNeeded()` and validate the resulting schema-2 configuration with effective scalar keys, before insertion or any call to `ProfileMigrationUtil.migrate`. For schema-2/3 sources copy raw unreadable data rather than empty projections. Check stored validity plus `forSave: true`; unreadable/marked-invalid candidates fail C12, missing Timer duration fails C11. Only an accepted candidate is inserted and runs the existing V3 tag-array conversion/save/enqueue. Move any inactive-source migration until after candidate acceptance; an active V1 source stays deferred. No `migrateIfEligible`/sync-owning helper may run on an unvalidated candidate. Failed saves roll back the inserted candidate and new tags and publish no snapshot. Migration may retain invalid records; Duplicate may not create a new invalid record.

- [ ] Replace the tests that require auto-clearing/hiding Same. Add `testStartChangesPreserveEveryStopOwnedSetting`: set Same NFC, Specific QR+keys, Timer 37+option true and stop recurrence; cycle NFC/QR/Manual/Link/Schedule starts, assert stops/data byte-equivalent. Add `testAllStopOptionsAlwaysAvailable` for empty/manual/opposite starts; Same explanation uses C21. Preserve unrelated tag assignment cleanup tests.
- [ ] Add `testTimerSaveReopenCloneSyncSnapshot`: select duration 37/option true, persist, reconstruct in a fresh ModelContext, load draft, duplicate, build SyncedProfile and snapshot, assert exact values everywhere. Toggle Timer off/on without changing starts or inventing a new duration; cancellation of duration selection leaves the draft unchanged. Keep the existing five-minute slider and snap behavior on slider interaction, never on load/Save. Use the existing plus/minus buttons with one-minute increments for exact selection, including 37 and the reachable 1439 endpoint; no new picker system. Reuse existing labels, replace the false 24h maximum label with the existing exact limit description.
- [ ] Add `testEditorSaveAndCloneRejectBeforeEffects` against the supplied create/update configuration and clone: C6/C7/C8/C11/C12 fail before profile insertion/mutation, candidate snapshot publication and schedule/sync actions. Include invalid converted Timer-only and nil ID. Read-only store failure reports an error, publishes no candidate snapshot, and makes no downstream schedule/sync call; use the existing failure fixture pattern. Valid create/update saves complete settings once before snapshot; failed persistence restores the prior live configuration. Keep unrelated successful changes and source snapshots intact.
- [ ] Update `ProfileSaveSnapshotTests` to the new persist-before-publish boundary and valid draft fixtures. Add `testUnreadableStoredSettingsCanBeRepairedByDraftSave`: load bad start/stop blobs as empty selections, select valid Manual start/stop, save, reload and assert readable canonical bytes and cleared invalid status. Preserve unrelated assertions in clone/save fixtures by giving their sources valid settings. Add raw decoder fixtures to the contradictory-flag cases in `ShortcutsStatusTests.swift` only; retain its deferred runtime predicate expectations and make no `hasUsableStop` change. Do not change schedule runtime/picker behavior.
- [ ] Run `scripts/xcode-stream.sh --agent build1 --session collab -- xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -only-testing:FoqosTests/TriggerConfigurationModelTests -only-testing:FoqosTests/TriggerPickerOptionsTests -only-testing:FoqosTests/BlockedProfilesTriggersTests -only-testing:FoqosTests/CloneProfileTests -only-testing:FoqosTests/ProfileSaveSnapshotTests -only-testing:FoqosTests/BlockedProfileSaveValidationTests -only-testing:FoqosTests/TimerDurationSnapTests -only-testing:FoqosTests/ShortcutsStatusTests`; confirm new red assertions. Implement canonical bindings, remove start-driven `.onChange` resets in `StopConditionSelector`, hide the old Link stop toggle, add saved-duration Configure sheet and C1/C2 option help, show C17 for missing Timer duration. Preserve edit-lock disabling on duration/option controls. No manual-start adjustment flow, C3 session note or old-mirror repair note belongs here.
- [ ] Rerun green; manually check new/existing editor: Same remains offered after a start edit, Save explains failure without erasing selections, Timer settings reopen exactly, Cancel does not set a duration, existing schedule guards remain. Confirm existing Parent/Child edit locks and basic labels/accessibility. Make a new signed commit, `feat: save independent profile conditions and timer settings`.

## Exact copy used by this slice

Use these strings unchanged in validator/editor errors and explanations; do not add friendly paraphrases. Keep multiple errors on the existing error surface.

| ID | Exact text |
| --- | --- |
| C1 | Allow changing timer before start |
| C2 | You can choose a different duration for an interactive start. Tag, link, Shortcut and scheduled starts use the saved duration. |
| C5 | Choose at least one way to start this profile. |
| C6 | Add at least one stop before saving this profile. |
| C7 NFC | Same NFC tag only works after an NFC start. Add another stop for other starts. |
| C7 QR | Same QR code only works after a QR start. Add another stop for other starts. |
| C7 Link | Links can come from NFC tags or QR codes. Add a stop that doesn’t rely on the same tag. |
| C8 NFC | Choose at least one NFC tag. |
| C8 QR | Choose at least one QR code. |
| C9 | Choose the days and time for this schedule. |
| C10 | Choose different moments for scheduled start and stop. |
| C11 | Choose a timer from 15 minutes to 23 hours 59 minutes. |
| C12 | These settings couldn’t be saved. Please check this profile and try again. |
| C17 | Set a timer duration. Timer won’t stop this profile until you do. |
| C21 NFC | Stop with the same NFC tag that started this session. Other starts need another stop. |
| C21 QR | Stop with the same QR code that started this session. Other starts need another stop. |

C18 is the **later** every-start presentation of stored invalid status: `Please edit this profile before starting. Its start and stop settings need updating.` Do not turn it into a save-error replacement or implement partial admission in the foundations PR. C21's older-link note requires recorded session origin and belongs to the identity slice.

## Task 5: Verify and hand off the foundations PR

**Files:** no extra source files. `project.pbxproj` only after explicit orchestrator reservation transfer.

- [ ] Run the full test target once through `scripts/xcode-stream.sh --agent build1 --session collab -- xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos`. This catches existing resolver/Shortcuts/schedule tests affected by computed projections without rewriting their future-slice behavior. Report baseline failures with exact evidence; request arbitration before editing any unreserved file.
- [ ] Format/lint only reserved changed Swift paths with `swift-format`, run `git diff --check`, and build via `scripts/xcode-stream.sh --agent build1 --session collab --xcbeautify -- xcodebuild -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -configuration Debug build`. Expected: zero new lint/whitespace errors, `TEST SUCCEEDED` and `BUILD SUCCEEDED`. Record simulator evidence and any unrun physical-device work accurately; this slice does not prove delivery/countdowns/two-device Same.
- [ ] Announce the project-file dependency to orchestrator when waiting begins. After orchestrator transfers the project-file reservation, merge current origin/main with a new merge commit if needed (no amend/force), increment both app/build versions under the gate, and make a signed commit. Run `scripts/check-version-increment.sh origin/main HEAD`, then affected build/checks; resolve overlaps through orchestrator.
- [ ] Push normal commits, create a ready-for-review PR describing exactly the foundations boundary, with #520/#511 coverage and partial #493/#509/#507 coverage. Do not auto-close the remaining timer/admission epic children. Request independent code review of its exact head; label `greptile-review` once only after findings are resolved and it is considered ready. Orchestrator owns the specific human merge gate.
- [ ] Send orchestrator the ready PR URL, exact head/base, check results, reviewer decision and reservation release list. Remainder after foundations: actual-origin admission, timer establishment/expiry/adjustment, identity/mirrors, schedule runtime, R5, R10, presentation and release notes.

## Planner review record

Round 1: reviewer reported 3 blocking and 9 non-blocking findings. This revision resolves active malformed-sync deferral, pure candidate conversion before clone persistence, draft-only repair validation and the nine scope/integration points. Round 2 verdict pending before build1 dispatch. Review must assess correctness, over-engineering and practical missing cases against the merged rulebook; it does not reopen approved rulings/copy or authorize implementation/merge by itself.
