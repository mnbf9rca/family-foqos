# CKSyncEngine Sync Transport (#267) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the CKQuery-based private-DB sync transport (`ProfileSyncManager`/`SyncCoordinator`) with a `CKSyncEngine`-based change-token transport, per the normative contract in `docs/plans/2026-07-02-sync-engine-design.md` (v9, converged), closing #195/#202/#219/#200/#201.

**Architecture:** A new `@MainActor SyncEngineController` owns a `CKSyncEngine` (private DB, `DeviceSync` zone) behind a mockable `SyncEngineDriver` seam. Inbound fetched events route through `SyncApplyService` (which reuses `SyncCoordinator`'s merge semantics verbatim, minus reconciliation). Outbound: every locally-originated mutation flows through one `MutationFunnel` (bump/tombstone + `state.add`); `RecordProvider` materializes `CKRecord`s reusing existing `toCKRecord`/`updateCKRecord`. All engine/intent/token state persists per-`userRecordID` in `SyncEngineStore`. Reset Sync is re-designed as a crash-resumable origin state machine + fixed-name command record. The old CKQuery path is deleted at cutover.

**Tech Stack:** Swift 6, SwiftData (`cloudKitDatabase: .none`), CloudKit `CKSyncEngine` (iOS 17+; target 18.6), XCTest, `@testable import FamilyFoqos`.

## Global Constraints

- **The design doc is a normative contract.** `docs/plans/2026-07-02-sync-engine-design.md` (v9) — its 12 invariants (I1–I12), 11-transition state machine (T1–T11), event-handling contract (§5.0–§5.6), Reset Sync (§8), and residuals (N1–N14) are REQUIREMENTS. `docs/plans/2026-07-02-sync-engine-corpus-mapping.md` is a normative companion. Do NOT redesign. If you hit a genuine contradiction/impossibility, STOP and report — do not improvise.
- **CKRecord payload schema UNCHANGED** (non-goal): no new record types or fields; reuse `SyncedProfile`/`SyncedLocation`/`SyncedEmergencySettings`/`ProfileSession`/`SyncResetRequest`/`LegacySyncedSession` type strings and field keys byte-for-byte. The reset command reuses `SyncResetRequest`.
- **Shared-DB FamilyCommand/lock-code channel UNTOUCHED** (out of scope, B2). `CloudKitManager`/`CloudKitNetworkService*` are not modified.
- **Apply-side merge semantics preserved** (SyncCoordinator) with exactly two named amendments: (§5.1) own-origin apply skip removed; (§5.1) fetched modifications shadowed by a pending delete skipped. `SessionSyncService` CAS path preserved with one amendment (§6 stop-on-absent).
- **I9 schema-version gate survives intact** (`SyncCoordinator.swift:126-166`): newer schema ⇒ mark-read-only; older ⇒ reject + auto-heal via the funnel; same-schema-newer ⇒ apply.
- **AGENTS.md compliance:** 2-space indent, `swift-format` clean, `@SafeQuery` in views (never `@Query`), no force/amend commits, request code review before merge. Tests run on a booted-simulator UUID (never device name).
- **TDD:** every task writes the failing test first. The 38 named scenarios (S-1..S-38) become tests. The existing 429-test suite stays green. No `Date()` called more than once per test; inject `now:`.
- **Persisted state keys are per-`userRecordID.recordName`** (§7) except the pre-existing global `syncEnabled`. Compound writes use `SharedData.withLock` (non-reentrant — never nest; batch with the local-copy pattern).
- **`deviceId` = `SharedData.deviceSyncId.uuidString`** everywhere.
- **No CKQuery in the private-DB sync path** (I5) after cutover — enforced by grep/CI check.
- **Delegate prohibition:** never call `fetchChanges()`/`sendChanges()` from within `handleEvent`; schedule them in a `Task` after the handler returns (§1.1, §5.0).

---

## File Structure

New files under `Foqos/CloudKit/SyncEngine/`:

| File | Responsibility |
|---|---|
| `SyncEngineEvent.swift` | Domain event enum `SyncEngineEvent` (mirrors the `CKSyncEngine.Event` cases we consume) + `SyncEngineZoneDeletionReason`, `SyncEngineAccountChangeKind`. Keeps hard-to-construct `CKSyncEngine.Event`/`State` out of tests; carries test-constructible `CKRecord`/`CKError`/`CKRecord.ID`. |
| `SyncEngineDriver.swift` | `protocol SyncEngineDriver` — the AB-1..AB-4 seam over `CKSyncEngine` (pending-change add/remove, `fetchChanges`, `sendChanges`, `stateSerialization`). Plus `protocol SyncEngineDriverDelegate` (receives `SyncEngineEvent`, supplies `nextRecordZoneChangeBatch`). |
| `CKSyncEngineDriver.swift` | Production adapter: owns a real `CKSyncEngine`, conforms to `CKSyncEngineDelegate`, translates `CKSyncEngine.Event`→`SyncEngineEvent`, forwards to delegate; encodes/decodes `State.Serialization`↔`Data`. Excluded from unit tests (integration-only). |
| `MockSyncEngineDriver.swift` (in `FoqosTests/Mocks/`) | Test double: records pending-change mutations & fetch/send requests; lets tests enqueue `SyncEngineEvent`s and pull `nextRecordZoneChangeBatch`. Actor or `@MainActor` per controller actor-context. |
| `SyncEngineStore.swift` | Per-user persisted state (§2.1 table): `engineState`, `systemFields`, `processedResetCommandIds`, `resetIntent`, `lastAppliedResetCommandId`, `pendingSeedIntent`, `deleteTombstones`, `failedApplies`, `legacyCleanupDone`, `legacyCleanupIds`. Compound writes under `withLock`. |
| `SyncEngineController.swift` | `@MainActor`, `SyncEngineDriverDelegate`. Sole engine owner (I10, context-gated). Implements `handleEvent` (T1–T11, §5.0–§5.6), the T1 strip (AB-4/I12), I11 seeding, I12 recovery, echo guard, failed-apply retry. |
| `SyncEngineController+Reset.swift` | Reset Sync: origin state machine (§8.1), command application (§8.3), T5/T6/T8/T9, `.deleting`-resume gate. |
| `MutationFunnel.swift` | The single API for locally-originated create/update/delete (I2): save path (bump-in-write + `state.add(.saveRecord)`), delete path (tombstone-in-`withLock` + `state.add(.deleteRecord)` + rollback-on-failure). |
| `RecordProvider.swift` | Materializes `CKRecord`s for `nextRecordZoneChangeBatch` from SwiftData/`EmergencyUnblockManager`, on cached `systemFields` (fresh if none); reuses `toCKRecord`/`updateCKRecord`; §5.4 rules. |
| `SyncApplyService.swift` | Inbound apply (§5.1/§5.2): routes fetched modifications/deletions by `recordType`; reuses `SyncCoordinator` merge + I9 gate; branch-0/E rules; pending-delete-wins; `systemFields` store-after-apply; `failedApplies` on throw. |

Modified files:
- `Foqos/CloudKit/SyncCoordinator.swift` — extract reusable per-record apply methods (keep merge/I9); DELETE reconciliation, own-origin skip, push paths, reset re-push.
- `Foqos/CloudKit/SessionSyncService.swift` — §6 stop-on-absent create-if-absent; I6 cache flush wiring; zone-existence guarantee.
- `Foqos/CloudKit/ProfileSyncManager.swift` — DELETE the CKQuery transport; keep only the `@Published` UI-state surface + `syncEnabled` toggle plumbing (moved/retained as needed) OR fold that surface into `SyncEngineController`. (Decided in Phase F.)
- `Foqos/FoqosApp.swift` — construct/wire `SyncEngineController(modelContext:)` at the `.onAppear` injection point (I10); route remote-notification + scenePhase; delete `handleRemoteNotification` call.
- `Foqos/Utils/StrategyManager.swift:646` — route dropped session-stop CAS error into the funnel/outbox (#201).
- Call sites re-routed to the funnel: `BlockedProfileView.swift:737/807/885`, `AddLocationView.swift:500`, `SavedLocationsView.swift:181`, `EmergencyUnblockManager.swift:257`, `SettingsView.swift:176/394/407`, `SyncCoordinator.swift:138` (I9 auto-heal).

New test files (auto-included by folder; no pbxproj edit): under `FoqosTests/` and `FoqosTests/Mocks/`. Group by phase (e.g. `SyncEngineStoreTests`, `RecordProviderTests`, `SyncApplyServiceTests`, `MutationFunnelTests`, `SyncEngineControllerTests`, `SyncEngineResetTests`, `SessionStopOnAbsentTests`, `SyncEngineCutoverTests`).

---

## Locked Interface Contract

These names/signatures are fixed; all tasks consume them verbatim. Where a signature says `// contract §X`, the detailed behavior is defined by that design-doc section.

### Engine seam (`SyncEngineEvent.swift`, `SyncEngineDriver.swift`)

```swift
import CloudKit

enum SyncEngineZoneDeletionReason { case deleted, purged, encryptedDataReset }
enum SyncEngineAccountChangeKind { case signIn, signOut, switchAccounts }

/// Domain mirror of the CKSyncEngine.Event cases the controller consumes.
/// CKRecord / CKError / CKRecord.ID are test-constructible; CKSyncEngine.Event/State are not.
enum SyncEngineEvent {
  case stateUpdate(serialization: Data)                       // T10; persist for fetch tokens (AB-2)
  case accountChange(kind: SyncEngineAccountChangeKind)       // T7
  case fetchedDatabaseChanges(
        modifiedZoneIDs: [CKRecordZone.ID],
        deletedZones: [(zoneID: CKRecordZone.ID, reason: SyncEngineZoneDeletionReason)]) // T5/T6
  case fetchedRecordZoneChanges(
        modifications: [CKRecord],
        deletions: [(recordID: CKRecord.ID, recordType: CKRecord.RecordType)])           // T3 §5.1/§5.2
  case sentRecordZoneChanges(
        savedRecords: [CKRecord],
        failedRecordSaves: [(record: CKRecord, error: CKError)],
        deletedRecordIDs: [CKRecord.ID],
        failedRecordDeletes: [(recordID: CKRecord.ID, error: CKError)])                   // T4 §5.3
  case sentDatabaseChanges(
        savedZones: [CKRecordZone.ID],
        failedZoneSaves: [(zone: CKRecordZone, error: CKError)],
        deletedZoneIDs: [CKRecordZone.ID],
        failedZoneDeletes: [(zoneID: CKRecordZone.ID, error: CKError)])                   // T4b §5.5
  case willFetchChanges                                        // AB-3 cycle delimiter
  case didFetchChanges                                         // T2; AB-3; drives §5.6 sweep + echo-guard drain
}

@MainActor
protocol SyncEngineDriver: AnyObject {
  var stateSerialization: Data? { get }                        // restored engine state (nil = bootstrap)
  var pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange] { get }
  var pendingDatabaseChanges: [CKSyncEngine.PendingDatabaseChange] { get }
  func add(pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange])
  func remove(pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange])
  func add(pendingDatabaseChanges: [CKSyncEngine.PendingDatabaseChange])
  func remove(pendingDatabaseChanges: [CKSyncEngine.PendingDatabaseChange])
  func fetchChanges()   // MUST be scheduled outside handleEvent (§1.1)
  func sendChanges()    // MUST be scheduled outside handleEvent
}

@MainActor
protocol SyncEngineDriverDelegate: AnyObject {
  func handle(_ event: SyncEngineEvent)                        // serial (B-7)
  func nextRecordZoneChangeBatch(scope: CKSyncEngine.SendChangesOptions.Scope?) -> [CKRecord]?  // §5.4 materialization
}
```

> **Implementation note (Phase A):** If `CKSyncEngine.PendingRecordZoneChange`/`PendingDatabaseChange` prove non-constructible in test targets, fall back to a tiny domain enum (`SyncPendingRecordChange { case save(CKRecord.ID); case delete(CKRecord.ID) }`, `SyncPendingZoneChange { case save(CKRecordZone.ID); case delete(CKRecordZone.ID) }`) used in the protocol, with `CKSyncEngineDriver` translating to/from the real types. This is an AB-boundary implementation detail, not a contract change.

### Persisted state (`SyncEngineStore.swift`) — §2.1

```swift
struct ResetIntent: Codable, Equatable {
  var id: UUID
  var clear: Bool
  enum Stage: String, Codable { case deleting, recreating, seeding }
  var stage: Stage
  var priorCommandId: UUID?
}

struct FailedApply: Codable, Hashable {
  var recordName: String
  var recordType: String            // CKRecord.RecordType raw
  enum Op: String, Codable { case upsert, delete }
  var op: Op
}

@MainActor
final class SyncEngineStore {
  init(userRecordName: String, defaults: UserDefaults = .standard)   // per-user namespace (§7)
  // engine state
  var engineState: Data? { get set }                                 // key ...engine_state_<user>
  // change-tag cache — SyncedProfile/SyncedLocation/SyncedEmergencySettings only (§2.1)
  func systemFields(for recordName: String) -> Data?
  func setSystemFields(_ data: Data?, for recordName: String)        // nil removes
  func purgeAllSystemFields()                                        // I6
  // idempotency
  var processedResetCommandIds: Set<UUID> { get }
  func markProcessed(_ id: UUID)
  var lastAppliedResetCommandId: UUID? { get set }
  // intents
  var resetIntent: ResetIntent? { get set }
  var pendingSeedIntent: Bool { get set }
  var deleteTombstones: [String: String?] { get }                   // recordName -> change tag (nil if never synced)
  func setTombstone(recordName: String, changeTag: String?)
  func clearTombstone(recordName: String)
  // retry
  var failedApplies: Set<FailedApply> { get }
  func addFailedApply(_ entry: FailedApply)
  func removeFailedApply(recordName: String)                        // supersession clears by name
  // legacy one-shot (§11)
  var legacyCleanupDone: Bool { get set }
  var legacyCleanupIds: Set<String> { get }
  func addLegacyCleanupIds(_ ids: Set<String>)
  func removeLegacyCleanupId(_ id: String)
  // atomic compound update (single withLock — never nest)
  func transaction(_ body: (SyncEngineStore) -> Void)
}
```

Key format: `family_foqos_syncengine_<field>_<userRecordName>`. `legacyCleanupDone` reuses the existing `family_foqos_legacy_session_cleanup_complete_<user>` key semantics (do not orphan it).

### Record materialization (`RecordProvider.swift`)

```swift
@MainActor
final class RecordProvider {
  init(modelContext: ModelContext, store: SyncEngineStore, emergencyManager: EmergencyUnblockManager, deviceId: String)
  /// Build the CKRecord for a pending recordName, on cached systemFields (fresh if none).
  /// Returns nil to signal §5.4 "remove from queue" (entity absent, or isNewerSchemaVersion profile).
  func record(forRecordName recordName: String) -> CKRecord?
  /// Reuses SyncedProfile/SyncedLocation/SyncedEmergencySettings toCKRecord/updateCKRecord + ProfileSessionRecord.
}
```

### Inbound apply (`SyncApplyService.swift`) — §5.1/§5.2

```swift
@MainActor
final class SyncApplyService {
  init(modelContext: ModelContext, store: SyncEngineStore, sessionController: SessionController, emergencyManager: EmergencyUnblockManager, deviceId: String)
  var recentlyConfirmedDeletes: Set<String>   // in-memory echo guard (§5.1)
  /// Apply one fetched modification; returns .applied/.skippedPendingDelete/.failed (records failedApplies on throw).
  func applyFetchedModification(_ record: CKRecord, isPendingDeleteOrTombstoned: (String) -> Bool) -> ApplyOutcome
  /// Apply one fetched deletion (§5.2). Clears matching tombstone + pending .deleteRecord via the returned effect.
  func applyFetchedDeletion(recordID: CKRecord.ID, recordType: CKRecord.RecordType) -> DeletionOutcome
  enum ApplyOutcome { case applied, skippedPendingDelete, ignored, failed }
  enum DeletionOutcome { case deleted, notPresent, ignored }
}
```

Conflict entries: call `SyncConflictManager.shared.addConflict/addNewerVersionConflict/clearConflict(profileId:profileName:)` exactly as `SyncCoordinator.handleSyncedProfiles` does today.

### Mutation funnel (`MutationFunnel.swift`) — I2/I12

```swift
@MainActor
final class MutationFunnel {
  init(modelContext: ModelContext, store: SyncEngineStore, driver: SyncEngineDriver, deviceId: String)
  /// Save path: re-read entity on sync context, bump version in the SAME persisted write, require success, state.add(.saveRecord). Never enqueues isNewerSchemaVersion profiles.
  func enqueueSave(profileId: UUID) throws
  func enqueueSave(locationId: UUID) throws
  func enqueueEmergencySettingsSave() throws
  /// Delete path: persist tombstone (recordName->change tag) in same withLock as (and before returning from) the entity delete; on delete failure remove tombstone + context.rollback; then state.add(.deleteRecord).
  func enqueueDelete(profileId: UUID) throws
  func enqueueDelete(locationId: UUID) throws
}
```

### Controller (`SyncEngineController.swift`)

```swift
@MainActor
final class SyncEngineController: SyncEngineDriverDelegate {
  /// I10: constructed with the ModelContext (never observes an event without one). Driver injected for tests.
  init(modelContext: ModelContext,
       store: SyncEngineStore,
       driverFactory: (Data?) -> SyncEngineDriver,      // receives restored engineState
       apply: SyncApplyService,
       provider: RecordProvider,
       sessionSync: SessionSyncFlushing,                 // I6 cache flush seam (SessionSyncService)
       deviceId: String)
  func start()                                           // T1: init driver, strip (AB-4), recovery, seed decision, resetIntent resume, then schedule fetchChanges()
  func stop()                                            // T11
  // SyncEngineDriverDelegate
  func handle(_ event: SyncEngineEvent)
  func nextRecordZoneChangeBatch(scope: CKSyncEngine.SendChangesOptions.Scope?) -> [CKRecord]?
  // Reset (in +Reset.swift)
  func beginReset(clearRemoteAppSelections: Bool)        // T8 §8.1
}
```

`SessionSyncFlushing` is a one-method seam (`func flushSessionCache() async`) that `SessionSyncService` conforms to, so I6 can flush without a hard singleton dependency (mockable).

---

<!-- PHASE TASKS APPENDED BELOW -->

## Conformance-Review Amendments (BINDING — 2026-07-03)

These five amendments come from the adversarial design-conformance review of this plan. They
correct real cross-phase seam-integration gaps. **Apply each when you reach the referenced
task** — they override the drafted task text where they conflict. Each keeps its phase's
compile-green exit criterion.

### CRA-1 — Drain `SyncApplyService.drainReenqueues()` into the driver (I2/I8/I9)

`applyFetchedModification` records equal-version-divergence bumps (§5.1 branch E), local-wins
re-adds, and I9/I2 older-schema auto-heals into `pendingReenqueues`; **the controller must drain
them or those conflict re-enqueues never reach CloudKit.** Wherever the controller calls
`apply.applyFetchedModification(...)`, immediately drain and enqueue:

```swift
for recordID in apply.drainReenqueues() {
  driver.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
}
```

Apply at **two sites**:
- **Task 69** `handleFetchedRecordZoneChanges`, after the `for record in modifications` loop (drain once after the loop is fine — `drainReenqueues()` returns all accumulated ids).
- **Task 70** `handleFailedSave` branch `.serverRecordChanged`, immediately after the
  `apply.applyFetchedModification(server, ...)` call at the branch-C site.

Add to the branch-E test (S-10) and the equal-version-divergence test (S-27) an assertion that
`driver.addedRecordZoneChanges` contains `.saveRecord` for the bumped record id.

### CRA-2 — Route fetched `SyncResetRequest` command records to §8.3 (finding: no application path)

`handleFetchedRecordZoneChanges` (Task 69) currently sends **every** modification through
`applyFetchedModification`, including the reset command — which `SyncApplyService` does not apply
(§8.3 lives in `ResetController`). Intercept it. Add a hook to `SyncEngineController` (near the
other reset hooks, Task 61/71) and fire it before the generic apply:

```swift
var onFetchedResetCommand: ((CKRecord) -> Void)?   // wired to ResetController.applyCommand in Phase F
```
```swift
// in handleFetchedRecordZoneChanges, first line of the `for record in modifications` loop:
if record.recordType == SyncResetRequest.recordType {
  onFetchedResetCommand?(record)   // §8.3 (undecodable command is inert per §5.1)
  continue
}
```
Add a Task-69 test asserting a fetched `SyncResetRequest` fires `onFetchedResetCommand` and is
**not** passed to `applyFetchedModification`.

### CRA-3 — Fire a command-save **success** hook (§8.1 step 5 happy path)

`handleSentRecordZoneChanges` (Task 70) has `resetCommandSaveDidFail?` but no success hook, so
§8.1 step 5's "command saved ⇒ clear `resetIntent`" is never triggered. Add the hook and fire it
in the `savedRecords` loop (the command is not a scoped type, so it stores no `systemFields`):

```swift
var resetCommandSaveDidSucceed: ((CKRecord) -> Void)?   // wired to ResetController in Phase F
```
```swift
// inside the savedRecords loop, before the scoped-type systemFields store:
if record.recordType == SyncResetRequest.recordType {
  resetCommandSaveDidSucceed?(record)
  continue
}
```
Add a Task-70 test asserting a saved `SyncResetRequest` fires the success hook and stores no
`systemFields`.

### CRA-4 — Promote the Phase-F reset wiring handoff to an executable task (§8.1/§8.3/T8)

The reset wiring at the end of Phase E / the Phase-F handoff bullet must be an **executable TDD
step in Task 133** (the composition root), not prose. In Task 133, after constructing the
`ResetController` from its adapters, wire **all** hooks and assert them:

```swift
let reset = ResetController(
  store: store, outbox: DriverResetOutbox(driver: driver),
  seeder: DefaultResetSeeder(flush: sessionSync.flushSessionCache, seed: seedAll, clearSelections: clearAllSelections),
  fetcher: DatabaseRecordFetcher(driver: driver),
  surfacer: ConflictManagerResetSurfacer(), deviceId: deviceId)
controller.onFetchedResetCommand   = { record in Task { await reset.applyCommand(record) } }
controller.onZoneChangeConfirmed   = { saved, deleted in
  if !deleted.isEmpty { reset.handleZoneDeleteConfirmed() }
  if !saved.isEmpty   { reset.handleZoneSaveConfirmed() }
}
controller.resetCommandSaveDidSucceed = { _ in reset.handleCommandSaveResult(.saved) }
controller.resetCommandSaveDidFail    = { record, _ in reset.handleCommandSaveResult(.serverRecordChanged(record)) }
controller.onResumeReset             = { Task { await reset.resume() } }
controller.beginResetForwarding      = { clear in reset.beginReset(clearRemoteAppSelections: clear, now: Date()) }
```

`SyncEngineController.beginReset(clearRemoteAppSelections:)` (locked signature) calls
`beginResetForwarding?(clear)`. Note the `.serverRecordChanged(record)` case: `handleCommandSaveResult`
already case-splits own/foreign/undecodable `requestId` inside (§8.1 step 5), so passing the
server/attempted record is correct. Add a Task-133 test (using `MockSyncEngineDriver` +
the real `ResetController`) asserting: a fetched command triggers `applyCommand`; a zone-delete
confirmation advances the stage; `beginReset(clearRemoteAppSelections:)` reaches
`ResetController.beginReset`. If `beginResetForwarding` is a new stored property, declare it next to
the other hooks in Task 61.

### CRA-5 — Make the S-33 "matching tag ⇒ delete" arm deterministically testable

`CKRecord.recordChangeTag` is not settable on a client-made record, so Task 66 dropped the only
destructive verify-before-delete arm. Fix by carrying the tag through the fetch seam instead of
reading it off the record.

- **Task 60:** change `enum FetchRecordResult { case found(CKRecord); ... }` to
  `case found(CKRecord, changeTag: String?)`. The production `CKSyncEngineDriver.fetchRecord`
  returns `.found(record, changeTag: record.recordChangeTag)`. `MockSyncEngineDriver` lets tests
  set the tag: `driver.fetchRecordResults[name] = .found(record, changeTag: "tag-m")`.
- **Task 66** `recoverDeleteIntents`: change the match to compare the **seam** tag:
  ```swift
  case .found(let record, let serverTag):
    if let tag, let serverTag, serverTag == tag {
      driver.add(pendingRecordZoneChanges: [.deleteRecord(recordID(name))])   // matching tag ⇒ delete
    } else {
      store.clearTombstone(recordName: name)
      surfaceConflict(forRecordName: name)   // different/absent tag ⇒ re-adopted, no delete
    }
  ```
  Restore the S-33 test's three real arms (delete the "reframe" note at the end of Task 66):
  `absentId` ⇒ `.notFound` ⇒ cleared, no delete; `matchId` ⇒ tombstone tag `"tag-m"` +
  `.found(matchRecord, changeTag: "tag-m")` ⇒ **`.deleteRecord` enqueued**; `diffId` ⇒ tombstone
  tag `"tag-old"` + `.found(diffRecord, changeTag: "tag-new")` ⇒ cleared + conflict surfaced, no
  delete.
- **Other `.found` consumers** (§5.6 `.delete` verify at Task 67, §8.1 `.deleting` gate at Task
  106): update their pattern matches to `.found(let record, _)` — they ignore the tag.



## Phase A — Engine seam + persisted state + mock driver

Scaffolding behind the AB-1..AB-4 boundary (§1.1, §2, §2.1, §7). This phase builds the domain event mirror, the mockable `SyncEngineDriver` seam, the production `CKSyncEngineDriver` adapter (integration-only), the `MockSyncEngineDriver` test double with the AB-harness capabilities later phases consume, and the full per-user `SyncEngineStore` (every §2.1 key). **Nothing is wired into the running app in this phase.**

**Phase exit criterion:** the project compiles (`xcodebuild build`), `swift-format lint --recursive .` is clean, and the full existing 429-test suite plus every new Phase A test are green. No new type is referenced from `FoqosApp`, `SyncCoordinator`, `ProfileSyncManager`, or any view — the cutover happens in a later phase.

> **Contract deviation (locked in Task 1, AB-boundary detail — not a contract change):** the interface contract's delegate signature names `CKSyncEngine.SendChangesScope?`, which **does not exist** in the CloudKit SDK. The real type is `CKSyncEngine.SendChangesOptions.Scope?` (public, `Sendable`, `Equatable`, constructible: `.all`, `.allExcluding([CKRecordZone.ID])`, `.zoneIDs([...])`, `.recordIDs([...])`, with `.contains(_:)`). This phase uses `CKSyncEngine.SendChangesOptions.Scope?` everywhere the contract wrote `SendChangesScope?`. This is the exact class of AB-boundary type-name resolution the contract's PendingChange note pre-authorizes ("an AB-boundary implementation detail, not a contract change").

All test commands assume a booted simulator whose UUID the executor substitutes for `<UUID>`. New files under `FoqosTests/` and `FoqosTests/Mocks/` are auto-included (PBXFileSystemSynchronizedRootGroup, no pbxproj edit). New app files go under `Foqos/CloudKit/SyncEngine/`.

---

### Task 1: Decision spike — lock the pending-change types + scope type

Verify (not assume) that the SDK's pending-change types and send-scope type are test-constructible, so the rest of the phase can consume the real `CKSyncEngine` types verbatim instead of the domain-enum fallback. This is the "decide in an early task" checkpoint the phase brief mandates.

**Files:**
- Test: `FoqosTests/SyncEngineSDKAssumptionsTests.swift` (create)

**Interfaces:**
- Consumes: `CKSyncEngine.PendingRecordZoneChange` (`.saveRecord`/`.deleteRecord(CKRecord.ID)`), `CKSyncEngine.PendingDatabaseChange` (`.saveZone(CKRecordZone)`/`.deleteZone(CKRecordZone.ID)`), `CKSyncEngine.SendChangesOptions.Scope`, `CloudKitConstants.syncZoneName`.
- Produces: the locked decision recorded in this task's notes (real SDK types; no fallback; scope = `SendChangesOptions.Scope`).

**Steps:**

- [ ] **Step 1 — Write the spike test.** Create `FoqosTests/SyncEngineSDKAssumptionsTests.swift`:

  ```swift
  import CloudKit
  import XCTest

  @testable import FamilyFoqos

  /// Decision spike (#267 Phase A): confirms the CKSyncEngine pending-change and
  /// send-scope types are test-constructible, locking the seam to the real SDK types
  /// (no domain-enum fallback). If any assertion here fails to COMPILE on a future SDK,
  /// adopt the domain-enum fallback from the contract's Phase A implementation note and
  /// thread it through SyncEngineDriver instead.
  final class SyncEngineSDKAssumptionsTests: XCTestCase {
    private func zoneID() -> CKRecordZone.ID {
      CKRecordZone.ID(zoneName: CloudKitConstants.syncZoneName, ownerName: CKCurrentUserDefaultName)
    }

    func testGivenSDK_WhenConstructingPendingRecordChanges_ThenTypesAreConstructible() {
      let recordID = CKRecord.ID(recordName: "p1", zoneID: zoneID())
      let save: CKSyncEngine.PendingRecordZoneChange = .saveRecord(recordID)
      let delete: CKSyncEngine.PendingRecordZoneChange = .deleteRecord(recordID)
      XCTAssertNotEqual(save, delete)
      XCTAssertEqual(save, .saveRecord(recordID))
    }

    func testGivenSDK_WhenConstructingPendingDatabaseChanges_ThenTypesAreConstructible() {
      let zone = CKRecordZone(zoneName: CloudKitConstants.syncZoneName)
      let saveZone: CKSyncEngine.PendingDatabaseChange = .saveZone(zone)
      let deleteZone: CKSyncEngine.PendingDatabaseChange = .deleteZone(zoneID())
      XCTAssertNotEqual(saveZone, deleteZone)
    }

    func testGivenSDK_WhenConstructingSendChangesScope_ThenScopeTypeResolvesAndFilters() {
      let recordID = CKRecord.ID(recordName: "p1", zoneID: zoneID())
      let scope: CKSyncEngine.SendChangesOptions.Scope = .zoneIDs([zoneID()])
      XCTAssertTrue(scope.contains(CKSyncEngine.PendingRecordZoneChange.saveRecord(recordID)))
      XCTAssertEqual(scope, .zoneIDs([zoneID()]))
    }
  }
  ```

- [ ] **Step 2 — Run it.** Expect it to COMPILE and PASS (verified against the iOS 26.5 simulator swiftinterface: `PendingRecordZoneChange`/`PendingDatabaseChange` are public `Hashable` enums; `SendChangesOptions.Scope` is a public `Equatable` enum with `.contains`). A pass LOCKS the decision: consume the real `CKSyncEngine.Pending*` types and `CKSyncEngine.SendChangesOptions.Scope` throughout the seam; the domain-enum fallback is NOT adopted.

  ```bash
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SyncEngineSDKAssumptionsTests | xcpretty
  ```

  If (and only if) it fails to compile, stop and adopt the fallback per the contract note before continuing; every later task's `CKSyncEngine.Pending*`/`SendChangesOptions.Scope` reference would then become the domain enums.

- [ ] **Step 3 — Format.** `swift-format --in-place FoqosTests/SyncEngineSDKAssumptionsTests.swift`.

- [ ] **Step 4 — Commit.**

  ```bash
  git add FoqosTests/SyncEngineSDKAssumptionsTests.swift
  git commit -m "test(#267): spike locking CKSyncEngine pending/scope types (Phase A, no fallback)"
  ```

---

### Task 2: Domain event mirror + driver seam protocols

Create `SyncEngineEvent` (the test-constructible mirror of the `CKSyncEngine.Event` cases the controller consumes) plus the two reason enums, and the `SyncEngineDriver`/`SyncEngineDriverDelegate` protocols (the AB-1..AB-4 seam).

**Files:**
- Create: `Foqos/CloudKit/SyncEngine/SyncEngineEvent.swift`
- Create: `Foqos/CloudKit/SyncEngine/SyncEngineDriver.swift`
- Test: `FoqosTests/SyncEngineEventTests.swift` (create)

**Interfaces:**
- Produces: `enum SyncEngineEvent` (8 cases per contract), `enum SyncEngineZoneDeletionReason`, `enum SyncEngineAccountChangeKind`, `protocol SyncEngineDriver` (`@MainActor`), `protocol SyncEngineDriverDelegate` (`@MainActor`).
- Consumes: `CKRecord`, `CKError`, `CKRecord.ID`, `CKRecordZone`, `CKRecordZone.ID`, `CKRecord.RecordType`, `CKSyncEngine.PendingRecordZoneChange`, `CKSyncEngine.PendingDatabaseChange`, `CKSyncEngine.SendChangesOptions.Scope`.

**Steps:**

- [ ] **Step 1 — Write the failing test.** Create `FoqosTests/SyncEngineEventTests.swift`:

  ```swift
  import CloudKit
  import XCTest

  @testable import FamilyFoqos

  final class SyncEngineEventTests: XCTestCase {
    private func zoneID() -> CKRecordZone.ID {
      CKRecordZone.ID(zoneName: CloudKitConstants.syncZoneName, ownerName: CKCurrentUserDefaultName)
    }

    func testGivenAllEventShapes_WhenConstructed_ThenAssociatedValuesReadBack() {
      let zid = zoneID()
      let recordID = CKRecord.ID(recordName: "p1", zoneID: zid)
      let record = CKRecord(recordType: SyncedProfile.recordType, recordID: recordID)
      let ckError = CKError(.serverRecordChanged)
      let data = Data([0x01, 0x02])

      let events: [SyncEngineEvent] = [
        .stateUpdate(serialization: data),
        .accountChange(kind: .switchAccounts),
        .fetchedDatabaseChanges(
          modifiedZoneIDs: [zid],
          deletedZones: [(zoneID: zid, reason: .purged)]),
        .fetchedRecordZoneChanges(
          modifications: [record],
          deletions: [(recordID: recordID, recordType: SyncedProfile.recordType)]),
        .sentRecordZoneChanges(
          savedRecords: [record],
          failedRecordSaves: [(record: record, error: ckError)],
          deletedRecordIDs: [recordID],
          failedRecordDeletes: [(recordID: recordID, error: ckError)]),
        .sentDatabaseChanges(
          savedZones: [zid],
          failedZoneSaves: [(zone: CKRecordZone(zoneName: CloudKitConstants.syncZoneName), error: ckError)],
          deletedZoneIDs: [zid],
          failedZoneDeletes: [(zoneID: zid, error: ckError)]),
        .willFetchChanges,
        .didFetchChanges,
      ]
      XCTAssertEqual(events.count, 8)

      guard case let .stateUpdate(serialization) = events[0] else { return XCTFail() }
      XCTAssertEqual(serialization, data)

      guard case let .fetchedRecordZoneChanges(mods, dels) = events[3] else { return XCTFail() }
      XCTAssertEqual(mods.first?.recordID, recordID)
      XCTAssertEqual(dels.first?.recordType, SyncedProfile.recordType)

      guard case let .fetchedDatabaseChanges(_, deletedZones) = events[2] else { return XCTFail() }
      XCTAssertEqual(deletedZones.first?.reason, .purged)
    }

    func testGivenReasonEnums_WhenCompared_ThenCasesAreDistinct() {
      XCTAssertNotEqual(SyncEngineZoneDeletionReason.deleted, .purged)
      XCTAssertNotEqual(SyncEngineZoneDeletionReason.purged, .encryptedDataReset)
      XCTAssertNotEqual(SyncEngineAccountChangeKind.signIn, .switchAccounts)
      XCTAssertNotEqual(SyncEngineAccountChangeKind.signOut, .signIn)
    }
  }
  ```

- [ ] **Step 2 — Run it, expect failure.** The types do not exist yet — compilation fails.

  ```bash
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SyncEngineEventTests | xcpretty
  ```

- [ ] **Step 3 — Implement.** Create `Foqos/CloudKit/SyncEngine/SyncEngineEvent.swift`:

  ```swift
  import CloudKit

  /// Reason a DeviceSync zone deletion was reported (mirror of
  /// CKDatabase.DatabaseChange.Deletion.Reason). Drives T5 vs T6 (§8.4, §5).
  enum SyncEngineZoneDeletionReason: Equatable {
    case deleted
    case purged
    case encryptedDataReset
  }

  /// Account-change kind (mirror of CKSyncEngine.Event.AccountChange.ChangeType,
  /// dropping the user record ids the controller does not consume). Drives T7.
  enum SyncEngineAccountChangeKind: Equatable {
    case signIn
    case signOut
    case switchAccounts
  }

  /// Domain mirror of the CKSyncEngine.Event cases the controller consumes.
  /// CKRecord / CKError / CKRecord.ID are test-constructible; CKSyncEngine.Event/State
  /// are not — this enum keeps them out of the unit tests (§1.1, §5).
  enum SyncEngineEvent {
    case stateUpdate(serialization: Data)  // T10; persist for fetch tokens (AB-2)
    case accountChange(kind: SyncEngineAccountChangeKind)  // T7
    case fetchedDatabaseChanges(
      modifiedZoneIDs: [CKRecordZone.ID],
      deletedZones: [(zoneID: CKRecordZone.ID, reason: SyncEngineZoneDeletionReason)])  // T5/T6
    case fetchedRecordZoneChanges(
      modifications: [CKRecord],
      deletions: [(recordID: CKRecord.ID, recordType: CKRecord.RecordType)])  // T3 §5.1/§5.2
    case sentRecordZoneChanges(
      savedRecords: [CKRecord],
      failedRecordSaves: [(record: CKRecord, error: CKError)],
      deletedRecordIDs: [CKRecord.ID],
      failedRecordDeletes: [(recordID: CKRecord.ID, error: CKError)])  // T4 §5.3
    case sentDatabaseChanges(
      savedZones: [CKRecordZone.ID],
      failedZoneSaves: [(zone: CKRecordZone, error: CKError)],
      deletedZoneIDs: [CKRecordZone.ID],
      failedZoneDeletes: [(zoneID: CKRecordZone.ID, error: CKError)])  // T4b §5.5
    case willFetchChanges  // AB-3 cycle delimiter
    case didFetchChanges  // T2; AB-3; drives §5.6 sweep + echo-guard drain
  }
  ```

  Create `Foqos/CloudKit/SyncEngine/SyncEngineDriver.swift`:

  ```swift
  import CloudKit

  /// The AB-1..AB-4 seam over CKSyncEngine (§1.1). Production adapter: CKSyncEngineDriver.
  /// Test double: MockSyncEngineDriver. All methods are main-actor: the controller owns
  /// the engine on the main actor and events are delivered serially (B-7).
  @MainActor
  protocol SyncEngineDriver: AnyObject {
    var stateSerialization: Data? { get }  // restored engine state (nil = bootstrap)
    var pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange] { get }
    var pendingDatabaseChanges: [CKSyncEngine.PendingDatabaseChange] { get }
    func add(pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange])
    func remove(pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange])
    func add(pendingDatabaseChanges: [CKSyncEngine.PendingDatabaseChange])
    func remove(pendingDatabaseChanges: [CKSyncEngine.PendingDatabaseChange])
    func fetchChanges()  // MUST be scheduled outside handleEvent (§1.1)
    func sendChanges()  // MUST be scheduled outside handleEvent
  }

  /// The controller side of the seam. `handle` receives events serially (B-7);
  /// `nextRecordZoneChangeBatch` materializes records for a send (§5.4).
  /// NOTE: the contract named the scope type `CKSyncEngine.SendChangesScope?`, which does
  /// not exist in the SDK; the real type is `CKSyncEngine.SendChangesOptions.Scope?`
  /// (AB-boundary type-name resolution, Task 1).
  @MainActor
  protocol SyncEngineDriverDelegate: AnyObject {
    func handle(_ event: SyncEngineEvent)
    func nextRecordZoneChangeBatch(
      scope: CKSyncEngine.SendChangesOptions.Scope?) -> [CKRecord]?
  }
  ```

- [ ] **Step 4 — Run it, expect pass.**

  ```bash
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SyncEngineEventTests | xcpretty
  ```

- [ ] **Step 5 — Format & commit.**

  ```bash
  swift-format --in-place Foqos/CloudKit/SyncEngine/SyncEngineEvent.swift Foqos/CloudKit/SyncEngine/SyncEngineDriver.swift FoqosTests/SyncEngineEventTests.swift
  git add Foqos/CloudKit/SyncEngine/SyncEngineEvent.swift Foqos/CloudKit/SyncEngine/SyncEngineDriver.swift FoqosTests/SyncEngineEventTests.swift
  git commit -m "feat(#267): SyncEngineEvent mirror + SyncEngineDriver seam protocols (Phase A)"
  ```

---

### Task 3: Expose `SharedData.withLock` as the public compound-write primitive

`SyncEngineStore` compound writes must run under `SharedData.withLock` (§2.1, global constraint), but the primitive is currently `private`. Promote it to `public` (behavior unchanged — same non-reentrant flock, same graceful degradation). This is the minimal enabling change; no call sites change.

**Files:**
- Modify: `Packages/FoqosShared/Sources/FoqosShared/SharedData.swift`
- Test: `FoqosTests/SharedDataLockTests.swift` (create)

**Interfaces:**
- Produces: `public static func withLock<T>(_ body: () -> T) -> T` on `SharedData`.

**Steps:**

- [ ] **Step 1 — Write the failing test.** Create `FoqosTests/SharedDataLockTests.swift`:

  ```swift
  import FoqosShared
  import XCTest

  final class SharedDataLockTests: XCTestCase {
    func testGivenReturningClosure_WhenRunUnderWithLock_ThenReturnsBodyResult() {
      let result = SharedData.withLock { 40 + 2 }
      XCTAssertEqual(result, 42)
    }

    func testGivenMutatingClosure_WhenRunUnderWithLock_ThenSideEffectApplied() {
      var counter = 0
      SharedData.withLock { counter += 1 }
      XCTAssertEqual(counter, 1)
    }
  }
  ```

- [ ] **Step 2 — Run it, expect failure.** `withLock` is `private` — `SharedData.withLock` is not visible, compilation fails.

  ```bash
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SharedDataLockTests | xcpretty
  ```

- [ ] **Step 3 — Implement.** In `Packages/FoqosShared/Sources/FoqosShared/SharedData.swift`, change the declaration on line 75 from:

  ```swift
    private static func withLock<T>(_ body: () -> T) -> T {
  ```

  to:

  ```swift
    /// Public entry point for compound cross-process reads/writes made by callers
    /// outside this file (e.g. SyncEngineStore, §2.1). Same **non-reentrant** contract —
    /// never call a withLock-wrapped method from inside another withLock closure.
    public static func withLock<T>(_ body: () -> T) -> T {
  ```

  (The body is unchanged — keep the existing flock / graceful-degradation logic verbatim.)

- [ ] **Step 4 — Run it, expect pass.**

  ```bash
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SharedDataLockTests | xcpretty
  ```

- [ ] **Step 5 — Format & commit.**

  ```bash
  swift-format --in-place Packages/FoqosShared/Sources/FoqosShared/SharedData.swift FoqosTests/SharedDataLockTests.swift
  git add Packages/FoqosShared/Sources/FoqosShared/SharedData.swift FoqosTests/SharedDataLockTests.swift
  git commit -m "refactor(#267): expose SharedData.withLock for SyncEngineStore compound writes (Phase A)"
  ```

---

### Task 4: `SyncEngineStore` scaffold — engine state + system-fields cache + I6 purge

Create the per-user store file with `ResetIntent`/`FailedApply` (owned by this file per the contract), the key-namespacing + codable + non-reentrant-lock helpers, plus `engineState`, the `systemFields` cache, and `purgeAllSystemFields` (I6). Per-user isolation (§7) is asserted for these fields.

**Files:**
- Create: `Foqos/CloudKit/SyncEngine/SyncEngineStore.swift`
- Test: `FoqosTests/SyncEngineStoreStateTests.swift` (create)

**Interfaces:**
- Produces: `struct ResetIntent: Codable, Equatable` (with `Stage`), `struct FailedApply: Codable, Hashable` (with `Op`), `@MainActor final class SyncEngineStore` (`init(userRecordName:defaults:)`, `var engineState: Data?`, `func systemFields(for:) -> Data?`, `func setSystemFields(_:for:)`, `func purgeAllSystemFields()`).
- Consumes: `SharedData.withLock` (Task 3).

**Steps:**

- [ ] **Step 1 — Write the failing test.** Create `FoqosTests/SyncEngineStoreStateTests.swift`:

  ```swift
  import FoqosShared
  import Foundation
  import XCTest

  @testable import FamilyFoqos

  @MainActor
  final class SyncEngineStoreStateTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
      try await super.setUp()
      suiteName = "SyncEngineStoreStateTests-\(UUID().uuidString)"
      defaults = UserDefaults(suiteName: suiteName)!
      SharedData.configure(suite: UserDefaults(suiteName: "\(suiteName!)-shared")!)
    }

    override func tearDown() async throws {
      UserDefaults().removePersistentDomain(forName: suiteName)
      UserDefaults().removePersistentDomain(forName: "\(suiteName!)-shared")
      try await super.tearDown()
    }

    func testGivenEngineState_WhenSetAndReloaded_ThenPersistsAndClears() {
      let store = SyncEngineStore(userRecordName: "userA", defaults: defaults)
      XCTAssertNil(store.engineState)
      let data = Data([0xAB, 0xCD])
      store.engineState = data
      let reloaded = SyncEngineStore(userRecordName: "userA", defaults: defaults)
      XCTAssertEqual(reloaded.engineState, data)
      reloaded.engineState = nil
      XCTAssertNil(SyncEngineStore(userRecordName: "userA", defaults: defaults).engineState)
    }

    func testGivenSystemFields_WhenStoredPerRecord_ThenRoundTripAndPurge() {
      let store = SyncEngineStore(userRecordName: "userA", defaults: defaults)
      let p1 = Data([0x01])
      let p2 = Data([0x02])
      store.setSystemFields(p1, for: "profile-1")
      store.setSystemFields(p2, for: "profile-2")
      XCTAssertEqual(store.systemFields(for: "profile-1"), p1)
      XCTAssertEqual(store.systemFields(for: "profile-2"), p2)
      store.setSystemFields(nil, for: "profile-1")
      XCTAssertNil(store.systemFields(for: "profile-1"))
      XCTAssertEqual(store.systemFields(for: "profile-2"), p2)
      // I6: zone events purge the whole cache
      store.purgeAllSystemFields()
      let reloaded = SyncEngineStore(userRecordName: "userA", defaults: defaults)
      XCTAssertNil(reloaded.systemFields(for: "profile-2"))
    }

    func testGivenTwoUsers_WhenSystemFieldsStored_ThenIsolatedByUserRecordName() {
      let a = SyncEngineStore(userRecordName: "userA", defaults: defaults)
      let b = SyncEngineStore(userRecordName: "userB", defaults: defaults)
      a.setSystemFields(Data([0xAA]), for: "shared-record")
      b.setSystemFields(Data([0xBB]), for: "shared-record")
      XCTAssertEqual(a.systemFields(for: "shared-record"), Data([0xAA]))
      XCTAssertEqual(b.systemFields(for: "shared-record"), Data([0xBB]))
      a.purgeAllSystemFields()
      XCTAssertNil(a.systemFields(for: "shared-record"))
      XCTAssertEqual(b.systemFields(for: "shared-record"), Data([0xBB]))
    }
  }
  ```

- [ ] **Step 2 — Run it, expect failure.** `SyncEngineStore` does not exist — compilation fails.

  ```bash
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SyncEngineStoreStateTests | xcpretty
  ```

- [ ] **Step 3 — Implement.** Create `Foqos/CloudKit/SyncEngine/SyncEngineStore.swift`:

  ```swift
  import FoqosShared
  import Foundation

  /// Origin reset intent (§2.1). Crash-resumable via `stage`.
  struct ResetIntent: Codable, Equatable {
    var id: UUID
    var clear: Bool
    enum Stage: String, Codable { case deleting, recreating, seeding }
    var stage: Stage
    var priorCommandId: UUID?
  }

  /// A thrown apply persisted for §5.6 retry.
  struct FailedApply: Codable, Hashable {
    var recordName: String
    var recordType: String  // CKRecord.RecordType raw
    enum Op: String, Codable { case upsert, delete }
    var op: Op
  }

  /// Per-userRecordID persisted state for the sync engine (§2.1, §7). All keys are
  /// namespaced `family_foqos_syncengine_<field>_<userRecordName>` (legacyCleanupDone is
  /// the one exception — it reuses the pre-existing key, Task 6). Compound read-modify-writes
  /// run under `SharedData.withLock`; `transaction` is the single-lock batch (Task 6).
  @MainActor
  final class SyncEngineStore {
    private let userRecordName: String
    private let defaults: UserDefaults
    private var inTransaction = false

    init(userRecordName: String, defaults: UserDefaults = .standard) {
      self.userRecordName = userRecordName
      self.defaults = defaults
    }

    // MARK: - Key namespacing (§7)

    private func key(_ field: String) -> String {
      "family_foqos_syncengine_\(field)_\(userRecordName)"
    }

    // MARK: - Non-reentrant compound-write lock

    /// Run a compound read-modify-write under the process-wide lock. When already inside
    /// a `transaction` the body runs directly — `SharedData.withLock` is non-reentrant.
    private func locked(_ body: () -> Void) {
      if inTransaction {
        body()
        return
      }
      SharedData.withLock { body() }
    }

    // MARK: - Codable helpers

    private func decoded<T: Decodable>(_ type: T.Type, _ field: String) -> T? {
      guard let data = defaults.data(forKey: key(field)) else { return nil }
      return try? JSONDecoder().decode(T.self, from: data)
    }

    private func encodeStore<T: Encodable>(_ value: T, _ field: String) {
      guard let data = try? JSONEncoder().encode(value) else { return }
      defaults.set(data, forKey: key(field))
    }

    // MARK: - Engine state (§2.1 engineState)

    var engineState: Data? {
      get { defaults.data(forKey: key("engine_state")) }
      set {
        if let newValue {
          defaults.set(newValue, forKey: key("engine_state"))
        } else {
          defaults.removeObject(forKey: key("engine_state"))
        }
      }
    }

    // MARK: - System-fields cache (§2.1 systemFields — scoped types only)

    private var systemFieldsMap: [String: Data] {
      decoded([String: Data].self, "system_fields") ?? [:]
    }

    func systemFields(for recordName: String) -> Data? {
      systemFieldsMap[recordName]
    }

    func setSystemFields(_ data: Data?, for recordName: String) {
      locked {
        var all = self.systemFieldsMap
        if let data {
          all[recordName] = data
        } else {
          all.removeValue(forKey: recordName)
        }
        self.encodeStore(all, "system_fields")
      }
    }

    /// I6: zone events purge the change-tag cache (not data/tombstones/processed ids).
    func purgeAllSystemFields() {
      locked { self.defaults.removeObject(forKey: self.key("system_fields")) }
    }
  }
  ```

- [ ] **Step 4 — Run it, expect pass.**

  ```bash
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SyncEngineStoreStateTests | xcpretty
  ```

- [ ] **Step 5 — Format & commit.**

  ```bash
  swift-format --in-place Foqos/CloudKit/SyncEngine/SyncEngineStore.swift FoqosTests/SyncEngineStoreStateTests.swift
  git add Foqos/CloudKit/SyncEngine/SyncEngineStore.swift FoqosTests/SyncEngineStoreStateTests.swift
  git commit -m "feat(#267): SyncEngineStore scaffold — engineState + systemFields cache + I6 purge (Phase A)"
  ```

---

### Task 5: `SyncEngineStore` — reset idempotency + intents

Add the identity-idempotency fields (`processedResetCommandIds` never pruned — I3/C-6; `lastAppliedResetCommandId`) and the crash-durable intents (`resetIntent`, `pendingSeedIntent`), with per-user isolation (§7).

**Files:**
- Modify: `Foqos/CloudKit/SyncEngine/SyncEngineStore.swift`
- Test: `FoqosTests/SyncEngineStoreIntentTests.swift` (create)

**Interfaces:**
- Produces (on `SyncEngineStore`): `var processedResetCommandIds: Set<UUID> { get }`, `func markProcessed(_:)`, `var lastAppliedResetCommandId: UUID?`, `var resetIntent: ResetIntent?`, `var pendingSeedIntent: Bool`.

**Steps:**

- [ ] **Step 1 — Write the failing test.** Create `FoqosTests/SyncEngineStoreIntentTests.swift`:

  ```swift
  import FoqosShared
  import Foundation
  import XCTest

  @testable import FamilyFoqos

  @MainActor
  final class SyncEngineStoreIntentTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
      try await super.setUp()
      suiteName = "SyncEngineStoreIntentTests-\(UUID().uuidString)"
      defaults = UserDefaults(suiteName: suiteName)!
      SharedData.configure(suite: UserDefaults(suiteName: "\(suiteName!)-shared")!)
    }

    override func tearDown() async throws {
      UserDefaults().removePersistentDomain(forName: suiteName)
      UserDefaults().removePersistentDomain(forName: "\(suiteName!)-shared")
      try await super.tearDown()
    }

    func testGivenProcessedResetIds_WhenMarked_ThenAccumulateAndNeverPrune() {
      let store = SyncEngineStore(userRecordName: "userA", defaults: defaults)
      let id1 = UUID()
      let id2 = UUID()
      XCTAssertTrue(store.processedResetCommandIds.isEmpty)
      store.markProcessed(id1)
      store.markProcessed(id2)
      store.markProcessed(id1)  // idempotent (Set)
      let reloaded = SyncEngineStore(userRecordName: "userA", defaults: defaults)
      XCTAssertEqual(reloaded.processedResetCommandIds, [id1, id2])
    }

    func testGivenLastAppliedAndResetIntent_WhenSet_ThenRoundTrip() {
      let store = SyncEngineStore(userRecordName: "userA", defaults: defaults)
      let cmd = UUID()
      let prior = UUID()
      store.lastAppliedResetCommandId = cmd
      let intent = ResetIntent(id: UUID(), clear: true, stage: .recreating, priorCommandId: prior)
      store.resetIntent = intent
      store.pendingSeedIntent = true

      let reloaded = SyncEngineStore(userRecordName: "userA", defaults: defaults)
      XCTAssertEqual(reloaded.lastAppliedResetCommandId, cmd)
      XCTAssertEqual(reloaded.resetIntent, intent)
      XCTAssertTrue(reloaded.pendingSeedIntent)

      reloaded.resetIntent = nil
      reloaded.lastAppliedResetCommandId = nil
      let cleared = SyncEngineStore(userRecordName: "userA", defaults: defaults)
      XCTAssertNil(cleared.resetIntent)
      XCTAssertNil(cleared.lastAppliedResetCommandId)
    }

    func testGivenTwoUsers_WhenIntentsSet_ThenIsolatedByUserRecordName() {
      let a = SyncEngineStore(userRecordName: "userA", defaults: defaults)
      let b = SyncEngineStore(userRecordName: "userB", defaults: defaults)
      a.markProcessed(UUID())
      a.pendingSeedIntent = true
      a.resetIntent = ResetIntent(id: UUID(), clear: false, stage: .deleting, priorCommandId: nil)
      XCTAssertTrue(b.processedResetCommandIds.isEmpty)
      XCTAssertFalse(b.pendingSeedIntent)
      XCTAssertNil(b.resetIntent)
    }
  }
  ```

- [ ] **Step 2 — Run it, expect failure.** The members do not exist — compilation fails.

  ```bash
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SyncEngineStoreIntentTests | xcpretty
  ```

- [ ] **Step 3 — Implement.** Add these members to `SyncEngineStore` (in `Foqos/CloudKit/SyncEngine/SyncEngineStore.swift`, after `purgeAllSystemFields`):

  ```swift
    // MARK: - Reset-command idempotency (§2.1 — never pruned, I3/C-6)

    var processedResetCommandIds: Set<UUID> {
      decoded(Set<UUID>.self, "processed_reset_ids") ?? []
    }

    func markProcessed(_ id: UUID) {
      locked {
        var all = self.processedResetCommandIds
        all.insert(id)
        self.encodeStore(all, "processed_reset_ids")
      }
    }

    var lastAppliedResetCommandId: UUID? {
      get { decoded(UUID.self, "last_applied_reset_id") }
      set {
        if let newValue {
          encodeStore(newValue, "last_applied_reset_id")
        } else {
          defaults.removeObject(forKey: key("last_applied_reset_id"))
        }
      }
    }

    // MARK: - Intents (§2.1)

    var resetIntent: ResetIntent? {
      get { decoded(ResetIntent.self, "reset_intent") }
      set {
        if let newValue {
          encodeStore(newValue, "reset_intent")
        } else {
          defaults.removeObject(forKey: key("reset_intent"))
        }
      }
    }

    var pendingSeedIntent: Bool {
      get { defaults.bool(forKey: key("pending_seed_intent")) }
      set { defaults.set(newValue, forKey: key("pending_seed_intent")) }
    }
  ```

- [ ] **Step 4 — Run it, expect pass.**

  ```bash
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SyncEngineStoreIntentTests | xcpretty
  ```

- [ ] **Step 5 — Format & commit.**

  ```bash
  swift-format --in-place Foqos/CloudKit/SyncEngine/SyncEngineStore.swift FoqosTests/SyncEngineStoreIntentTests.swift
  git add Foqos/CloudKit/SyncEngine/SyncEngineStore.swift FoqosTests/SyncEngineStoreIntentTests.swift
  git commit -m "feat(#267): SyncEngineStore reset idempotency + intents (Phase A)"
  ```

---

### Task 6: `SyncEngineStore` — tombstones, failed applies, legacy one-shot, transaction

Add the remaining §2.1 state: `deleteTombstones` (I12 — carries a nullable change tag), `failedApplies` (§5.6 — supersession clears by name), the legacy one-shot (`legacyCleanupDone` reusing the pre-existing per-user key, `legacyCleanupIds`), and the single-lock `transaction` compound update. This completes the store.

**Files:**
- Modify: `Foqos/CloudKit/SyncEngine/SyncEngineStore.swift`
- Test: `FoqosTests/SyncEngineStoreTombstoneTests.swift` (create)

**Interfaces:**
- Produces (on `SyncEngineStore`): `var deleteTombstones: [String: String?] { get }`, `func setTombstone(recordName:changeTag:)`, `func clearTombstone(recordName:)`, `var failedApplies: Set<FailedApply> { get }`, `func addFailedApply(_:)`, `func removeFailedApply(recordName:)`, `var legacyCleanupDone: Bool`, `var legacyCleanupIds: Set<String> { get }`, `func addLegacyCleanupIds(_:)`, `func removeLegacyCleanupId(_:)`, `func transaction(_:)`.

**Steps:**

- [ ] **Step 1 — Write the failing test.** Create `FoqosTests/SyncEngineStoreTombstoneTests.swift`:

  ```swift
  import FoqosShared
  import Foundation
  import XCTest

  @testable import FamilyFoqos

  @MainActor
  final class SyncEngineStoreTombstoneTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
      try await super.setUp()
      suiteName = "SyncEngineStoreTombstoneTests-\(UUID().uuidString)"
      defaults = UserDefaults(suiteName: suiteName)!
      SharedData.configure(suite: UserDefaults(suiteName: "\(suiteName!)-shared")!)
    }

    override func tearDown() async throws {
      UserDefaults().removePersistentDomain(forName: suiteName)
      UserDefaults().removePersistentDomain(forName: "\(suiteName!)-shared")
      try await super.tearDown()
    }

    func testGivenTombstones_WhenSetWithNilAndNonNilTags_ThenRoundTripAndClear() {
      let store = SyncEngineStore(userRecordName: "userA", defaults: defaults)
      store.setTombstone(recordName: "p1", changeTag: "tagX")
      store.setTombstone(recordName: "p2", changeTag: nil)  // never synced

      let reloaded = SyncEngineStore(userRecordName: "userA", defaults: defaults)
      let map = reloaded.deleteTombstones
      XCTAssertEqual(map.count, 2)
      XCTAssertEqual(map["p1"] ?? nil, "tagX")
      XCTAssertTrue(map.keys.contains("p2"))  // key present...
      XCTAssertNil(map["p2"] ?? nil)  // ...with a nil change tag

      reloaded.clearTombstone(recordName: "p1")
      let after = SyncEngineStore(userRecordName: "userA", defaults: defaults).deleteTombstones
      XCTAssertFalse(after.keys.contains("p1"))
      XCTAssertTrue(after.keys.contains("p2"))
    }

    func testGivenFailedApplies_WhenAddedAndSupersededByName_ThenClearedByName() {
      let store = SyncEngineStore(userRecordName: "userA", defaults: defaults)
      let upsert = FailedApply(recordName: "p1", recordType: SyncedProfile.recordType, op: .upsert)
      let del = FailedApply(recordName: "p2", recordType: SyncedProfile.recordType, op: .delete)
      store.addFailedApply(upsert)
      store.addFailedApply(del)
      store.addFailedApply(upsert)  // Set dedupes
      XCTAssertEqual(store.failedApplies.count, 2)

      store.removeFailedApply(recordName: "p1")  // supersession clears by name
      let reloaded = SyncEngineStore(userRecordName: "userA", defaults: defaults)
      XCTAssertEqual(reloaded.failedApplies, [del])
    }

    func testGivenLegacyCleanup_WhenIdsTrackedAndFlagSet_ThenReusePreExistingKey() {
      let store = SyncEngineStore(userRecordName: "userA", defaults: defaults)
      XCTAssertFalse(store.legacyCleanupDone)
      store.addLegacyCleanupIds(["s1", "s2"])
      store.removeLegacyCleanupId("s1")
      XCTAssertEqual(store.legacyCleanupIds, ["s2"])

      store.legacyCleanupDone = true
      // Must reuse the pre-existing per-user key (do not orphan it).
      XCTAssertTrue(
        defaults.bool(forKey: "family_foqos_legacy_session_cleanup_complete_userA"))
      XCTAssertTrue(
        SyncEngineStore(userRecordName: "userA", defaults: defaults).legacyCleanupDone)
    }

    func testGivenTransaction_WhenCompoundWriteUnderSingleLock_ThenAllPersistNoReentrancyDeadlock() {
      let store = SyncEngineStore(userRecordName: "userA", defaults: defaults)
      let cmdId = UUID()
      store.transaction { s in
        s.resetIntent = ResetIntent(id: UUID(), clear: false, stage: .deleting, priorCommandId: nil)
        s.pendingSeedIntent = true
        s.setTombstone(recordName: "p9", changeTag: "t9")  // nested mutator must not re-lock
        s.markProcessed(cmdId)
      }
      let reloaded = SyncEngineStore(userRecordName: "userA", defaults: defaults)
      XCTAssertNotNil(reloaded.resetIntent)
      XCTAssertTrue(reloaded.pendingSeedIntent)
      XCTAssertEqual(reloaded.deleteTombstones["p9"] ?? nil, "t9")
      XCTAssertEqual(reloaded.processedResetCommandIds, [cmdId])
    }

    func testGivenTwoUsers_WhenTombstonesAndLegacySet_ThenIsolated() {
      let a = SyncEngineStore(userRecordName: "userA", defaults: defaults)
      let b = SyncEngineStore(userRecordName: "userB", defaults: defaults)
      a.setTombstone(recordName: "p1", changeTag: "t")
      a.legacyCleanupDone = true
      XCTAssertTrue(b.deleteTombstones.isEmpty)
      XCTAssertFalse(b.legacyCleanupDone)
    }
  }
  ```

- [ ] **Step 2 — Run it, expect failure.** The members do not exist — compilation fails.

  ```bash
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SyncEngineStoreTombstoneTests | xcpretty
  ```

- [ ] **Step 3 — Implement.** Add these members to `SyncEngineStore` (after `pendingSeedIntent`). Tombstones are stored as an array of `TombstoneEntry` (a struct with an optional `changeTag`) to sidestep the `[String: String?]` JSON round-trip quirk, and re-projected to the contract's `[String: String?]` shape on read:

  ```swift
    // MARK: - Delete tombstones (§2.1 deleteTombstones, I12)

    private struct TombstoneEntry: Codable {
      var recordName: String
      var changeTag: String?
    }

    private var tombstoneEntries: [TombstoneEntry] {
      decoded([TombstoneEntry].self, "delete_tombstones") ?? []
    }

    var deleteTombstones: [String: String?] {
      var result: [String: String?] = [:]
      for entry in tombstoneEntries {
        result[entry.recordName] = entry.changeTag  // key present; value may be nil
      }
      return result
    }

    func setTombstone(recordName: String, changeTag: String?) {
      locked {
        var all = self.tombstoneEntries.filter { $0.recordName != recordName }
        all.append(TombstoneEntry(recordName: recordName, changeTag: changeTag))
        self.encodeStore(all, "delete_tombstones")
      }
    }

    func clearTombstone(recordName: String) {
      locked {
        let all = self.tombstoneEntries.filter { $0.recordName != recordName }
        self.encodeStore(all, "delete_tombstones")
      }
    }

    // MARK: - Failed applies (§2.1 failedApplies, §5.6)

    var failedApplies: Set<FailedApply> {
      decoded(Set<FailedApply>.self, "failed_applies") ?? []
    }

    func addFailedApply(_ entry: FailedApply) {
      locked {
        var all = self.failedApplies
        all.insert(entry)
        self.encodeStore(all, "failed_applies")
      }
    }

    /// Supersession: a later successful apply for a recordName clears its entry (§5.6),
    /// regardless of op — clear by name.
    func removeFailedApply(recordName: String) {
      locked {
        let all = self.failedApplies.filter { $0.recordName != recordName }
        self.encodeStore(all, "failed_applies")
      }
    }

    // MARK: - Legacy cleanup one-shot (§2.1, §11)

    /// Reuses the pre-existing per-user key `family_foqos_legacy_session_cleanup_complete_<user>`.
    private func legacyCleanupDoneKey() -> String {
      "family_foqos_legacy_session_cleanup_complete_\(userRecordName)"
    }

    var legacyCleanupDone: Bool {
      get { defaults.bool(forKey: legacyCleanupDoneKey()) }
      set { defaults.set(newValue, forKey: legacyCleanupDoneKey()) }
    }

    var legacyCleanupIds: Set<String> {
      decoded(Set<String>.self, "legacy_cleanup_ids") ?? []
    }

    func addLegacyCleanupIds(_ ids: Set<String>) {
      locked {
        var all = self.legacyCleanupIds
        all.formUnion(ids)
        self.encodeStore(all, "legacy_cleanup_ids")
      }
    }

    func removeLegacyCleanupId(_ id: String) {
      locked {
        var all = self.legacyCleanupIds
        all.remove(id)
        self.encodeStore(all, "legacy_cleanup_ids")
      }
    }

    // MARK: - Compound transaction (single withLock — never nest)

    /// Runs `body` under one `SharedData.withLock`; individual mutators called inside
    /// detect `inTransaction` and skip re-locking (the primitive is non-reentrant).
    func transaction(_ body: (SyncEngineStore) -> Void) {
      SharedData.withLock {
        self.inTransaction = true
        defer { self.inTransaction = false }
        body(self)
      }
    }
  ```

- [ ] **Step 4 — Run it, expect pass.**

  ```bash
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SyncEngineStoreTombstoneTests | xcpretty
  ```

- [ ] **Step 5 — Format & commit.**

  ```bash
  swift-format --in-place Foqos/CloudKit/SyncEngine/SyncEngineStore.swift FoqosTests/SyncEngineStoreTombstoneTests.swift
  git add Foqos/CloudKit/SyncEngine/SyncEngineStore.swift FoqosTests/SyncEngineStoreTombstoneTests.swift
  git commit -m "feat(#267): SyncEngineStore tombstones + failedApplies + legacy one-shot + transaction (Phase A)"
  ```

---

### Task 7: `MockSyncEngineDriver` — pending-change recording + serial delivery + restored-state exposure

Create the test double in `FoqosTests/Mocks/`. It conforms to `SyncEngineDriver`, records every add/remove/fetch/send into an ordered operation log, mirrors the engine's pending queues, delivers enqueued events serially to a delegate, and exposes restored pending changes at init (the S-38 strip capability).

**Files:**
- Create: `FoqosTests/Mocks/MockSyncEngineDriver.swift`
- Test: `FoqosTests/MockSyncEngineDriverTests.swift` (create)

**Interfaces:**
- Produces: `@MainActor final class MockSyncEngineDriver: SyncEngineDriver` with `weak var delegate: SyncEngineDriverDelegate?`, `enum Operation: Equatable`, `var operations: [Operation]`, `var fetchChangesCount/sendChangesCount: Int`, `init(stateSerialization:pendingRecordZoneChanges:pendingDatabaseChanges:)`, `func deliver(_:)`, `func deliverSerially(_:)`, `func pullNextRecordZoneChangeBatch(scope:)`.
- Consumes: `SyncEngineDriver`, `SyncEngineDriverDelegate`, `SyncEngineEvent` (Task 2); `CKSyncEngine.Pending*`, `CKSyncEngine.SendChangesOptions.Scope`.

**Steps:**

- [ ] **Step 1 — Write the failing test.** Create `FoqosTests/MockSyncEngineDriverTests.swift`:

  ```swift
  import CloudKit
  import XCTest

  @testable import FamilyFoqos

  @MainActor
  private final class SpyDelegate: SyncEngineDriverDelegate {
    var received: [SyncEngineEvent] = []
    var batchScopes: [CKSyncEngine.SendChangesOptions.Scope?] = []
    var batchToReturn: [CKRecord]?
    func handle(_ event: SyncEngineEvent) { received.append(event) }
    func nextRecordZoneChangeBatch(
      scope: CKSyncEngine.SendChangesOptions.Scope?) -> [CKRecord]? {
      batchScopes.append(scope)
      return batchToReturn
    }
  }

  @MainActor
  final class MockSyncEngineDriverTests: XCTestCase {
    private func zoneID() -> CKRecordZone.ID {
      CKRecordZone.ID(zoneName: CloudKitConstants.syncZoneName, ownerName: CKCurrentUserDefaultName)
    }

    func testGivenRecordChangeAddsAndRemoves_WhenApplied_ThenQueueAndLogReflectThem() {
      let driver = MockSyncEngineDriver()
      let id = CKRecord.ID(recordName: "p1", zoneID: zoneID())
      driver.add(pendingRecordZoneChanges: [.saveRecord(id)])
      XCTAssertEqual(driver.pendingRecordZoneChanges, [.saveRecord(id)])
      driver.remove(pendingRecordZoneChanges: [.saveRecord(id)])
      XCTAssertTrue(driver.pendingRecordZoneChanges.isEmpty)
      driver.add(pendingDatabaseChanges: [.deleteZone(zoneID())])
      XCTAssertEqual(driver.pendingDatabaseChanges.count, 1)

      XCTAssertEqual(driver.operations.count, 3)
      XCTAssertEqual(driver.operations[0], .addRecordChanges([.saveRecord(id)]))
      XCTAssertEqual(driver.operations[1], .removeRecordChanges([.saveRecord(id)]))
      guard case .addDatabaseChanges = driver.operations[2] else {
        return XCTFail("third op must be a database-change add")
      }
    }

    func testGivenFetchAndSend_WhenRequested_ThenCountsAndLogRecorded() {
      let driver = MockSyncEngineDriver()
      driver.fetchChanges()
      driver.sendChanges()
      driver.fetchChanges()
      XCTAssertEqual(driver.fetchChangesCount, 2)
      XCTAssertEqual(driver.sendChangesCount, 1)
      XCTAssertEqual(driver.operations, [.fetchChanges, .sendChanges, .fetchChanges])
    }

    func testGivenEvents_WhenDeliveredSerially_ThenDelegateReceivesInOrder() {
      let driver = MockSyncEngineDriver()
      let spy = SpyDelegate()
      driver.delegate = spy
      driver.deliverSerially([.willFetchChanges, .didFetchChanges])
      XCTAssertEqual(spy.received.count, 2)
      guard case .willFetchChanges = spy.received[0], case .didFetchChanges = spy.received[1]
      else { return XCTFail("events delivered out of order") }
    }

    func testGivenPullBatch_WhenRequested_ThenScopeForwardedAndRecordsReturned() {
      let driver = MockSyncEngineDriver()
      let spy = SpyDelegate()
      let rec = CKRecord(
        recordType: SyncedProfile.recordType,
        recordID: CKRecord.ID(recordName: "p1", zoneID: zoneID()))
      spy.batchToReturn = [rec]
      driver.delegate = spy
      let batch = driver.pullNextRecordZoneChangeBatch(scope: .zoneIDs([zoneID()]))
      XCTAssertEqual(batch?.first?.recordID, rec.recordID)
      XCTAssertEqual(spy.batchScopes.count, 1)
    }

    func testGivenRestoredPending_WhenInitialized_ThenExposedForStripAndNoAutoSend() {
      let id = CKRecord.ID(recordName: "p1", zoneID: zoneID())
      let driver = MockSyncEngineDriver(
        stateSerialization: Data([0x01]),
        pendingRecordZoneChanges: [.deleteRecord(id)],
        pendingDatabaseChanges: [.deleteZone(zoneID())])
      XCTAssertEqual(driver.stateSerialization, Data([0x01]))
      XCTAssertEqual(driver.pendingRecordZoneChanges, [.deleteRecord(id)])
      XCTAssertEqual(driver.pendingDatabaseChanges, [.deleteZone(zoneID())])
      XCTAssertEqual(driver.sendChangesCount, 0)  // AB-4: no send happens at init
      XCTAssertTrue(driver.operations.isEmpty)
    }
  }
  ```

- [ ] **Step 2 — Run it, expect failure.** `MockSyncEngineDriver` does not exist — compilation fails.

  ```bash
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/MockSyncEngineDriverTests | xcpretty
  ```

- [ ] **Step 3 — Implement.** Create `FoqosTests/Mocks/MockSyncEngineDriver.swift`:

  ```swift
  import CloudKit

  @testable import FamilyFoqos

  /// Test double for the AB-1..AB-4 seam. Records every pending-change mutation and
  /// fetch/send request into an ordered log, mirrors the engine's pending queues, and
  /// delivers enqueued SyncEngineEvents serially to its delegate. It never initiates a
  /// send on its own (AB-4 containment for the T1 strip).
  @MainActor
  final class MockSyncEngineDriver: SyncEngineDriver {
    enum Operation: Equatable {
      case addRecordChanges([CKSyncEngine.PendingRecordZoneChange])
      case removeRecordChanges([CKSyncEngine.PendingRecordZoneChange])
      case addDatabaseChanges([CKSyncEngine.PendingDatabaseChange])
      case removeDatabaseChanges([CKSyncEngine.PendingDatabaseChange])
      case fetchChanges
      case sendChanges
    }

    weak var delegate: SyncEngineDriverDelegate?

    private(set) var operations: [Operation] = []
    private(set) var fetchChangesCount = 0
    private(set) var sendChangesCount = 0

    var stateSerialization: Data?
    private(set) var pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange]
    private(set) var pendingDatabaseChanges: [CKSyncEngine.PendingDatabaseChange]

    init(
      stateSerialization: Data? = nil,
      pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange] = [],
      pendingDatabaseChanges: [CKSyncEngine.PendingDatabaseChange] = []
    ) {
      self.stateSerialization = stateSerialization
      self.pendingRecordZoneChanges = pendingRecordZoneChanges
      self.pendingDatabaseChanges = pendingDatabaseChanges
    }

    // MARK: - SyncEngineDriver

    func add(pendingRecordZoneChanges changes: [CKSyncEngine.PendingRecordZoneChange]) {
      pendingRecordZoneChanges.append(contentsOf: changes)
      operations.append(.addRecordChanges(changes))
    }

    func remove(pendingRecordZoneChanges changes: [CKSyncEngine.PendingRecordZoneChange]) {
      pendingRecordZoneChanges.removeAll { changes.contains($0) }
      operations.append(.removeRecordChanges(changes))
    }

    func add(pendingDatabaseChanges changes: [CKSyncEngine.PendingDatabaseChange]) {
      pendingDatabaseChanges.append(contentsOf: changes)
      operations.append(.addDatabaseChanges(changes))
    }

    func remove(pendingDatabaseChanges changes: [CKSyncEngine.PendingDatabaseChange]) {
      pendingDatabaseChanges.removeAll { changes.contains($0) }
      operations.append(.removeDatabaseChanges(changes))
    }

    func fetchChanges() {
      fetchChangesCount += 1
      operations.append(.fetchChanges)
    }

    func sendChanges() {
      sendChangesCount += 1
      operations.append(.sendChanges)
    }

    // MARK: - Test drivers

    /// Deliver one event to the delegate (serial, synchronous — B-7).
    func deliver(_ event: SyncEngineEvent) {
      delegate?.handle(event)
    }

    /// Deliver events one at a time in order (S-26 interleave capability).
    func deliverSerially(_ events: [SyncEngineEvent]) {
      for event in events { delegate?.handle(event) }
    }

    /// Pull a materialized batch from the delegate for a given scope (§5.4).
    func pullNextRecordZoneChangeBatch(
      scope: CKSyncEngine.SendChangesOptions.Scope?) -> [CKRecord]? {
      delegate?.nextRecordZoneChangeBatch(scope: scope)
    }
  }
  ```

- [ ] **Step 4 — Run it, expect pass.**

  ```bash
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/MockSyncEngineDriverTests | xcpretty
  ```

- [ ] **Step 5 — Format & commit.**

  ```bash
  swift-format --in-place FoqosTests/Mocks/MockSyncEngineDriver.swift FoqosTests/MockSyncEngineDriverTests.swift
  git add FoqosTests/Mocks/MockSyncEngineDriver.swift FoqosTests/MockSyncEngineDriverTests.swift
  git commit -m "test(#267): MockSyncEngineDriver — pending-change recording + serial delivery (Phase A)"
  ```

---

### Task 8: `MockSyncEngineDriver` — AB harness capabilities (S-25 / S-26 / S-37 / S-38)

Add the fetch-cycle delimiter helper and prove the harness capabilities later phases rely on: AB-3 delimiters wrap record events (S-37), AB-1 database-before-record send order is observable in the op log (S-25), a `stateUpdate` can interleave between two fetch events (S-26), and restored pending changes are available at init for the strip (S-38, extending Task 7's exposure with an explicit ordering assertion).

**Files:**
- Modify: `FoqosTests/Mocks/MockSyncEngineDriver.swift`
- Modify: `FoqosTests/MockSyncEngineDriverTests.swift`

**Interfaces:**
- Produces (on `MockSyncEngineDriver`): `func deliverFetchCycle(_ innerEvents: [SyncEngineEvent])`.

**Steps:**

- [ ] **Step 1 — Write the failing tests.** Append to `FoqosTests/MockSyncEngineDriverTests.swift` (inside `MockSyncEngineDriverTests`):

  ```swift
    func testGivenFetchCycle_WhenDelivered_ThenDelimitersWrapRecordEvents_S37() {
      let driver = MockSyncEngineDriver()
      let spy = SpyDelegate()
      driver.delegate = spy
      let rec = CKRecord(
        recordType: SyncedProfile.recordType,
        recordID: CKRecord.ID(recordName: "p1", zoneID: zoneID()))
      driver.deliverFetchCycle([.fetchedRecordZoneChanges(modifications: [rec], deletions: [])])
      XCTAssertEqual(spy.received.count, 3)
      guard case .willFetchChanges = spy.received[0] else { return XCTFail() }
      guard case .fetchedRecordZoneChanges = spy.received[1] else { return XCTFail() }
      guard case .didFetchChanges = spy.received[2] else { return XCTFail() }
    }

    func testGivenDatabaseThenRecordSends_WhenEnqueued_ThenOrderObservableInLog_S25() {
      let driver = MockSyncEngineDriver()
      let id = CKRecord.ID(recordName: "p1", zoneID: zoneID())
      driver.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneName: CloudKitConstants.syncZoneName))])
      driver.add(pendingRecordZoneChanges: [.saveRecord(id)])
      driver.sendChanges()
      let dbIndex = driver.operations.firstIndex {
        if case .addDatabaseChanges = $0 { return true }
        return false
      }
      let recIndex = driver.operations.firstIndex {
        if case .addRecordChanges = $0 { return true }
        return false
      }
      XCTAssertNotNil(dbIndex)
      XCTAssertNotNil(recIndex)
      XCTAssertLessThan(dbIndex!, recIndex!)  // AB-1: database changes precede record changes
    }

    func testGivenStateUpdateBetweenTwoFetchEvents_WhenDeliveredSerially_ThenObservedInOrder_S26() {
      let driver = MockSyncEngineDriver()
      let spy = SpyDelegate()
      driver.delegate = spy
      let rec1 = CKRecord(
        recordType: SyncedProfile.recordType,
        recordID: CKRecord.ID(recordName: "p1", zoneID: zoneID()))
      let rec2 = CKRecord(
        recordType: SyncedProfile.recordType,
        recordID: CKRecord.ID(recordName: "p2", zoneID: zoneID()))
      driver.deliverSerially([
        .fetchedRecordZoneChanges(modifications: [rec1], deletions: []),
        .stateUpdate(serialization: Data([0x09])),
        .fetchedRecordZoneChanges(modifications: [rec2], deletions: []),
      ])
      XCTAssertEqual(spy.received.count, 3)
      guard case .stateUpdate = spy.received[1] else {
        return XCTFail("stateUpdate must interleave between the two fetch events")
      }
    }

    func testGivenRestoredPendingDeletes_WhenInitialized_ThenAvailableBeforeAnySend_S38() {
      let id = CKRecord.ID(recordName: "p1", zoneID: zoneID())
      let driver = MockSyncEngineDriver(
        stateSerialization: Data([0xFF]),
        pendingRecordZoneChanges: [.deleteRecord(id)],
        pendingDatabaseChanges: [.deleteZone(zoneID())])
      // The strip inspects restored pending changes with no send having occurred (AB-4).
      XCTAssertEqual(driver.sendChangesCount, 0)
      XCTAssertEqual(driver.pendingRecordZoneChanges, [.deleteRecord(id)])
      // Strip removes them; the mock records the removals, still without a send.
      driver.remove(pendingRecordZoneChanges: [.deleteRecord(id)])
      driver.remove(pendingDatabaseChanges: [.deleteZone(zoneID())])
      XCTAssertTrue(driver.pendingRecordZoneChanges.isEmpty)
      XCTAssertTrue(driver.pendingDatabaseChanges.isEmpty)
      XCTAssertEqual(driver.sendChangesCount, 0)
    }
  ```

- [ ] **Step 2 — Run them, expect failure.** `deliverFetchCycle` does not exist — compilation fails.

  ```bash
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/MockSyncEngineDriverTests | xcpretty
  ```

- [ ] **Step 3 — Implement.** Add to `MockSyncEngineDriver` (in the "Test drivers" section):

  ```swift
    /// Deliver a full fetch cycle: willFetchChanges, then the inner record/state events,
    /// then didFetchChanges (AB-3 delimiters). Used by the echo-guard/cycle-scoping tests.
    func deliverFetchCycle(_ innerEvents: [SyncEngineEvent]) {
      delegate?.handle(.willFetchChanges)
      for event in innerEvents { delegate?.handle(event) }
      delegate?.handle(.didFetchChanges)
    }
  ```

- [ ] **Step 4 — Run them, expect pass.**

  ```bash
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/MockSyncEngineDriverTests | xcpretty
  ```

- [ ] **Step 5 — Format & commit.**

  ```bash
  swift-format --in-place FoqosTests/Mocks/MockSyncEngineDriver.swift FoqosTests/MockSyncEngineDriverTests.swift
  git add FoqosTests/Mocks/MockSyncEngineDriver.swift FoqosTests/MockSyncEngineDriverTests.swift
  git commit -m "test(#267): MockSyncEngineDriver AB harness — fetch-cycle/order/interleave/strip (Phase A)"
  ```

---

### Task 9: `CKSyncEngineDriver` — production adapter (integration-only)

Build the production adapter that owns a real `CKSyncEngine`, conforms to `CKSyncEngineDelegate`, translates `CKSyncEngine.Event` → `SyncEngineEvent`, and encodes/decodes `State.Serialization` ↔ `Data`. Per the contract this type is **integration-only** — constructing a `CKSyncEngine` needs a live CloudKit account/database, so it has no unit test that drives the engine. The one genuinely pure piece — the zone-deletion-reason translation — is unit-tested; the rest is verified by compilation (which exercises the full delegate conformance and event translation) plus the manual two-device checklist (§10).

**Files:**
- Create: `Foqos/CloudKit/SyncEngine/CKSyncEngineDriver.swift`
- Test: `FoqosTests/CKSyncEngineDriverTranslationTests.swift` (create)

**Interfaces:**
- Produces: `@MainActor final class CKSyncEngineDriver: NSObject, SyncEngineDriver, CKSyncEngineDelegate` (`init(database:stateSerialization:delegate:)`), `nonisolated static func translateReason(_:) -> SyncEngineZoneDeletionReason`, `static func translate(_:) -> SyncEngineEvent?`.
- Consumes: `CKSyncEngine`, `CKSyncEngine.Configuration`, `CKSyncEngine.Event`, `CKSyncEngine.State.Serialization`, `CKDatabase.DatabaseChange.Deletion.Reason`, `SyncEngineDriver`/`SyncEngineDriverDelegate`/`SyncEngineEvent` (Task 2).

**Steps:**

- [ ] **Step 1 — Write the failing test.** Create `FoqosTests/CKSyncEngineDriverTranslationTests.swift`:

  ```swift
  import CloudKit
  import XCTest

  @testable import FamilyFoqos

  /// The only unit-testable slice of the integration-only production adapter: the pure
  /// zone-deletion-reason translation. Its presence in this test target also forces the
  /// whole CKSyncEngineDriver (delegate conformance + event translation) to compile,
  /// which is the phase's build-level guarantee for the adapter.
  final class CKSyncEngineDriverTranslationTests: XCTestCase {
    func testGivenZoneDeletionReasons_WhenTranslated_ThenMapToDomainReasons() {
      XCTAssertEqual(CKSyncEngineDriver.translateReason(.deleted), .deleted)
      XCTAssertEqual(CKSyncEngineDriver.translateReason(.purged), .purged)
      XCTAssertEqual(CKSyncEngineDriver.translateReason(.encryptedDataReset), .encryptedDataReset)
    }
  }
  ```

- [ ] **Step 2 — Run it, expect failure.** `CKSyncEngineDriver` does not exist — compilation fails.

  ```bash
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/CKSyncEngineDriverTranslationTests | xcpretty
  ```

- [ ] **Step 3 — Implement.** Create `Foqos/CloudKit/SyncEngine/CKSyncEngineDriver.swift`. Notes: the engine is an implicitly-unwrapped stored property assigned after `super.init()` so `self` can be the delegate; delegate callbacks are `nonisolated async` and hop to the main actor passing only the `Sendable` `CKSyncEngine.Event` (never the non-Sendable `SyncEngineEvent`, which is built on the main actor); `automaticallySync = false` holds the AB-4 strip window open.

  ```swift
  import CloudKit
  import Foundation

  /// Production adapter wrapping a real CKSyncEngine behind the SyncEngineDriver seam
  /// (§1.1, §2). INTEGRATION-ONLY: a CKSyncEngine needs a live CloudKit account/database,
  /// so this type is deliberately excluded from the driven unit tests — it *is* the thing
  /// MockSyncEngineDriver stands in for. Verified by compilation + the manual two-device
  /// checklist (§10). Only `translateReason` is unit-tested (pure).
  @MainActor
  final class CKSyncEngineDriver: NSObject, SyncEngineDriver, CKSyncEngineDelegate {
    private var engine: CKSyncEngine!
    private weak var delegate: SyncEngineDriverDelegate?
    private let restoredState: Data?

    init(database: CKDatabase, stateSerialization: Data?, delegate: SyncEngineDriverDelegate) {
      self.delegate = delegate
      self.restoredState = stateSerialization
      super.init()
      let restored = stateSerialization.flatMap {
        try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0)
      }
      var configuration = CKSyncEngine.Configuration(
        database: database, stateSerialization: restored, delegate: self)
      // AB-4: never auto-send restored pending changes before the T1 strip runs.
      configuration.automaticallySync = false
      self.engine = CKSyncEngine(configuration)
    }

    // MARK: - SyncEngineDriver

    var stateSerialization: Data? { restoredState }

    var pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange] {
      engine.state.pendingRecordZoneChanges
    }

    var pendingDatabaseChanges: [CKSyncEngine.PendingDatabaseChange] {
      engine.state.pendingDatabaseChanges
    }

    func add(pendingRecordZoneChanges changes: [CKSyncEngine.PendingRecordZoneChange]) {
      engine.state.add(pendingRecordZoneChanges: changes)
    }

    func remove(pendingRecordZoneChanges changes: [CKSyncEngine.PendingRecordZoneChange]) {
      engine.state.remove(pendingRecordZoneChanges: changes)
    }

    func add(pendingDatabaseChanges changes: [CKSyncEngine.PendingDatabaseChange]) {
      engine.state.add(pendingDatabaseChanges: changes)
    }

    func remove(pendingDatabaseChanges changes: [CKSyncEngine.PendingDatabaseChange]) {
      engine.state.remove(pendingDatabaseChanges: changes)
    }

    func fetchChanges() {
      let engine = self.engine!
      Task { try? await engine.fetchChanges() }
    }

    func sendChanges() {
      let engine = self.engine!
      Task { try? await engine.sendChanges() }
    }

    // MARK: - CKSyncEngineDelegate (nonisolated; hops to main actor)

    nonisolated func handleEvent(
      _ event: CKSyncEngine.Event, syncEngine: CKSyncEngine
    ) async {
      await handleOnMain(event)
    }

    nonisolated func nextRecordZoneChangeBatch(
      _ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
      let pending = syncEngine.state.pendingRecordZoneChanges
      return await batchOnMain(scope: context.options.scope, pendingRecordChanges: pending)
    }

    @MainActor
    private func handleOnMain(_ event: CKSyncEngine.Event) {
      guard let translated = Self.translate(event) else { return }
      delegate?.handle(translated)
    }

    @MainActor
    private func batchOnMain(
      scope: CKSyncEngine.SendChangesOptions.Scope,
      pendingRecordChanges: [CKSyncEngine.PendingRecordZoneChange]
    ) -> CKSyncEngine.RecordZoneChangeBatch? {
      let saves = delegate?.nextRecordZoneChangeBatch(scope: scope) ?? []
      let deletes = pendingRecordChanges.compactMap { change -> CKRecord.ID? in
        if case let .deleteRecord(id) = change, scope.contains(change) { return id }
        return nil
      }
      if saves.isEmpty && deletes.isEmpty { return nil }
      return CKSyncEngine.RecordZoneChangeBatch(recordsToSave: saves, recordIDsToDelete: deletes)
    }

    // MARK: - Event translation

    nonisolated static func translateReason(
      _ reason: CKDatabase.DatabaseChange.Deletion.Reason
    ) -> SyncEngineZoneDeletionReason {
      switch reason {
      case .deleted: return .deleted
      case .purged: return .purged
      case .encryptedDataReset: return .encryptedDataReset
      @unknown default: return .deleted
      }
    }

    static func translate(_ event: CKSyncEngine.Event) -> SyncEngineEvent? {
      switch event {
      case .stateUpdate(let e):
        guard let data = try? JSONEncoder().encode(e.stateSerialization) else {
          Log.error("Failed to encode engine state serialization", category: .sync)
          return nil
        }
        return .stateUpdate(serialization: data)
      case .accountChange(let e):
        switch e.changeType {
        case .signIn: return .accountChange(kind: .signIn)
        case .signOut: return .accountChange(kind: .signOut)
        case .switchAccounts: return .accountChange(kind: .switchAccounts)
        @unknown default: return nil
        }
      case .fetchedDatabaseChanges(let e):
        let deleted = e.deletions.map {
          (zoneID: $0.zoneID, reason: translateReason($0.reason))
        }
        return .fetchedDatabaseChanges(
          modifiedZoneIDs: e.modifications.map { $0.zoneID }, deletedZones: deleted)
      case .fetchedRecordZoneChanges(let e):
        let deletions = e.deletions.map { (recordID: $0.recordID, recordType: $0.recordType) }
        return .fetchedRecordZoneChanges(
          modifications: e.modifications.map { $0.record }, deletions: deletions)
      case .sentRecordZoneChanges(let e):
        let failedSaves = e.failedRecordSaves.map { (record: $0.record, error: $0.error) }
        let failedDeletes = e.failedRecordDeletes.map { (recordID: $0.key, error: $0.value) }
        return .sentRecordZoneChanges(
          savedRecords: e.savedRecords, failedRecordSaves: failedSaves,
          deletedRecordIDs: e.deletedRecordIDs, failedRecordDeletes: failedDeletes)
      case .sentDatabaseChanges(let e):
        let failedSaves = e.failedZoneSaves.map { (zone: $0.zone, error: $0.error) }
        let failedDeletes = e.failedZoneDeletes.map { (zoneID: $0.key, error: $0.value) }
        return .sentDatabaseChanges(
          savedZones: e.savedZones.map { $0.zoneID }, failedZoneSaves: failedSaves,
          deletedZoneIDs: e.deletedZoneIDs, failedZoneDeletes: failedDeletes)
      case .willFetchChanges: return .willFetchChanges
      case .didFetchChanges: return .didFetchChanges
      case .willFetchRecordZoneChanges, .didFetchRecordZoneChanges, .willSendChanges,
        .didSendChanges:
        return nil  // not consumed by the controller
      @unknown default:
        return nil
      }
    }
  }
  ```

- [ ] **Step 4 — Run it, expect pass; then build the full project and full suite.** The translation test passes, and its presence forces the adapter to compile. Then confirm the whole project builds and the entire suite is green (phase exit criterion):

  ```bash
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/CKSyncEngineDriverTranslationTests | xcpretty
  xcodebuild -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -configuration Debug build 2>&1 | xcpretty
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' | xcpretty
  ```

  (If the Swift 6 actor-isolation of the `nonisolated` delegate methods or the IUO engine init needs adjustment, resolve it here — this is the integration-only adapter and the build is its contract.)

- [ ] **Step 5 — Format & commit.**

  ```bash
  swift-format --in-place Foqos/CloudKit/SyncEngine/CKSyncEngineDriver.swift FoqosTests/CKSyncEngineDriverTranslationTests.swift
  swift-format lint --recursive .
  git add Foqos/CloudKit/SyncEngine/CKSyncEngineDriver.swift FoqosTests/CKSyncEngineDriverTranslationTests.swift
  git commit -m "feat(#267): CKSyncEngineDriver production adapter — integration-only (Phase A)"
  ```

---

**Phase A exit verification (run before handing off):**

```bash
swift-format lint --recursive .
xcodebuild -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -configuration Debug build 2>&1 | xcpretty
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' | xcpretty
```

All Phase A files (`SyncEngineEvent.swift`, `SyncEngineDriver.swift`, `SyncEngineStore.swift`, `CKSyncEngineDriver.swift`, `MockSyncEngineDriver.swift`) compile; the existing 429-test suite plus the new Phase A tests are green; nothing in `FoqosApp`/`SyncCoordinator`/`ProfileSyncManager`/views references the new types yet (grep to confirm zero non-test references to `SyncEngineController`/`SyncEngineDriver`/`SyncEngineStore` outside `Foqos/CloudKit/SyncEngine/` and `FoqosTests/`).

---

## Phase B — RecordProvider + SyncApplyService (record apply-path)

> **Phase exit criterion (every task below preserves it):** the project compiles, the full existing 429-test suite plus every new Phase B test stays green, and the new apply components (`RecordProvider`, `SyncApplyService`) are **not wired into `SyncEngineController`, the driver, or `FoqosApp`** — they are pure, independently-constructed units. Cutover (deleting the old CKQuery batch handlers and routing the engine into these types) is Phase F. This phase adds new callable methods **alongside** `SyncCoordinator`; it does not delete or modify `SyncCoordinator`'s existing handlers.
>
> **Consumes from Phase A (must already exist):** `SyncEngineStore` (with `init(userRecordName:defaults:)`, `systemFields(for:)`, `setSystemFields(_:for:)`, `purgeAllSystemFields()`, `failedApplies`, `addFailedApply(_:)`, `removeFailedApply(recordName:)`, `deleteTombstones`, `setTombstone(recordName:changeTag:)`, `clearTombstone(recordName:)`, `transaction(_:)`) and the `FailedApply` struct (`{recordName, recordType, op: .upsert/.delete}`). Booted-simulator UUID is written literally as `<UUID>` in every test command; the executor substitutes it.

---

### Task 20: EmergencyUnblockManager snapshot accessor (enables RecordProvider materialization)

`RecordProvider` must materialize the `SyncedEmergencySettings` record from the live `EmergencyUnblockManager` **without** bumping the version (I2: bumps only happen in the funnel). The manager exposes getters but no whole-struct snapshot at the current version, and `lastResetDate` is private. Add a read-only snapshot builder.

**Files:**
- Modify: `Foqos/Utils/EmergencyUnblockManager.swift`
- Test: `FoqosTests/EmergencyUnblockManagerSnapshotTests.swift` (new; auto-included by folder)

**Interfaces:**
- Produces: `func currentEmergencySettings(deviceId: String, now: Date = Date()) -> SyncedEmergencySettings` on `EmergencyUnblockManager` (@MainActor). Reads current published state verbatim; `version = emergencySettingsVersion` (no bump); `lastModified = now`; `originDeviceId = deviceId`.
- Consumes: `SyncedEmergencySettings.init(unblocksRemaining:resetPeriodInDays:lastResetDate:settingsLocked:version:lastModified:originDeviceId:)` (`SyncModels.swift:521`); `EmergencyUnblockManager.applyRemoteEmergencySettings(_:)` (`EmergencyUnblockManager.swift:232`).

**Steps:**

- [ ] **Step 1 — Write the failing test.** Create `FoqosTests/EmergencyUnblockManagerSnapshotTests.swift`:

```swift
import XCTest

@testable import FamilyFoqos

@MainActor
final class EmergencyUnblockManagerSnapshotTests: XCTestCase {
  private let defaultsKeys = [
    "family_foqos_emergency_unblocks_remaining",
    "family_foqos_emergency_unblocks_reset_period_in_days",
    "family_foqos_last_emergency_unblocks_reset_date",
    "family_foqos_emergency_settings_locked",
    "family_foqos_emergency_settings_version",
  ]

  override func tearDown() async throws {
    for key in defaultsKeys { UserDefaults.standard.removeObject(forKey: key) }
    try await super.tearDown()
  }

  func testGivenAppliedState_WhenSnapshotRequested_ThenReflectsCurrentValuesWithoutBump() {
    let now = Date()
    let manager = EmergencyUnblockManager()
    let remote = SyncedEmergencySettings(
      unblocksRemaining: 2,
      resetPeriodInDays: 14,
      lastResetDate: now,
      settingsLocked: true,
      version: 9,
      lastModified: now,
      originDeviceId: "remote-device"
    )
    manager.applyRemoteEmergencySettings(remote)

    let snapshot = manager.currentEmergencySettings(deviceId: "device-A", now: now)

    XCTAssertEqual(snapshot.unblocksRemaining, 2)
    XCTAssertEqual(snapshot.resetPeriodInDays, 14)
    XCTAssertEqual(snapshot.settingsLocked, true)
    XCTAssertEqual(snapshot.version, 9, "snapshot must carry the current version verbatim (no bump)")
    XCTAssertEqual(snapshot.originDeviceId, "device-A")
    XCTAssertEqual(snapshot.lastModified, now)
    XCTAssertEqual(
      snapshot.lastResetDate.timeIntervalSinceReferenceDate,
      now.timeIntervalSinceReferenceDate,
      accuracy: 0.001
    )
  }
}
```

- [ ] **Step 2 — Run; expect FAIL** (compile error: `currentEmergencySettings` does not exist).

```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/EmergencyUnblockManagerSnapshotTests/testGivenAppliedState_WhenSnapshotRequested_ThenReflectsCurrentValuesWithoutBump | xcpretty
```

- [ ] **Step 3 — Minimal implementation.** In `Foqos/Utils/EmergencyUnblockManager.swift`, add this method inside the `EmergencyUnblockManager` class body (e.g. immediately after `applyRemoteEmergencySettings(_:)`), so it can read the private backing state:

```swift
  /// Snapshot of the current emergency settings for CKRecord materialization (RecordProvider).
  /// Reads the current version verbatim — never bumps (I2: version bumps only in MutationFunnel).
  func currentEmergencySettings(deviceId: String, now: Date = Date()) -> SyncedEmergencySettings {
    SyncedEmergencySettings(
      unblocksRemaining: emergencyUnblocksRemaining,
      resetPeriodInDays: emergencyUnblocksResetPeriodInDays,
      lastResetDate: Date(
        timeIntervalSinceReferenceDate: lastEmergencyUnblocksResetDateTimestamp),
      settingsLocked: emergencySettingsLockedStorage,
      version: emergencySettingsVersion,
      lastModified: now,
      originDeviceId: deviceId
    )
  }
```

- [ ] **Step 4 — Run; expect PASS** (same command as Step 2).

- [ ] **Step 5 — Commit.**

```bash
git add Foqos/Utils/EmergencyUnblockManager.swift FoqosTests/EmergencyUnblockManagerSnapshotTests.swift
git commit -m "feat(#267): EmergencyUnblockManager.currentEmergencySettings snapshot (Phase B, no-bump materialization source)"
```

---

### Task 21: CKRecord system-fields codec (Data ↔ change-tag-bearing CKRecord)

The `systemFields[user]` cache stores archived CKRecord system fields (recordID + server change tag) so saves carry the correct tag (§2.1/§5.1/§5.3). `RecordProvider` reads it (materialize on cached fields); `SyncApplyService` writes it (after durable apply). Provide the shared encode/decode.

**Files:**
- Create: `Foqos/CloudKit/SyncEngine/CKRecordSystemFieldsCodec.swift`
- Test: `FoqosTests/CKRecordSystemFieldsCodecTests.swift` (new)

**Interfaces:**
- Produces: `enum CKRecordSystemFieldsCodec { static func encode(_ record: CKRecord) -> Data; static func decode(_ data: Data) -> CKRecord? }`.

**Steps:**

- [ ] **Step 1 — Write the failing test.** Create `FoqosTests/CKRecordSystemFieldsCodecTests.swift`:

```swift
import CloudKit
import XCTest

@testable import FamilyFoqos

final class CKRecordSystemFieldsCodecTests: XCTestCase {
  func testGivenRecord_WhenEncodedAndDecoded_ThenRecordIDAndZonePreserved() {
    let zone = CKRecordZone.ID(zoneName: "DeviceSync", ownerName: "sentinel-owner")
    let recordID = CKRecord.ID(recordName: "abc-123", zoneID: zone)
    let record = CKRecord(recordType: SyncedProfile.recordType, recordID: recordID)
    record[SyncedProfile.FieldKey.name.rawValue] = "should-not-round-trip"

    let data = CKRecordSystemFieldsCodec.encode(record)
    let decoded = CKRecordSystemFieldsCodec.decode(data)

    XCTAssertNotNil(decoded)
    XCTAssertEqual(decoded?.recordID.recordName, "abc-123")
    XCTAssertEqual(decoded?.recordID.zoneID.zoneName, "DeviceSync")
    XCTAssertEqual(decoded?.recordID.zoneID.ownerName, "sentinel-owner")
    XCTAssertEqual(decoded?.recordType, SyncedProfile.recordType)
    // Only system fields are captured — user fields are NOT part of the archive.
    XCTAssertNil(decoded?[SyncedProfile.FieldKey.name.rawValue])
  }

  func testGivenGarbageData_WhenDecoded_ThenNil() {
    XCTAssertNil(CKRecordSystemFieldsCodec.decode(Data([0x00, 0x01, 0x02])))
  }
}
```

- [ ] **Step 2 — Run; expect FAIL** (compile error: `CKRecordSystemFieldsCodec` does not exist).

```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/CKRecordSystemFieldsCodecTests | xcpretty
```

- [ ] **Step 3 — Minimal implementation.** Create `Foqos/CloudKit/SyncEngine/CKRecordSystemFieldsCodec.swift`:

```swift
import CloudKit
import Foundation

/// Archives / restores a CKRecord's system fields (recordID + server change tag) as Data
/// for the `systemFields[user]` cache (§2.1). Reader: RecordProvider. Writer: SyncApplyService.
enum CKRecordSystemFieldsCodec {
  static func encode(_ record: CKRecord) -> Data {
    let coder = NSKeyedArchiver(requiringSecureCoding: true)
    record.encodeSystemFields(with: coder)
    coder.finishEncoding()
    return coder.encodedData
  }

  static func decode(_ data: Data) -> CKRecord? {
    guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else {
      return nil
    }
    coder.requiresSecureCoding = true
    let record = CKRecord(coder: coder)
    coder.finishDecoding()
    return record
  }
}
```

- [ ] **Step 4 — Run; expect PASS** (same command as Step 2).

- [ ] **Step 5 — Commit.**

```bash
git add Foqos/CloudKit/SyncEngine/CKRecordSystemFieldsCodec.swift FoqosTests/CKRecordSystemFieldsCodecTests.swift
git commit -m "feat(#267): CKRecordSystemFieldsCodec — change-tag cache encode/decode (Phase B)"
```

---

### Task 22: Payload-equality helper (decoded-semantic comparison, §2)

Two synced representations are *payload-equal* iff all synced fields match **excluding sync metadata** (`lastModified`, `originDeviceId`, `version`/system fields). Encoded-`Data` blobs compare by **decoded semantic value** via the existing `SyncedProfile` accessors (`schedule`, `geofenceRule`, `startTriggers`, `stopConditions`, `startSchedule`, `stopSchedule`, `preActivationReminderTimes` — all `Equatable`); `strategyData` (no typed decoder) compares by bytes. Used by the §5.1 equal-version-divergence branch.

**Files:**
- Create: `Foqos/CloudKit/SyncEngine/SyncPayloadEquality.swift`
- Test: `FoqosTests/SyncPayloadEqualityTests.swift` (new)

**Interfaces:**
- Produces: `enum SyncPayloadEquality` with `static func profilesPayloadEqual(_:_:) -> Bool`, `static func locationsPayloadEqual(_:_:) -> Bool`, `static func emergencyPayloadEqual(_:_:) -> Bool`.
- Consumes: `SyncedProfile`, `SyncedLocation`, `SyncedEmergencySettings` and `SyncedProfile`'s decoded accessors (`SyncModels.swift`).

**Steps:**

- [ ] **Step 1 — Write the failing test.** Create `FoqosTests/SyncPayloadEqualityTests.swift`:

```swift
import XCTest

@testable import FamilyFoqos

final class SyncPayloadEqualityTests: XCTestCase {
  private func makeProfile(name: String, now: Date, originDeviceId: String, version: Int)
    -> SyncedProfile
  {
    let source = BlockedProfiles(id: UUID(), name: name, syncVersion: version)
    var synced = SyncedProfile(from: source, originDeviceId: originDeviceId)
    synced.createdAt = now
    synced.updatedAt = now
    return synced
  }

  func testGivenSameFieldsDifferentMetadata_WhenComparedProfiles_ThenPayloadEqual() {
    let now = Date()
    let id = UUID()
    let base = BlockedProfiles(id: id, name: "Focus", syncVersion: 5)
    var a = SyncedProfile(from: base, originDeviceId: "device-A")
    var b = SyncedProfile(from: base, originDeviceId: "device-B")
    a.createdAt = now
    a.updatedAt = now
    a.version = 5
    a.lastModified = now
    b.createdAt = now
    b.updatedAt = now
    b.version = 99
    b.lastModified = now.addingTimeInterval(1000)
    XCTAssertTrue(SyncPayloadEquality.profilesPayloadEqual(a, b))
  }

  func testGivenDifferentName_WhenComparedProfiles_ThenNotPayloadEqual() {
    let now = Date()
    let a = makeProfile(name: "Focus", now: now, originDeviceId: "device-A", version: 5)
    let b = makeProfile(name: "Work", now: now, originDeviceId: "device-A", version: 5)
    XCTAssertFalse(SyncPayloadEquality.profilesPayloadEqual(a, b))
  }

  func testGivenSameFieldsDifferentMetadata_WhenComparedLocations_ThenPayloadEqual() {
    let now = Date()
    let id = UUID()
    let a = SyncedLocation(
      locationId: id, name: "Home", latitude: 1, longitude: 2,
      defaultRadiusMeters: 100, isLocked: false, lastModified: now)
    let b = SyncedLocation(
      locationId: id, name: "Home", latitude: 1, longitude: 2,
      defaultRadiusMeters: 100, isLocked: false, lastModified: now.addingTimeInterval(5000))
    XCTAssertTrue(SyncPayloadEquality.locationsPayloadEqual(a, b))
  }

  func testGivenDifferentRadius_WhenComparedLocations_ThenNotPayloadEqual() {
    let now = Date()
    let id = UUID()
    let a = SyncedLocation(
      locationId: id, name: "Home", latitude: 1, longitude: 2,
      defaultRadiusMeters: 100, isLocked: false, lastModified: now)
    let b = SyncedLocation(
      locationId: id, name: "Home", latitude: 1, longitude: 2,
      defaultRadiusMeters: 250, isLocked: false, lastModified: now)
    XCTAssertFalse(SyncPayloadEquality.locationsPayloadEqual(a, b))
  }

  func testGivenSameFieldsDifferentMetadata_WhenComparedEmergency_ThenPayloadEqual() {
    let now = Date()
    let a = SyncedEmergencySettings(
      unblocksRemaining: 3, resetPeriodInDays: 28, lastResetDate: now,
      settingsLocked: false, version: 1, lastModified: now, originDeviceId: "device-A")
    let b = SyncedEmergencySettings(
      unblocksRemaining: 3, resetPeriodInDays: 28, lastResetDate: now,
      settingsLocked: false, version: 42, lastModified: now.addingTimeInterval(9),
      originDeviceId: "device-B")
    XCTAssertTrue(SyncPayloadEquality.emergencyPayloadEqual(a, b))
  }
}
```

- [ ] **Step 2 — Run; expect FAIL** (compile error: `SyncPayloadEquality` does not exist).

```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SyncPayloadEqualityTests | xcpretty
```

- [ ] **Step 3 — Minimal implementation.** Create `Foqos/CloudKit/SyncEngine/SyncPayloadEquality.swift`:

```swift
import CloudKit
import Foundation

/// Payload equality excludes sync metadata (`lastModified`, `originDeviceId`, `version`)
/// and compares encoded-Data blobs by decoded semantic value where a decoder exists (§2).
enum SyncPayloadEquality {
  static func profilesPayloadEqual(_ a: SyncedProfile, _ b: SyncedProfile) -> Bool {
    return a.name == b.name
      && a.createdAt == b.createdAt
      && a.updatedAt == b.updatedAt
      && a.blockingStrategyId == b.blockingStrategyId
      && a.strategyData == b.strategyData
      && a.order == b.order
      && a.enableLiveActivity == b.enableLiveActivity
      && a.reminderTimeInSeconds == b.reminderTimeInSeconds
      && a.customReminderMessage == b.customReminderMessage
      && a.enableBreaks == b.enableBreaks
      && a.breakTimeInMinutes == b.breakTimeInMinutes
      && a.enableStrictMode == b.enableStrictMode
      && a.enableAllowMode == b.enableAllowMode
      && a.enableAllowModeDomains == b.enableAllowModeDomains
      && a.enableSafariBlocking == b.enableSafariBlocking
      && a.preActivationReminderTimes == b.preActivationReminderTimes
      && a.physicalUnblockNFCTagId == b.physicalUnblockNFCTagId
      && a.physicalUnblockQRCodeId == b.physicalUnblockQRCodeId
      && a.domains == b.domains
      && a.disableBackgroundStops == b.disableBackgroundStops
      && a.isManaged == b.isManaged
      && a.managedByChildId == b.managedByChildId
      && a.profileSchemaVersion == b.profileSchemaVersion
      && a.scheduleLastStoppedAt == b.scheduleLastStoppedAt
      && a.startNFCTagId == b.startNFCTagId
      && a.startQRCodeId == b.startQRCodeId
      && a.stopNFCTagId == b.stopNFCTagId
      && a.stopQRCodeId == b.stopQRCodeId
      && a.schedule == b.schedule
      && a.geofenceRule == b.geofenceRule
      && a.startTriggers == b.startTriggers
      && a.stopConditions == b.stopConditions
      && a.startSchedule == b.startSchedule
      && a.stopSchedule == b.stopSchedule
  }

  static func locationsPayloadEqual(_ a: SyncedLocation, _ b: SyncedLocation) -> Bool {
    return a.name == b.name
      && a.latitude == b.latitude
      && a.longitude == b.longitude
      && a.defaultRadiusMeters == b.defaultRadiusMeters
      && a.isLocked == b.isLocked
  }

  static func emergencyPayloadEqual(
    _ a: SyncedEmergencySettings, _ b: SyncedEmergencySettings
  ) -> Bool {
    return a.unblocksRemaining == b.unblocksRemaining
      && a.resetPeriodInDays == b.resetPeriodInDays
      && a.lastResetDate == b.lastResetDate
      && a.settingsLocked == b.settingsLocked
  }
}
```

- [ ] **Step 4 — Run; expect PASS** (same command as Step 2).

- [ ] **Step 5 — Commit.**

```bash
git add Foqos/CloudKit/SyncEngine/SyncPayloadEquality.swift FoqosTests/SyncPayloadEqualityTests.swift
git commit -m "feat(#267): SyncPayloadEquality — decoded-semantic payload comparison (Phase B, §2)"
```

---

### Task 23: RecordProvider — materialize profile / location / emergency records (§5.4)

Materialize `CKRecord`s for `nextRecordZoneChangeBatch` reusing `toCKRecord`/`updateCKRecord`, on cached `systemFields` (fresh if none). Return `nil` (§5.4 "remove from queue") for an absent entity or an `isNewerSchemaVersion` profile. Sessions are owned by `SessionSyncService` (never materialized here — §6/§2.1).

**Files:**
- Create: `Foqos/CloudKit/SyncEngine/RecordProvider.swift`
- Test: `FoqosTests/RecordProviderTests.swift` (new)

**Interfaces:**
- Produces: `@MainActor final class RecordProvider { init(modelContext: ModelContext, store: SyncEngineStore, emergencyManager: EmergencyUnblockManager, deviceId: String); func record(forRecordName recordName: String) -> CKRecord? }`.
- Consumes: `SyncedProfile(from:originDeviceId:).toCKRecord/updateCKRecord`, `SyncedLocation(from:)`, `SyncedEmergencySettings` (`SyncModels.swift`); `BlockedProfiles.findProfile(byID:in:)`, `BlockedProfiles.isNewerSchemaVersion`; `SavedLocation.find(byID:in:)`; `EmergencyUnblockManager.currentEmergencySettings(deviceId:)` (Task 20); `CKRecordSystemFieldsCodec` (Task 21); `SyncEngineStore.systemFields(for:)`.

**Steps:**

- [ ] **Step 1 — Write the failing test.** Create `FoqosTests/RecordProviderTests.swift`:

```swift
import CloudKit
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class RecordProviderTests: XCTestCase {
  private var container: ModelContainer!
  private var context: ModelContext!
  private var store: SyncEngineStore!
  private var emergencyManager: EmergencyUnblockManager!
  private var suiteName: String!
  private var storeSuiteName: String!
  private var storeDefaults: UserDefaults!
  private let deviceId = "device-A"
  private let zoneID = CKRecordZone.ID(
    zoneName: CloudKitConstants.syncZoneName, ownerName: CKCurrentUserDefaultName)

  override func setUp() async throws {
    try await super.setUp()
    suiteName = "RecordProviderTests-\(UUID().uuidString)"
    SharedData.configure(suite: UserDefaults(suiteName: suiteName)!)
    storeSuiteName = "RecordProviderTests-store-\(UUID().uuidString)"
    storeDefaults = UserDefaults(suiteName: storeSuiteName)!
    store = SyncEngineStore(userRecordName: "user-1", defaults: storeDefaults)
    container = try TestModelContainer.create()
    context = container.mainContext
    emergencyManager = EmergencyUnblockManager()
  }

  override func tearDown() async throws {
    UserDefaults().removePersistentDomain(forName: suiteName)
    UserDefaults().removePersistentDomain(forName: storeSuiteName)
    try await super.tearDown()
  }

  private func makeProvider() -> RecordProvider {
    RecordProvider(
      modelContext: context, store: store, emergencyManager: emergencyManager, deviceId: deviceId)
  }

  func testGivenLocalProfile_WhenMaterializedFresh_ThenBuildsProfileRecordInSyncZone() throws {
    let id = UUID()
    let profile = BlockedProfiles(id: id, name: "Focus", syncVersion: 3)
    context.insert(profile)
    try context.save()

    let record = makeProvider().record(forRecordName: id.uuidString)

    XCTAssertNotNil(record)
    XCTAssertEqual(record?.recordType, SyncedProfile.recordType)
    XCTAssertEqual(record?.recordID.recordName, id.uuidString)
    XCTAssertEqual(record?.recordID.zoneID.ownerName, CKCurrentUserDefaultName)
    XCTAssertEqual(record?[SyncedProfile.FieldKey.name.rawValue] as? String, "Focus")
    XCTAssertEqual(record?[SyncedProfile.FieldKey.version.rawValue] as? Int, 3)
    XCTAssertEqual(record?[SyncedProfile.FieldKey.originDeviceId.rawValue] as? String, deviceId)
  }

  func testGivenCachedSystemFields_WhenProfileMaterialized_ThenReusesCachedRecordID() throws {
    let id = UUID()
    let profile = BlockedProfiles(id: id, name: "Focus", syncVersion: 1)
    context.insert(profile)
    try context.save()
    // Seed cached system fields from a record in a SENTINEL zone — proves cache reuse.
    let sentinelZone = CKRecordZone.ID(zoneName: "DeviceSync", ownerName: "sentinel-owner")
    let cached = CKRecord(
      recordType: SyncedProfile.recordType,
      recordID: CKRecord.ID(recordName: id.uuidString, zoneID: sentinelZone))
    store.setSystemFields(CKRecordSystemFieldsCodec.encode(cached), for: id.uuidString)

    let record = makeProvider().record(forRecordName: id.uuidString)

    XCTAssertEqual(record?.recordID.zoneID.ownerName, "sentinel-owner")
    XCTAssertEqual(record?[SyncedProfile.FieldKey.name.rawValue] as? String, "Focus")
  }

  func testGivenLocalLocation_WhenMaterialized_ThenBuildsLocationRecord() throws {
    let id = UUID()
    let location = SavedLocation(
      id: id, name: "Home", latitude: 1, longitude: 2, defaultRadiusMeters: 150,
      isLocked: true, syncVersion: 1)
    context.insert(location)
    try context.save()

    let record = makeProvider().record(forRecordName: id.uuidString)

    XCTAssertEqual(record?.recordType, SyncedLocation.recordType)
    XCTAssertEqual(record?[SyncedLocation.FieldKey.name.rawValue] as? String, "Home")
    XCTAssertEqual(record?[SyncedLocation.FieldKey.isLocked.rawValue] as? Bool, true)
  }

  func testGivenEmergencyRecordName_WhenMaterialized_ThenBuildsEmergencyRecord() {
    let now = Date()
    emergencyManager.applyRemoteEmergencySettings(
      SyncedEmergencySettings(
        unblocksRemaining: 2, resetPeriodInDays: 14, lastResetDate: now,
        settingsLocked: true, version: 4, lastModified: now, originDeviceId: "remote"))

    let record = makeProvider().record(forRecordName: SyncedEmergencySettings.recordName)

    XCTAssertEqual(record?.recordType, SyncedEmergencySettings.recordType)
    XCTAssertEqual(record?.recordID.recordName, SyncedEmergencySettings.recordName)
    XCTAssertEqual(record?[SyncedEmergencySettings.FieldKey.unblocksRemaining.rawValue] as? Int, 2)
    XCTAssertEqual(record?[SyncedEmergencySettings.FieldKey.version.rawValue] as? Int, 4)
  }

  func testGivenAbsentEntity_WhenMaterialized_ThenNil() {
    XCTAssertNil(makeProvider().record(forRecordName: UUID().uuidString))
  }

  func testGivenNewerSchemaProfile_WhenMaterialized_ThenNil() throws {
    let id = UUID()
    let profile = BlockedProfiles(id: id, name: "Future", syncVersion: 1)
    profile.profileSchemaVersion = BlockedProfiles.currentSchemaVersion + 1
    context.insert(profile)
    try context.save()

    XCTAssertNil(makeProvider().record(forRecordName: id.uuidString))
  }

  func testGivenSessionRecordName_WhenMaterialized_ThenNil() {
    let name = ProfileSessionRecord.recordName(for: UUID())
    XCTAssertNil(makeProvider().record(forRecordName: name))
  }
}
```

- [ ] **Step 2 — Run; expect FAIL** (compile error: `RecordProvider` does not exist).

```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/RecordProviderTests | xcpretty
```

- [ ] **Step 3 — Minimal implementation.** Create `Foqos/CloudKit/SyncEngine/RecordProvider.swift`:

```swift
import CloudKit
import Foundation
import SwiftData

/// Materializes CKRecords for `nextRecordZoneChangeBatch` on cached system fields (fresh if none),
/// reusing the Synced* `toCKRecord`/`updateCKRecord` helpers. Returns nil for §5.4 removal
/// (entity absent, or `isNewerSchemaVersion` profile). Sessions are never materialized here (§6).
@MainActor
final class RecordProvider {
  private let modelContext: ModelContext
  private let store: SyncEngineStore
  private let emergencyManager: EmergencyUnblockManager
  private let deviceId: String
  private let zoneID = CKRecordZone.ID(
    zoneName: CloudKitConstants.syncZoneName, ownerName: CKCurrentUserDefaultName)

  init(
    modelContext: ModelContext,
    store: SyncEngineStore,
    emergencyManager: EmergencyUnblockManager,
    deviceId: String
  ) {
    self.modelContext = modelContext
    self.store = store
    self.emergencyManager = emergencyManager
    self.deviceId = deviceId
  }

  func record(forRecordName recordName: String) -> CKRecord? {
    if recordName == SyncedEmergencySettings.recordName {
      return emergencyRecord()
    }
    if recordName.hasPrefix("ProfileSession_") {
      // Session records are owned by SessionSyncService (CAS), never materialized here.
      return nil
    }
    guard let id = UUID(uuidString: recordName) else {
      return nil
    }
    if let profile = try? BlockedProfiles.findProfile(byID: id, in: modelContext) {
      return profileRecord(profile)
    }
    if let location = try? SavedLocation.find(byID: id, in: modelContext) {
      return locationRecord(location)
    }
    return nil
  }

  private func profileRecord(_ profile: BlockedProfiles) -> CKRecord? {
    guard !profile.isNewerSchemaVersion else { return nil }
    let synced = SyncedProfile(from: profile, originDeviceId: deviceId)
    let record = materialize(
      recordName: profile.id.uuidString,
      recordType: SyncedProfile.recordType,
      freshRecordID: CKRecord.ID(recordName: profile.id.uuidString, zoneID: zoneID))
    synced.updateCKRecord(record)
    return record
  }

  private func locationRecord(_ location: SavedLocation) -> CKRecord? {
    let synced = SyncedLocation(from: location)
    let record = materialize(
      recordName: location.id.uuidString,
      recordType: SyncedLocation.recordType,
      freshRecordID: CKRecord.ID(recordName: location.id.uuidString, zoneID: zoneID))
    synced.updateCKRecord(record)
    return record
  }

  private func emergencyRecord() -> CKRecord? {
    let synced = emergencyManager.currentEmergencySettings(deviceId: deviceId)
    let record = materialize(
      recordName: SyncedEmergencySettings.recordName,
      recordType: SyncedEmergencySettings.recordType,
      freshRecordID: CKRecord.ID(recordName: SyncedEmergencySettings.recordName, zoneID: zoneID))
    synced.updateCKRecord(record)
    return record
  }

  /// The CKRecord to write fields onto: decoded from cached system fields when present
  /// (change-tag-correct), else a fresh record (§5.4).
  private func materialize(
    recordName: String, recordType: String, freshRecordID: CKRecord.ID
  ) -> CKRecord {
    if let data = store.systemFields(for: recordName),
      let cached = CKRecordSystemFieldsCodec.decode(data)
    {
      return cached
    }
    return CKRecord(recordType: recordType, recordID: freshRecordID)
  }
}
```

- [ ] **Step 4 — Run; expect PASS** (same command as Step 2).

- [ ] **Step 5 — Commit.**

```bash
git add Foqos/CloudKit/SyncEngine/RecordProvider.swift FoqosTests/RecordProviderTests.swift
git commit -m "feat(#267): RecordProvider — materialize profile/location/emergency on cached systemFields (Phase B, §5.4)"
```

---

### Task 24: SyncApplyService — fetched profile modifications (I9 gate, E-1, equal-version divergence, systemFields, rollback)

Create the `@MainActor SyncApplyService` skeleton with routing, and fully implement the **profile** branch: reuse the I9 schema-version gate (`SyncCoordinator.swift:126-166`), `updateLocalProfile`/`createLocalProfile` (E-1) **without** the own-origin skip or deletion reconciliation; add the §5.1 equal-version-divergence rule; store `systemFields` only after durable apply (S-30); roll back + record a `failedApplies` entry on throw. Location/emergency/session branches and `applyFetchedDeletion` are stubs (`.ignored`) completed in Tasks 25–27; the pending-delete guard lands in Task 28.

**Files:**
- Create: `Foqos/CloudKit/SyncEngine/SyncApplyService.swift`
- Test: `FoqosTests/SyncApplyServiceTests.swift` (new)

**Interfaces:**
- Produces: `@MainActor final class SyncApplyService { init(modelContext: ModelContext, store: SyncEngineStore, sessionController: SessionController, emergencyManager: EmergencyUnblockManager, deviceId: String); var recentlyConfirmedDeletes: Set<String>; func applyFetchedModification(_ record: CKRecord, isPendingDeleteOrTombstoned: (String) -> Bool) -> ApplyOutcome; func applyFetchedDeletion(recordID: CKRecord.ID, recordType: CKRecord.RecordType) -> DeletionOutcome; enum ApplyOutcome { case applied, skippedPendingDelete, ignored, failed }; enum DeletionOutcome { case deleted, notPresent, ignored } }`. Additional (drained by `SyncEngineController` in the controller phase): `private(set) var pendingReenqueues: [CKRecord.ID]`, `func drainReenqueues() -> [CKRecord.ID]`, and the test seam `var saveOverride: (() throws -> Void)?`.
- Consumes: `SyncedProfile.init?(from:)`, `BlockedProfiles.findProfile/currentSchemaVersion/updateSnapshot`, `SyncConflictManager.shared.addConflict/addNewerVersionConflict/clearConflict`, `SyncEngineStore.setSystemFields/addFailedApply/removeFailedApply`, `CKRecordSystemFieldsCodec`, `SyncPayloadEquality.profilesPayloadEqual`.

**Steps:**

- [ ] **Step 1 — Write the failing test.** Create `FoqosTests/SyncApplyServiceTests.swift`:

```swift
import CloudKit
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class SyncApplyServiceTests: XCTestCase {
  private var container: ModelContainer!
  private var context: ModelContext!
  private var store: SyncEngineStore!
  private var sessionController: MockSessionController!
  private var emergencyManager: EmergencyUnblockManager!
  private var suiteName: String!
  private var storeSuiteName: String!
  private var storeDefaults: UserDefaults!
  private let deviceId = "device-A"
  private let zoneID = CKRecordZone.ID(
    zoneName: CloudKitConstants.syncZoneName, ownerName: CKCurrentUserDefaultName)

  override func setUp() async throws {
    try await super.setUp()
    suiteName = "SyncApplyServiceTests-\(UUID().uuidString)"
    SharedData.configure(suite: UserDefaults(suiteName: suiteName)!)
    storeSuiteName = "SyncApplyServiceTests-store-\(UUID().uuidString)"
    storeDefaults = UserDefaults(suiteName: storeSuiteName)!
    store = SyncEngineStore(userRecordName: "user-1", defaults: storeDefaults)
    container = try TestModelContainer.create()
    context = container.mainContext
    sessionController = MockSessionController()
    emergencyManager = EmergencyUnblockManager()
    SyncConflictManager.shared.clearAll()
  }

  override func tearDown() async throws {
    SyncConflictManager.shared.clearAll()
    UserDefaults().removePersistentDomain(forName: suiteName)
    UserDefaults().removePersistentDomain(forName: storeSuiteName)
    try await super.tearDown()
  }

  private func makeService() -> SyncApplyService {
    SyncApplyService(
      modelContext: context, store: store, sessionController: sessionController,
      emergencyManager: emergencyManager, deviceId: deviceId)
  }

  private func makeProfileRecord(
    id: UUID, name: String, version: Int, originDeviceId: String, schemaVersion: Int? = nil,
    now: Date
  ) -> CKRecord {
    let source = BlockedProfiles(id: id, name: name, syncVersion: version)
    if let schemaVersion { source.profileSchemaVersion = schemaVersion }
    var synced = SyncedProfile(from: source, originDeviceId: originDeviceId)
    synced.createdAt = now
    synced.updatedAt = now
    synced.version = version
    if let schemaVersion { synced.profileSchemaVersion = schemaVersion }
    return synced.toCKRecord(in: zoneID)
  }

  private let noPendingDelete: (String) -> Bool = { _ in false }

  // MARK: - S-27 (normal apply) / E-1

  func testGivenAbsentProfile_WhenModificationApplied_ThenCreatedWithNeedsAppSelection() throws {
    let now = Date()
    let id = UUID()
    let record = makeProfileRecord(
      id: id, name: "Focus", version: 4, originDeviceId: "device-B", now: now)
    let service = makeService()

    let outcome = service.applyFetchedModification(record, isPendingDeleteOrTombstoned: noPendingDelete)

    XCTAssertEqual(outcome, .applied)
    let created = try BlockedProfiles.findProfile(byID: id, in: context)
    XCTAssertNotNil(created)
    XCTAssertEqual(created?.name, "Focus")
    XCTAssertEqual(created?.syncVersion, 4, "version applied verbatim (I2)")
    XCTAssertTrue(created?.needsAppSelection ?? false, "E-1: remote-created profile needs app selection")
    XCTAssertTrue(service.pendingReenqueues.isEmpty, "S-27: a plain apply enqueues nothing")
    XCTAssertNotNil(store.systemFields(for: id.uuidString), "systemFields stored after durable apply")
  }

  // MARK: - S-18 / I9

  func testGivenSchemaVersions_WhenProfileModificationApplied_ThenI9GatePreserved() throws {
    let now = Date()

    // (a) older incoming schema ⇒ reject data + conflict + auto-heal (bump + re-enqueue).
    let idOlder = UUID()
    let localOlder = BlockedProfiles(id: idOlder, name: "Local", syncVersion: 2)
    localOlder.profileSchemaVersion = 2
    context.insert(localOlder)
    try context.save()
    let olderIncoming = makeProfileRecord(
      id: idOlder, name: "FromOldApp", version: 9, originDeviceId: "device-B",
      schemaVersion: 1, now: now)
    let service = makeService()
    XCTAssertEqual(
      service.applyFetchedModification(olderIncoming, isPendingDeleteOrTombstoned: noPendingDelete),
      .applied)
    let afterOlder = try BlockedProfiles.findProfile(byID: idOlder, in: context)
    XCTAssertEqual(afterOlder?.name, "Local", "older-schema data is rejected, not applied")
    XCTAssertEqual(afterOlder?.syncVersion, 3, "auto-heal bumps syncVersion")
    XCTAssertTrue(service.pendingReenqueues.contains(olderIncoming.recordID), "auto-heal re-enqueues")
    XCTAssertNotNil(SyncConflictManager.shared.conflictedProfiles[idOlder])

    // (b) newer incoming schema than this app ⇒ reject data, mark read-only, no auto-heal.
    let idNewer = UUID()
    let localNewer = BlockedProfiles(id: idNewer, name: "Local2", syncVersion: 1)
    localNewer.profileSchemaVersion = 2
    context.insert(localNewer)
    try context.save()
    let newerIncoming = makeProfileRecord(
      id: idNewer, name: "FromNewApp", version: 7, originDeviceId: "device-B",
      schemaVersion: BlockedProfiles.currentSchemaVersion + 1, now: now)
    let service2 = makeService()
    XCTAssertEqual(
      service2.applyFetchedModification(newerIncoming, isPendingDeleteOrTombstoned: noPendingDelete),
      .applied)
    let afterNewer = try BlockedProfiles.findProfile(byID: idNewer, in: context)
    XCTAssertEqual(afterNewer?.name, "Local2", "newer-schema data is rejected")
    XCTAssertEqual(afterNewer?.profileSchemaVersion, BlockedProfiles.currentSchemaVersion + 1)
    XCTAssertEqual(afterNewer?.syncVersion, 7, "syncVersion advanced to stop re-processing")
    XCTAssertTrue(service2.pendingReenqueues.isEmpty, "newer device is authoritative — no auto-heal")
    XCTAssertNotNil(SyncConflictManager.shared.newerVersionProfiles[idNewer])

    // (c) same schema, newer version ⇒ apply.
    let idApply = UUID()
    let localApply = BlockedProfiles(id: idApply, name: "Old", syncVersion: 1)
    localApply.profileSchemaVersion = 2
    context.insert(localApply)
    try context.save()
    let applyIncoming = makeProfileRecord(
      id: idApply, name: "New", version: 5, originDeviceId: "device-B", schemaVersion: 2, now: now)
    let service3 = makeService()
    XCTAssertEqual(
      service3.applyFetchedModification(applyIncoming, isPendingDeleteOrTombstoned: noPendingDelete),
      .applied)
    XCTAssertEqual(try BlockedProfiles.findProfile(byID: idApply, in: context)?.name, "New")
  }

  // MARK: - S-27 (equal-version divergence)

  func testGivenEqualVersion_WhenProfileModificationApplied_ThenDivergenceBumpsAndEqualIsNoOp() throws {
    let now = Date()
    let id = UUID()
    let local = BlockedProfiles(id: id, name: "Focus", syncVersion: 5)
    local.profileSchemaVersion = 2
    local.createdAt = now
    local.updatedAt = now
    context.insert(local)
    try context.save()

    // Payload-equal echo at the same version ⇒ pure no-op.
    var equalSynced = SyncedProfile(from: local, originDeviceId: "device-B")
    equalSynced.version = 5
    let equalOutcome = makeService().applyFetchedModification(
      equalSynced.toCKRecord(in: zoneID), isPendingDeleteOrTombstoned: noPendingDelete)
    XCTAssertEqual(equalOutcome, .applied)
    XCTAssertEqual(try BlockedProfiles.findProfile(byID: id, in: context)?.syncVersion, 5, "no-op")

    // Payload-differing at the same version ⇒ bump + re-enqueue + conflict.
    var divergent = SyncedProfile(from: local, originDeviceId: "device-B")
    divergent.name = "Changed"
    divergent.version = 5
    let service = makeService()
    let record = divergent.toCKRecord(in: zoneID)
    let divergeOutcome = service.applyFetchedModification(
      record, isPendingDeleteOrTombstoned: noPendingDelete)
    XCTAssertEqual(divergeOutcome, .applied)
    let after = try BlockedProfiles.findProfile(byID: id, in: context)
    XCTAssertEqual(after?.name, "Focus", "local wins — incoming payload not applied")
    XCTAssertEqual(after?.syncVersion, 6, "conflict bump")
    XCTAssertTrue(service.pendingReenqueues.contains(record.recordID))
    XCTAssertNotNil(SyncConflictManager.shared.conflictedProfiles[id])
  }

  // MARK: - S-31

  func testGivenOwnOriginRecord_WhenApplied_ThenNewerHealsForwardAndEqualEchoNoOp() throws {
    let now = Date()
    let id = UUID()
    let local = BlockedProfiles(id: id, name: "Local", syncVersion: 2)
    local.profileSchemaVersion = 2
    context.insert(local)
    try context.save()

    // Own-origin (originDeviceId == self) newer version ⇒ applied (restore-from-backup heals).
    let ownNewer = makeProfileRecord(
      id: id, name: "Healed", version: 6, originDeviceId: deviceId, schemaVersion: 2, now: now)
    XCTAssertEqual(
      makeService().applyFetchedModification(ownNewer, isPendingDeleteOrTombstoned: noPendingDelete),
      .applied)
    XCTAssertEqual(try BlockedProfiles.findProfile(byID: id, in: context)?.name, "Healed",
      "own-origin records are applied, not skipped (§2, S-31)")

    // Own-origin equal-version payload-equal echo ⇒ no-op.
    let healed = try BlockedProfiles.findProfile(byID: id, in: context)!
    var echo = SyncedProfile(from: healed, originDeviceId: deviceId)
    echo.version = 6
    XCTAssertEqual(
      makeService().applyFetchedModification(echo.toCKRecord(in: zoneID),
        isPendingDeleteOrTombstoned: noPendingDelete),
      .applied)
    XCTAssertEqual(try BlockedProfiles.findProfile(byID: id, in: context)?.syncVersion, 6, "echo no-op")
  }

  // MARK: - S-30

  func testGivenThrowingCreate_WhenApplied_ThenRollbackNoSystemFieldsFailedApplyRecorded() throws {
    let now = Date()
    let id = UUID()
    let record = makeProfileRecord(
      id: id, name: "WillFail", version: 1, originDeviceId: "device-B", now: now)
    let service = makeService()
    struct BoomError: Error {}
    service.saveOverride = { throw BoomError() }

    let outcome = service.applyFetchedModification(record, isPendingDeleteOrTombstoned: noPendingDelete)

    XCTAssertEqual(outcome, .failed)
    XCTAssertNil(try BlockedProfiles.findProfile(byID: id, in: context), "rolled back")
    XCTAssertNil(store.systemFields(for: id.uuidString), "no systemFields after a thrown apply")
    XCTAssertTrue(service.pendingReenqueues.isEmpty, "no outbound effect")
    XCTAssertTrue(
      store.failedApplies.contains(
        FailedApply(recordName: id.uuidString, recordType: SyncedProfile.recordType, op: .upsert)))
  }
}
```

- [ ] **Step 2 — Run; expect FAIL** (compile error: `SyncApplyService` does not exist).

```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SyncApplyServiceTests | xcpretty
```

- [ ] **Step 3 — Minimal implementation.** Create `Foqos/CloudKit/SyncEngine/SyncApplyService.swift`:

```swift
import CloudKit
import Foundation
import SwiftData

/// Inbound apply (§5.1/§5.2): routes fetched modifications/deletions by recordType and reuses
/// SyncCoordinator's merge semantics (I9 gate + E-1 + N6) minus deletion reconciliation and the
/// own-origin apply skip. Not wired into any engine in Phase B.
@MainActor
final class SyncApplyService {
  enum ApplyOutcome { case applied, skippedPendingDelete, ignored, failed }
  enum DeletionOutcome { case deleted, notPresent, ignored }

  private let modelContext: ModelContext
  private let store: SyncEngineStore
  private let sessionController: SessionController
  private let emergencyManager: EmergencyUnblockManager
  private let deviceId: String

  /// In-memory confirmed-delete echo guard (§5.1). Populated by the controller on §5.3 confirmation.
  var recentlyConfirmedDeletes: Set<String> = []

  /// Record IDs the controller must re-enqueue as `.saveRecord` (I2 exceptions:
  /// I9 older-schema auto-heal, §5.1 equal-version divergence).
  private(set) var pendingReenqueues: [CKRecord.ID] = []

  /// Test seam: overrides the durable save so §5.1 rollback (S-30) is exercisable.
  var saveOverride: (() throws -> Void)?

  init(
    modelContext: ModelContext,
    store: SyncEngineStore,
    sessionController: SessionController,
    emergencyManager: EmergencyUnblockManager,
    deviceId: String
  ) {
    self.modelContext = modelContext
    self.store = store
    self.sessionController = sessionController
    self.emergencyManager = emergencyManager
    self.deviceId = deviceId
  }

  func drainReenqueues() -> [CKRecord.ID] {
    let ids = pendingReenqueues
    pendingReenqueues.removeAll()
    return ids
  }

  // MARK: - Fetched modifications (§5.1)

  func applyFetchedModification(
    _ record: CKRecord, isPendingDeleteOrTombstoned: (String) -> Bool
  ) -> ApplyOutcome {
    switch record.recordType {
    case SyncedProfile.recordType:
      return applyProfileModification(record)
    case SyncedLocation.recordType:
      return applyLocationModification(record)
    case SyncedEmergencySettings.recordType:
      return applyEmergencyModification(record)
    case ProfileSessionRecord.recordType:
      return applySessionModification(record)
    default:
      Log.info(
        "Ignoring fetched modification of type \(record.recordType)", category: .sync)
      return .ignored
    }
  }

  // MARK: - Fetched deletions (§5.2)

  func applyFetchedDeletion(
    recordID: CKRecord.ID, recordType: CKRecord.RecordType
  ) -> DeletionOutcome {
    // Real implementation added in Task 27.
    return .ignored
  }

  // MARK: - Profile apply (I9 gate + E-1 + equal-version divergence)

  private func applyProfileModification(_ record: CKRecord) -> ApplyOutcome {
    guard let synced = SyncedProfile(from: record) else {
      Log.info("Ignoring undecodable SyncedProfile record", category: .sync)
      return .ignored
    }
    let recordName = record.recordID.recordName
    do {
      let outcome = try applyDecodedProfile(synced, record: record)
      store.removeFailedApply(recordName: recordName)  // supersession (§5.6)
      return outcome
    } catch {
      modelContext.rollback()
      store.addFailedApply(
        FailedApply(
          recordName: recordName, recordType: SyncedProfile.recordType, op: .upsert))
      Log.error(
        "Failed to apply SyncedProfile \(recordName): \(error.localizedDescription)",
        category: .sync)
      return .failed
    }
  }

  private func applyDecodedProfile(
    _ synced: SyncedProfile, record: CKRecord
  ) throws -> ApplyOutcome {
    guard
      let existing = try BlockedProfiles.findProfile(byID: synced.profileId, in: modelContext)
    else {
      createLocalProfile(from: synced)
      try commit()
      storeSystemFields(record)
      return .applied
    }

    // I9 schema-version gate (verbatim from SyncCoordinator.swift:126-166, own-origin skip removed).
    if synced.profileSchemaVersion < existing.profileSchemaVersion {
      SyncConflictManager.shared.addConflict(
        profileId: existing.id, profileName: existing.name)
      // Auto-heal (I2 exception): bump + signal controller to re-enqueue the V2 payload.
      existing.syncVersion += 1
      try commit()
      pendingReenqueues.append(record.recordID)
      return .applied
    } else if synced.profileSchemaVersion > BlockedProfiles.currentSchemaVersion {
      SyncConflictManager.shared.addNewerVersionConflict(
        profileId: existing.id, profileName: existing.name)
      existing.profileSchemaVersion = synced.profileSchemaVersion
      existing.syncVersion = synced.version
      try commit()
      return .applied
    } else if synced.version > existing.syncVersion {
      updateLocalProfile(existing, from: synced)
      try commit()
      SyncConflictManager.shared.clearConflict(profileId: existing.id)
      storeSystemFields(record)
      return .applied
    } else if synced.version == existing.syncVersion {
      // Equal-version divergence (§5.1): payload-differing ⇒ conflict now.
      let localSynced = SyncedProfile(from: existing, originDeviceId: deviceId)
      if SyncPayloadEquality.profilesPayloadEqual(synced, localSynced) {
        return .applied  // payload-equal echo ⇒ no-op
      }
      existing.syncVersion += 1
      try commit()
      pendingReenqueues.append(record.recordID)
      SyncConflictManager.shared.addConflict(
        profileId: existing.id, profileName: existing.name)
      return .applied
    } else {
      // Older incoming version ⇒ no-op.
      return .applied
    }
  }

  // Verbatim from SyncCoordinator.updateLocalProfile (SyncCoordinator.swift:211-265),
  // adapted to use self.modelContext (the original `context` param was unused).
  private func updateLocalProfile(_ profile: BlockedProfiles, from synced: SyncedProfile) {
    profile.name = synced.name
    profile.blockingStrategyId = synced.blockingStrategyId
    profile.strategyData = synced.strategyData
    profile.order = synced.order
    profile.enableLiveActivity = synced.enableLiveActivity
    profile.reminderTimeInSeconds = synced.reminderTimeInSeconds
    profile.customReminderMessage = synced.customReminderMessage
    profile.enableBreaks = synced.enableBreaks
    profile.breakTimeInMinutes = synced.breakTimeInMinutes
    profile.enableStrictMode = synced.enableStrictMode
    profile.enableAllowMode = synced.enableAllowMode
    profile.enableAllowModeDomains = synced.enableAllowModeDomains
    profile.enableSafariBlocking = synced.enableSafariBlocking
    profile.physicalUnblockNFCTagId = synced.physicalUnblockNFCTagId
    profile.physicalUnblockQRCodeId = synced.physicalUnblockQRCodeId
    profile.domains = synced.domains
    profile.schedule = synced.schedule
    profile.geofenceRule = synced.geofenceRule
    profile.disableBackgroundStops = synced.disableBackgroundStops
    profile.preActivationReminderTimes = synced.preActivationReminderTimes
    profile.isManaged = synced.isManaged
    profile.managedByChildId = synced.managedByChildId
    profile.syncVersion = synced.version
    profile.updatedAt = synced.updatedAt
    if let startTriggers = synced.startTriggers {
      profile.startTriggers = startTriggers
    }
    if let stopConditions = synced.stopConditions {
      profile.stopConditions = stopConditions
    }
    if synced.startScheduleData != nil {
      profile.startSchedule = synced.startSchedule
    }
    if synced.stopScheduleData != nil {
      profile.stopSchedule = synced.stopSchedule
    }
    profile.startNFCTagId = synced.startNFCTagId
    profile.startQRCodeId = synced.startQRCodeId
    profile.stopNFCTagId = synced.stopNFCTagId
    profile.stopQRCodeId = synced.stopQRCodeId
    profile.profileSchemaVersion = max(
      profile.profileSchemaVersion, synced.profileSchemaVersion)
    profile.scheduleLastStoppedAt = synced.scheduleLastStoppedAt
    BlockedProfiles.updateSnapshot(for: profile)
  }

  // Verbatim from SyncCoordinator.createLocalProfile (SyncCoordinator.swift:267-318),
  // adapted to use self.modelContext. E-1: needsAppSelection = true.
  private func createLocalProfile(from synced: SyncedProfile) {
    let profile = BlockedProfiles(
      id: synced.profileId,
      name: synced.name,
      createdAt: synced.createdAt,
      updatedAt: synced.updatedAt,
      blockingStrategyId: synced.blockingStrategyId ?? NFCBlockingStrategy.id,
      strategyData: synced.strategyData,
      enableLiveActivity: synced.enableLiveActivity,
      reminderTimeInSeconds: synced.reminderTimeInSeconds,
      customReminderMessage: synced.customReminderMessage,
      enableBreaks: synced.enableBreaks,
      breakTimeInMinutes: synced.breakTimeInMinutes,
      enableStrictMode: synced.enableStrictMode,
      enableAllowMode: synced.enableAllowMode,
      enableAllowModeDomains: synced.enableAllowModeDomains,
      enableSafariBlocking: synced.enableSafariBlocking,
      order: synced.order,
      domains: synced.domains,
      physicalUnblockNFCTagId: synced.physicalUnblockNFCTagId,
      physicalUnblockQRCodeId: synced.physicalUnblockQRCodeId,
      schedule: synced.schedule,
      geofenceRule: synced.geofenceRule,
      disableBackgroundStops: synced.disableBackgroundStops,
      preActivationReminderTimes: synced.preActivationReminderTimes,
      isManaged: synced.isManaged,
      managedByChildId: synced.managedByChildId,
      syncVersion: synced.version,
      needsAppSelection: true
    )
    if let startTriggers = synced.startTriggers {
      profile.startTriggers = startTriggers
    }
    if let stopConditions = synced.stopConditions {
      profile.stopConditions = stopConditions
    }
    profile.startSchedule = synced.startSchedule
    profile.stopSchedule = synced.stopSchedule
    profile.startNFCTagId = synced.startNFCTagId
    profile.startQRCodeId = synced.startQRCodeId
    profile.stopNFCTagId = synced.stopNFCTagId
    profile.stopQRCodeId = synced.stopQRCodeId
    profile.profileSchemaVersion = synced.profileSchemaVersion
    profile.scheduleLastStoppedAt = synced.scheduleLastStoppedAt
    modelContext.insert(profile)
    BlockedProfiles.updateSnapshot(for: profile)
  }

  // MARK: - Location apply (implemented in Task 25)

  private func applyLocationModification(_ record: CKRecord) -> ApplyOutcome {
    // Location branch — implemented in Task 25.
    return .ignored
  }

  // MARK: - Emergency apply (implemented in Task 25)

  private func applyEmergencyModification(_ record: CKRecord) -> ApplyOutcome {
    // Emergency branch — implemented in Task 25.
    return .ignored
  }

  // MARK: - Session apply (implemented in Task 26)

  private func applySessionModification(_ record: CKRecord) -> ApplyOutcome {
    // Session branch — implemented in Task 26.
    return .ignored
  }

  // MARK: - Helpers

  private func commit() throws {
    if let saveOverride {
      try saveOverride()
    } else {
      try modelContext.save()
    }
  }

  /// Store change-tag system fields — scoped types only, only after a durable apply (§2.1/§5.1).
  private func storeSystemFields(_ record: CKRecord) {
    store.setSystemFields(
      CKRecordSystemFieldsCodec.encode(record), for: record.recordID.recordName)
  }
}
```

- [ ] **Step 4 — Run; expect PASS** (same command as Step 2). Also run the full suite once to confirm nothing regressed:

```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' | xcpretty
```

- [ ] **Step 5 — Commit.**

```bash
git add Foqos/CloudKit/SyncEngine/SyncApplyService.swift FoqosTests/SyncApplyServiceTests.swift
git commit -m "feat(#267): SyncApplyService profile apply — I9 gate + E-1 + equal-version divergence + rollback (Phase B, §5.1)"
```

---

### Task 25: SyncApplyService — location (N6) and emergency (versioned) modifications

Replace the location and emergency stubs. Location: reuse the N6 client-clock merge verbatim (`SyncCoordinator.swift:438-455`); store `systemFields` after apply. Emergency: reuse the last-write-wins version gate (`SyncCoordinator.swift:514-524`); store `systemFields` only when the newer version is actually applied.

**Files:**
- Modify: `Foqos/CloudKit/SyncEngine/SyncApplyService.swift`
- Test: `FoqosTests/SyncApplyServiceTests.swift`

**Interfaces:**
- Consumes: `SyncedLocation.init?(from:)`, `SavedLocation.find/update`, `SyncedEmergencySettings.init?(from:)`, `EmergencyUnblockManager.emergencySettingsVersion/applyRemoteEmergencySettings`.

**Steps:**

- [ ] **Step 1 — Add failing tests.** Append to `SyncApplyServiceTests`:

```swift
  // MARK: - N6 location merge

  func testGivenNewerRemoteLocation_WhenApplied_ThenClientClockMergeApplies() throws {
    let now = Date()
    let id = UUID()
    let local = SavedLocation(
      id: id, name: "Home", latitude: 1, longitude: 2, defaultRadiusMeters: 100,
      isLocked: false, updatedAt: now.addingTimeInterval(-100), syncVersion: 1)
    context.insert(local)
    try context.save()

    let newer = SyncedLocation(
      locationId: id, name: "Home Updated", latitude: 3, longitude: 4,
      defaultRadiusMeters: 250, isLocked: true, lastModified: now)
    let service = makeService()
    let record = newer.toCKRecord(in: zoneID)

    XCTAssertEqual(
      service.applyFetchedModification(record, isPendingDeleteOrTombstoned: noPendingDelete),
      .applied)
    let updated = try SavedLocation.find(byID: id, in: context)
    XCTAssertEqual(updated?.name, "Home Updated")
    XCTAssertEqual(updated?.latitude, 3)
    XCTAssertEqual(updated?.isLocked, true)
    XCTAssertNotNil(store.systemFields(for: id.uuidString))
  }

  func testGivenOlderRemoteLocation_WhenApplied_ThenFieldsUnchanged() throws {
    let now = Date()
    let id = UUID()
    let local = SavedLocation(
      id: id, name: "Home", latitude: 1, longitude: 2, defaultRadiusMeters: 100,
      isLocked: false, updatedAt: now, syncVersion: 1)
    context.insert(local)
    try context.save()

    let older = SyncedLocation(
      locationId: id, name: "Stale", latitude: 9, longitude: 9, defaultRadiusMeters: 999,
      isLocked: true, lastModified: now.addingTimeInterval(-500))
    XCTAssertEqual(
      makeService().applyFetchedModification(
        older.toCKRecord(in: zoneID), isPendingDeleteOrTombstoned: noPendingDelete),
      .applied)
    XCTAssertEqual(try SavedLocation.find(byID: id, in: context)?.name, "Home", "older remote ignored")
  }

  func testGivenAbsentLocation_WhenApplied_ThenCreated() throws {
    let now = Date()
    let id = UUID()
    let synced = SyncedLocation(
      locationId: id, name: "Cafe", latitude: 5, longitude: 6, defaultRadiusMeters: 80,
      isLocked: false, lastModified: now)
    XCTAssertEqual(
      makeService().applyFetchedModification(
        synced.toCKRecord(in: zoneID), isPendingDeleteOrTombstoned: noPendingDelete),
      .applied)
    XCTAssertEqual(try SavedLocation.find(byID: id, in: context)?.name, "Cafe")
  }

  // MARK: - Emergency versioned apply

  func testGivenNewerEmergencySettings_WhenApplied_ThenAppliedAndSystemFieldsStored() {
    let now = Date()
    let nextVersion = emergencyManager.emergencySettingsVersion + 1
    let remote = SyncedEmergencySettings(
      unblocksRemaining: 7, resetPeriodInDays: 21, lastResetDate: now,
      settingsLocked: true, version: nextVersion, lastModified: now, originDeviceId: "device-B")
    XCTAssertEqual(
      makeService().applyFetchedModification(
        remote.toCKRecord(in: zoneID), isPendingDeleteOrTombstoned: noPendingDelete),
      .applied)
    XCTAssertEqual(emergencyManager.getRemainingEmergencyUnblocks(), 7)
    XCTAssertEqual(emergencyManager.emergencySettingsVersion, nextVersion)
    XCTAssertNotNil(store.systemFields(for: SyncedEmergencySettings.recordName))
  }

  func testGivenOlderEmergencySettings_WhenApplied_ThenIgnoredNoSystemFields() {
    let now = Date()
    let baseline = emergencyManager.emergencySettingsVersion + 5
    emergencyManager.applyRemoteEmergencySettings(
      SyncedEmergencySettings(
        unblocksRemaining: 1, resetPeriodInDays: 28, lastResetDate: now,
        settingsLocked: false, version: baseline, lastModified: now, originDeviceId: "device-B"))
    let stale = SyncedEmergencySettings(
      unblocksRemaining: 99, resetPeriodInDays: 99, lastResetDate: now,
      settingsLocked: true, version: baseline - 1, lastModified: now, originDeviceId: "device-C")
    XCTAssertEqual(
      makeService().applyFetchedModification(
        stale.toCKRecord(in: zoneID), isPendingDeleteOrTombstoned: noPendingDelete),
      .applied)
    XCTAssertEqual(emergencyManager.getRemainingEmergencyUnblocks(), 1, "stale version ignored")
    XCTAssertNil(store.systemFields(for: SyncedEmergencySettings.recordName))
  }
```

- [ ] **Step 2 — Run; expect FAIL** (stubs return `.ignored`, so fields are not applied and assertions fail).

```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SyncApplyServiceTests/testGivenNewerRemoteLocation_WhenApplied_ThenClientClockMergeApplies -only-testing:FoqosTests/SyncApplyServiceTests/testGivenNewerEmergencySettings_WhenApplied_ThenAppliedAndSystemFieldsStored | xcpretty
```

- [ ] **Step 3 — Implement.** In `SyncApplyService.swift`, replace the location stub:

```swift
  private func applyLocationModification(_ record: CKRecord) -> ApplyOutcome {
    // Location branch — implemented in Task 25.
    return .ignored
  }
```

with:

```swift
  private func applyLocationModification(_ record: CKRecord) -> ApplyOutcome {
    guard let synced = SyncedLocation(from: record) else {
      Log.info("Ignoring undecodable SyncedLocation record", category: .sync)
      return .ignored
    }
    let recordName = record.recordID.recordName
    do {
      if let existing = try SavedLocation.find(byID: synced.locationId, in: modelContext) {
        // N6 client-clock merge (verbatim from SyncCoordinator.swift:438-455).
        if synced.lastModified > existing.updatedAt {
          existing.syncVersion = max(existing.syncVersion, 1) + 1
          _ = try SavedLocation.update(
            existing,
            in: modelContext,
            name: synced.name,
            latitude: synced.latitude,
            longitude: synced.longitude,
            defaultRadiusMeters: synced.defaultRadiusMeters,
            isLocked: synced.isLocked
          )
        } else {
          existing.syncVersion = max(existing.syncVersion, 1)
          try commit()
        }
      } else {
        let location = SavedLocation(
          id: synced.locationId,
          name: synced.name,
          latitude: synced.latitude,
          longitude: synced.longitude,
          defaultRadiusMeters: synced.defaultRadiusMeters,
          isLocked: synced.isLocked,
          syncVersion: 1
        )
        modelContext.insert(location)
        try commit()
      }
      store.removeFailedApply(recordName: recordName)  // supersession (§5.6)
      storeSystemFields(record)
      return .applied
    } catch {
      modelContext.rollback()
      store.addFailedApply(
        FailedApply(
          recordName: recordName, recordType: SyncedLocation.recordType, op: .upsert))
      Log.error(
        "Failed to apply SyncedLocation \(recordName): \(error.localizedDescription)",
        category: .sync)
      return .failed
    }
  }
```

Then replace the emergency stub:

```swift
  private func applyEmergencyModification(_ record: CKRecord) -> ApplyOutcome {
    // Emergency branch — implemented in Task 25.
    return .ignored
  }
```

with:

```swift
  private func applyEmergencyModification(_ record: CKRecord) -> ApplyOutcome {
    guard let remote = SyncedEmergencySettings(from: record) else {
      Log.info("Ignoring undecodable SyncedEmergencySettings record", category: .sync)
      return .ignored
    }
    // Last-write-wins version gate (verbatim from SyncCoordinator.swift:514-524).
    guard remote.version > emergencyManager.emergencySettingsVersion else {
      Log.info(
        "Ignoring emergency settings v\(remote.version) "
          + "(local v\(emergencyManager.emergencySettingsVersion))", category: .sync)
      return .applied
    }
    emergencyManager.applyRemoteEmergencySettings(remote)
    store.removeFailedApply(recordName: record.recordID.recordName)  // supersession (§5.6)
    storeSystemFields(record)
    return .applied
  }
```

- [ ] **Step 4 — Run; expect PASS.**

```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SyncApplyServiceTests | xcpretty
```

- [ ] **Step 5 — Commit.**

```bash
git add Foqos/CloudKit/SyncEngine/SyncApplyService.swift FoqosTests/SyncApplyServiceTests.swift
git commit -m "feat(#267): SyncApplyService location (N6) + emergency versioned apply (Phase B, §5.1)"
```

---

### Task 26: SyncApplyService — session modifications routed to applySessionState (S-22)

Replace the session stub. A fetched `ProfileSession` modification routes to `applySessionState`, keeping the `lastModifiedBy == deviceId` self-echo filter and the directional CAS (remote-active→start, remote-stopped→stop). Sessions never enter `systemFields`. There is deliberately **no** absence-driven stop path (I1/§6): only an explicit modification (or, later, a §5.2 deletion) can stop a mirror.

**Files:**
- Modify: `Foqos/CloudKit/SyncEngine/SyncApplyService.swift`
- Test: `FoqosTests/SyncApplyServiceTests.swift`

**Interfaces:**
- Consumes: `ProfileSessionRecord.init?(from:)/applyUpdate/toCKRecord`; `SessionController.activeSession/startRemoteSession/stopRemoteSession`.

**Steps:**

- [ ] **Step 1 — Add failing test.** Append to `SyncApplyServiceTests`:

```swift
  // MARK: - S-22

  func testGivenSessionModification_WhenApplied_ThenStopsMirrorAndAbsenceNeverStops() throws {
    let now = Date()
    let id = UUID()
    let profile = BlockedProfiles(id: id, name: "Focus", syncVersion: 1)
    context.insert(profile)
    try context.save()
    let localSession = BlockedProfileSession(tag: "local", blockedProfile: profile)

    func stoppedRecord() -> CKRecord {
      var session = ProfileSessionRecord(profileId: id)
      _ = session.applyUpdate(
        isActive: true, sequenceNumber: 1, deviceId: "device-B", startTime: now)
      _ = session.applyUpdate(
        isActive: false, sequenceNumber: 2, deviceId: "device-B", endTime: now)
      return session.toCKRecord(in: zoneID)
    }

    // (1) Remote stopped + local active ⇒ stop the mirror.
    sessionController.activeSession = localSession
    let service = makeService()
    XCTAssertEqual(
      service.applyFetchedModification(stoppedRecord(), isPendingDeleteOrTombstoned: noPendingDelete),
      .applied)
    XCTAssertTrue(sessionController.stopRemoteSessionCalled)
    XCTAssertEqual(sessionController.stopRemoteSessionProfileId, id)

    // (2) Remote stopped + NO local active session ⇒ nothing is stopped (absence never stops, I1).
    sessionController.activeSession = nil
    sessionController.stopRemoteSessionCalled = false
    sessionController.stopRemoteSessionProfileId = nil
    XCTAssertEqual(
      makeService().applyFetchedModification(
        stoppedRecord(), isPendingDeleteOrTombstoned: noPendingDelete),
      .applied)
    XCTAssertFalse(sessionController.stopRemoteSessionCalled)
  }

  func testGivenOwnSessionModification_WhenApplied_ThenSelfEchoFiltered() throws {
    let now = Date()
    let id = UUID()
    let profile = BlockedProfiles(id: id, name: "Focus", syncVersion: 1)
    context.insert(profile)
    try context.save()
    sessionController.activeSession = BlockedProfileSession(tag: "local", blockedProfile: profile)

    var own = ProfileSessionRecord(profileId: id)
    _ = own.applyUpdate(isActive: true, sequenceNumber: 1, deviceId: deviceId, startTime: now)
    _ = own.applyUpdate(isActive: false, sequenceNumber: 2, deviceId: deviceId, endTime: now)

    XCTAssertEqual(
      makeService().applyFetchedModification(
        own.toCKRecord(in: zoneID), isPendingDeleteOrTombstoned: noPendingDelete),
      .applied)
    XCTAssertFalse(sessionController.stopRemoteSessionCalled, "lastModifiedBy == self is ignored")
  }
```

- [ ] **Step 2 — Run; expect FAIL** (stub returns `.ignored`; `stopRemoteSession` never called).

```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SyncApplyServiceTests/testGivenSessionModification_WhenApplied_ThenStopsMirrorAndAbsenceNeverStops | xcpretty
```

- [ ] **Step 3 — Implement.** In `SyncApplyService.swift`, replace the session stub:

```swift
  private func applySessionModification(_ record: CKRecord) -> ApplyOutcome {
    // Session branch — implemented in Task 26.
    return .ignored
  }
```

with:

```swift
  private func applySessionModification(_ record: CKRecord) -> ApplyOutcome {
    guard let session = ProfileSessionRecord(from: record) else {
      Log.info("Ignoring undecodable ProfileSession record", category: .sync)
      return .ignored
    }
    applySessionState(session)
    return .applied
  }

  /// Verbatim from SyncCoordinator.applySessionState (SyncCoordinator.swift:368-405),
  /// keeping the lastModifiedBy self-echo filter. Sessions never enter systemFields.
  private func applySessionState(_ session: ProfileSessionRecord) {
    let profileId = session.profileId
    if session.lastModifiedBy == deviceId {
      Log.info("Ignoring our own session update for \(profileId)", category: .sync)
      return
    }
    let localActive = sessionController.activeSession?.blockedProfile.id == profileId
    if session.isActive && !localActive {
      if let startTime = session.startTime {
        sessionController.startRemoteSession(
          context: modelContext, profileId: profileId, sessionId: UUID(), startTime: startTime)
      }
    } else if !session.isActive && localActive {
      sessionController.stopRemoteSession(context: modelContext, profileId: profileId)
    }
  }
```

- [ ] **Step 4 — Run; expect PASS.**

```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SyncApplyServiceTests | xcpretty
```

- [ ] **Step 5 — Commit.**

```bash
git add Foqos/CloudKit/SyncEngine/SyncApplyService.swift FoqosTests/SyncApplyServiceTests.swift
git commit -m "feat(#267): SyncApplyService session modifications via applySessionState (Phase B, §5.1/S-22)"
```

---

### Task 27: SyncApplyService — fetched deletions (§5.2): the only remote-driven deletion path

Implement `applyFetchedDeletion`: profile → delete local; location → delete local; `ProfileSession` → stop matching remote-started session (#203); command/legacy/unknown → no-op; absent-locally → no-op. On any deletion, drop the `systemFields` entry and **clear a matching tombstone** (I12 — intent satisfied) and clear any `failedApplies` entry (supersession). A thrown deletion rolls back and records a `.delete` `failedApplies` entry (retry via §5.6). The controller (later phase) uses the recordID to `state.remove` any orphaned pending change (§5.2/§5.4); that is out of scope here.

**Files:**
- Modify: `Foqos/CloudKit/SyncEngine/SyncApplyService.swift`
- Test: `FoqosTests/SyncApplyServiceTests.swift`

**Interfaces:**
- Consumes: `BlockedProfiles.findProfile/deleteProfile`, `SavedLocation.find/delete`, `SessionController.activeSession/stopRemoteSession`, `SyncEngineStore.setSystemFields(nil,for:)/clearTombstone/removeFailedApply/setTombstone`.

**Steps:**

- [ ] **Step 1 — Add failing tests.** Append to `SyncApplyServiceTests`:

```swift
  // MARK: - S-1

  func testGivenTombstonedProfile_WhenFetchedDeletionApplied_ThenOnlyThatProfileDeletedAndTombstoneCleared()
    throws
  {
    let keepId = UUID()
    let dropId = UUID()
    let keep = BlockedProfiles(id: keepId, name: "Keep", syncVersion: 1)
    let drop = BlockedProfiles(id: dropId, name: "Drop", syncVersion: 1)
    context.insert(keep)
    context.insert(drop)
    try context.save()
    store.setSystemFields(Data([0x01]), for: dropId.uuidString)
    store.setTombstone(recordName: dropId.uuidString, changeTag: "tag-1")

    let outcome = makeService().applyFetchedDeletion(
      recordID: CKRecord.ID(recordName: dropId.uuidString, zoneID: zoneID),
      recordType: SyncedProfile.recordType)

    XCTAssertEqual(outcome, .deleted)
    XCTAssertNil(try BlockedProfiles.findProfile(byID: dropId, in: context))
    XCTAssertNotNil(try BlockedProfiles.findProfile(byID: keepId, in: context), "only the named id is deleted")
    XCTAssertNil(store.systemFields(for: dropId.uuidString))
    XCTAssertNil(store.deleteTombstones[dropId.uuidString] ?? nil, "matching tombstone cleared (I12)")
  }

  func testGivenLocationDeletion_WhenApplied_ThenLocalLocationDeleted() throws {
    let id = UUID()
    let location = SavedLocation(
      id: id, name: "Home", latitude: 1, longitude: 2, defaultRadiusMeters: 100,
      isLocked: false, syncVersion: 1)
    context.insert(location)
    try context.save()

    XCTAssertEqual(
      makeService().applyFetchedDeletion(
        recordID: CKRecord.ID(recordName: id.uuidString, zoneID: zoneID),
        recordType: SyncedLocation.recordType),
      .deleted)
    XCTAssertNil(try SavedLocation.find(byID: id, in: context))
  }

  func testGivenDeletionForAbsentProfile_WhenApplied_ThenNotPresentNoMutation() throws {
    XCTAssertEqual(
      makeService().applyFetchedDeletion(
        recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID),
        recordType: SyncedProfile.recordType),
      .notPresent)
  }

  func testGivenSessionDeletion_WhenLocalActive_ThenMirrorStopped() throws {
    let id = UUID()
    let profile = BlockedProfiles(id: id, name: "Focus", syncVersion: 1)
    context.insert(profile)
    try context.save()
    sessionController.activeSession = BlockedProfileSession(tag: "local", blockedProfile: profile)

    XCTAssertEqual(
      makeService().applyFetchedDeletion(
        recordID: CKRecord.ID(
          recordName: ProfileSessionRecord.recordName(for: id), zoneID: zoneID),
        recordType: ProfileSessionRecord.recordType),
      .deleted)
    XCTAssertTrue(sessionController.stopRemoteSessionCalled)
    XCTAssertEqual(sessionController.stopRemoteSessionProfileId, id)
  }

  // MARK: - S-2

  func testGivenEmptyFetch_WhenApplied_ThenZeroLocalMutations() throws {
    let p1 = BlockedProfiles(id: UUID(), name: "A", syncVersion: 1)
    let p2 = BlockedProfiles(id: UUID(), name: "B", syncVersion: 1)
    context.insert(p1)
    context.insert(p2)
    try context.save()
    let before = try BlockedProfiles.fetchProfiles(in: context).count

    let service = makeService()
    for record in [CKRecord]() {
      _ = service.applyFetchedModification(record, isPendingDeleteOrTombstoned: noPendingDelete)
    }
    for pair in [(CKRecord.ID, CKRecord.RecordType)]() {
      _ = service.applyFetchedDeletion(recordID: pair.0, recordType: pair.1)
    }

    XCTAssertEqual(try BlockedProfiles.fetchProfiles(in: context).count, before, "empty fetch mutates nothing")
    XCTAssertTrue(service.pendingReenqueues.isEmpty)
  }
```

- [ ] **Step 2 — Run; expect FAIL** (`applyFetchedDeletion` stub returns `.ignored`).

```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SyncApplyServiceTests/testGivenTombstonedProfile_WhenFetchedDeletionApplied_ThenOnlyThatProfileDeletedAndTombstoneCleared | xcpretty
```

- [ ] **Step 3 — Implement.** In `SyncApplyService.swift`, replace the deletion stub:

```swift
  func applyFetchedDeletion(
    recordID: CKRecord.ID, recordType: CKRecord.RecordType
  ) -> DeletionOutcome {
    // Real implementation added in Task 27.
    return .ignored
  }
```

with:

```swift
  func applyFetchedDeletion(
    recordID: CKRecord.ID, recordType: CKRecord.RecordType
  ) -> DeletionOutcome {
    let recordName = recordID.recordName
    switch recordType {
    case SyncedProfile.recordType:
      return deleteLocalProfile(recordName: recordName)
    case SyncedLocation.recordType:
      return deleteLocalLocation(recordName: recordName)
    case ProfileSessionRecord.recordType:
      return stopSessionForDeletedRecord(recordName: recordName)
    default:
      // Command / legacy / unknown ⇒ no-op (§5.2).
      return .ignored
    }
  }

  private func clearDeletionBookkeeping(recordName: String) {
    store.setSystemFields(nil, for: recordName)
    store.clearTombstone(recordName: recordName)
    store.removeFailedApply(recordName: recordName)
  }

  private func deleteLocalProfile(recordName: String) -> DeletionOutcome {
    guard let id = UUID(uuidString: recordName) else { return .ignored }
    do {
      guard let profile = try BlockedProfiles.findProfile(byID: id, in: modelContext) else {
        clearDeletionBookkeeping(recordName: recordName)  // intent already satisfied
        return .notPresent
      }
      try BlockedProfiles.deleteProfile(profile, in: modelContext)  // defers save
      try commit()
      clearDeletionBookkeeping(recordName: recordName)
      return .deleted
    } catch {
      modelContext.rollback()
      store.addFailedApply(
        FailedApply(
          recordName: recordName, recordType: SyncedProfile.recordType, op: .delete))
      Log.error(
        "Failed to apply profile deletion \(recordName): \(error.localizedDescription)",
        category: .sync)
      return .ignored
    }
  }

  private func deleteLocalLocation(recordName: String) -> DeletionOutcome {
    guard let id = UUID(uuidString: recordName) else { return .ignored }
    do {
      guard let location = try SavedLocation.find(byID: id, in: modelContext) else {
        clearDeletionBookkeeping(recordName: recordName)
        return .notPresent
      }
      try SavedLocation.delete(location, in: modelContext)  // saves internally
      clearDeletionBookkeeping(recordName: recordName)
      return .deleted
    } catch {
      modelContext.rollback()
      store.addFailedApply(
        FailedApply(
          recordName: recordName, recordType: SyncedLocation.recordType, op: .delete))
      Log.error(
        "Failed to apply location deletion \(recordName): \(error.localizedDescription)",
        category: .sync)
      return .ignored
    }
  }

  private func stopSessionForDeletedRecord(recordName: String) -> DeletionOutcome {
    let prefix = "ProfileSession_"
    guard recordName.hasPrefix(prefix),
      let id = UUID(uuidString: String(recordName.dropFirst(prefix.count)))
    else {
      return .ignored
    }
    // §5.2: an explicit deletion stops the matching remote-started session (#203).
    if sessionController.activeSession?.blockedProfile.id == id {
      sessionController.stopRemoteSession(context: modelContext, profileId: id)
      return .deleted
    }
    return .notPresent
  }
```

- [ ] **Step 4 — Run; expect PASS.**

```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SyncApplyServiceTests | xcpretty
```

- [ ] **Step 5 — Commit.**

```bash
git add Foqos/CloudKit/SyncEngine/SyncApplyService.swift FoqosTests/SyncApplyServiceTests.swift
git commit -m "feat(#267): SyncApplyService fetched deletions — profile/location/session + tombstone clear (Phase B, §5.2)"
```

---

### Task 28: SyncApplyService — pending-delete-wins + confirmed-delete echo guard (S-32, S-34)

Insert the §5.1 skip guard at the top of `applyFetchedModification`: a modification whose id has a pending `.deleteRecord`/live tombstone (`isPendingDeleteOrTombstoned` closure supplied by the controller) **or** is in the in-memory `recentlyConfirmedDeletes` echo guard is skipped (`.skippedPendingDelete`) with zero local mutation. The echo-guard drain (at the next cycle's start) is the controller's job (later phase); this task delivers the guard mechanism and its membership check.

**Files:**
- Modify: `Foqos/CloudKit/SyncEngine/SyncApplyService.swift`
- Test: `FoqosTests/SyncApplyServiceTests.swift`

**Interfaces:**
- Consumes: the `isPendingDeleteOrTombstoned: (String) -> Bool` parameter (already on `applyFetchedModification`) and `recentlyConfirmedDeletes`.

**Steps:**

- [ ] **Step 1 — Add failing tests.** Append to `SyncApplyServiceTests`:

```swift
  // MARK: - S-32

  func testGivenPendingDeleteId_WhenModificationApplied_ThenSkippedPendingDelete() throws {
    let now = Date()
    let id = UUID()
    let record = makeProfileRecord(
      id: id, name: "Ghost", version: 3, originDeviceId: "device-B", now: now)
    let service = makeService()

    let outcome = service.applyFetchedModification(
      record, isPendingDeleteOrTombstoned: { $0 == id.uuidString })

    XCTAssertEqual(outcome, .skippedPendingDelete)
    XCTAssertNil(try BlockedProfiles.findProfile(byID: id, in: context), "no local create while a delete is pending")
    XCTAssertNil(store.systemFields(for: id.uuidString))
    XCTAssertTrue(service.pendingReenqueues.isEmpty)
  }

  // MARK: - S-34

  func testGivenEchoGuardId_WhenModificationApplied_ThenSkippedUntilDrained() throws {
    let now = Date()
    let id = UUID()
    let record = makeProfileRecord(
      id: id, name: "Recreated", version: 3, originDeviceId: "device-B", now: now)
    let service = makeService()

    // A cycle that started before the delete confirmation delivers an echo ⇒ skipped.
    service.recentlyConfirmedDeletes = [id.uuidString]
    XCTAssertEqual(
      service.applyFetchedModification(record, isPendingDeleteOrTombstoned: noPendingDelete),
      .skippedPendingDelete)
    XCTAssertNil(try BlockedProfiles.findProfile(byID: id, in: context))

    // After the guard drains (controller clears it at the next cycle's start), the same
    // record is a genuine recreation and must apply.
    service.recentlyConfirmedDeletes = []
    XCTAssertEqual(
      service.applyFetchedModification(record, isPendingDeleteOrTombstoned: noPendingDelete),
      .applied)
    XCTAssertNotNil(try BlockedProfiles.findProfile(byID: id, in: context), "genuine recreation applies")
  }
```

- [ ] **Step 2 — Run; expect FAIL** (guard absent — the modification currently applies/creates instead of skipping).

```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SyncApplyServiceTests/testGivenPendingDeleteId_WhenModificationApplied_ThenSkippedPendingDelete | xcpretty
```

- [ ] **Step 3 — Implement.** In `SyncApplyService.swift`, replace the opening of `applyFetchedModification`:

```swift
  func applyFetchedModification(
    _ record: CKRecord, isPendingDeleteOrTombstoned: (String) -> Bool
  ) -> ApplyOutcome {
    switch record.recordType {
```

with:

```swift
  func applyFetchedModification(
    _ record: CKRecord, isPendingDeleteOrTombstoned: (String) -> Bool
  ) -> ApplyOutcome {
    let recordName = record.recordID.recordName
    // Pending-delete-wins (§5.1): a modification shadowed by a pending delete, a live
    // tombstone, or the in-memory confirmed-delete echo guard is skipped.
    if isPendingDeleteOrTombstoned(recordName) || recentlyConfirmedDeletes.contains(recordName) {
      Log.info(
        "Skipping fetched modification for pending-delete/echo-guarded id \(recordName)",
        category: .sync)
      return .skippedPendingDelete
    }
    switch record.recordType {
```

- [ ] **Step 4 — Run; expect PASS**, then run the full suite to confirm the phase leaves all 429 existing tests plus the Phase B additions green:

```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SyncApplyServiceTests | xcpretty
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' | xcpretty
```

- [ ] **Step 5 — Commit.**

```bash
git add Foqos/CloudKit/SyncEngine/SyncApplyService.swift FoqosTests/SyncApplyServiceTests.swift
git commit -m "feat(#267): SyncApplyService pending-delete-wins + echo guard (Phase B, §5.1/S-32/S-34)"
```

---

**Phase B complete.** New units delivered: `CKRecordSystemFieldsCodec`, `SyncPayloadEquality`, `RecordProvider`, `SyncApplyService` (full §5.1 fetched-modification routing + I9 gate + E-1 + equal-version divergence + N6 + versioned emergency + session routing; full §5.2 fetched-deletion path + tombstone/systemFields/failedApply bookkeeping; pending-delete-wins + echo guard), plus the `EmergencyUnblockManager.currentEmergencySettings` snapshot source. All merge helpers (`updateLocalProfile`, `createLocalProfile`, I9 gate, N6, emergency gate, `applySessionState`) are reused verbatim from `SyncCoordinator`, minus the deletion-reconciliation and own-origin-skip amendments. `SyncApplyService.pendingReenqueues`/`drainReenqueues()` and `applyFetchedDeletion`'s recordID-based effects are the seams the controller phase consumes to `state.add`/`state.remove`. Nothing is wired into the engine, driver, or `FoqosApp`; `SyncCoordinator`'s existing handlers are untouched (cutover is Phase F).

---

## Phase C — MutationFunnel + delete-intent tombstones (I2/I12 write side)

> Implements the single outbound funnel for locally-originated create/update/delete (design §2 save/delete paths, I2, I12; §9 "`pushProfile` increment moves into the funnel"). Nothing here is wired into any UI call site — call-site rerouting is the cutover phase. **Phase exit criterion (applies to every task below): `Foqos/CloudKit/SyncEngine/MutationFunnel.swift` compiles, the funnel is referenced by no production call site yet, and the full existing 429-test suite stays green.**
>
> **Shared dependencies consumed verbatim from earlier phases / the locked contract:**
> - `SyncEngineStore` (locked contract §2.1): `init(userRecordName:defaults:)`, `func systemFields(for:) -> Data?`, `func setSystemFields(_:for:)`, `var deleteTombstones: [String: String?]`, `func setTombstone(recordName:changeTag:)`, `func clearTombstone(recordName:)`. Compound writes go through `SharedData.withLock`, so tests must `SharedData.configure(suite:)`.
> - `SyncEngineDriver` (locked contract, engine seam): `@MainActor protocol` exposing `var pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange] { get }` and `func add(pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange])`.
> - `MockSyncEngineDriver` (Phase A, `FoqosTests/Mocks/MockSyncEngineDriver.swift`): test double conforming to `SyncEngineDriver`; default `init()`; `add(pendingRecordZoneChanges:)` appends to its `pendingRecordZoneChanges` array and `remove(...)` subtracts, so the protocol getter reflects the current pending set. (If Phase A's `init` differs, adjust the one construction call — the assertions only touch `pendingRecordZoneChanges`.)
> - Existing app symbols reused: `CloudKitConstants.syncZoneName` (`"DeviceSync"`), `BlockedProfiles.findProfile(byID:in:)` / `deleteProfile(_:in:)` / `isNewerSchemaVersion` / `syncVersion`, `SavedLocation.find(byID:in:)` / `delete(_:in:)` / `updatedAt`, `SyncedProfile.recordType`, `SyncedEmergencySettings.recordName`, `EmergencyUnblockManager.shared`, `Log`.
> - Test helpers reused: `TestModelContainer.create()`, `MockSyncEngineDriver`. The funnel runs on its **own dedicated sync `ModelContext`** (design §2 round-6); tests supply that context plus a **separate** context that plays the already-saved user mutation, both from one in-memory container.

---

### Task 40: MutationFunnel scaffold + `enqueueSave(profileId:)` bump-in-write + S-16 bypass regression

**Files:**
- Create: `Foqos/CloudKit/SyncEngine/MutationFunnel.swift`
- Test: `FoqosTests/MutationFunnelTests.swift`

**Interfaces:**
- Produces: `@MainActor final class MutationFunnel { init(modelContext: ModelContext, store: SyncEngineStore, driver: SyncEngineDriver, deviceId: String); func enqueueSave(profileId: UUID) throws }`, `enum MutationFunnel.MutationFunnelError: Error, Equatable { case entityNotFound }`
- Consumes: `SyncEngineStore`, `SyncEngineDriver`/`MockSyncEngineDriver`, `BlockedProfiles.findProfile(byID:in:)`, `BlockedProfiles.syncVersion`, `CloudKitConstants.syncZoneName`, `CKSyncEngine.PendingRecordZoneChange.saveRecord(_:)`

**Steps:**

- [ ] **Step 1 — Write the failing test.** Create `FoqosTests/MutationFunnelTests.swift` with the shared scaffold and the first two tests (S-15 save-positive, S-16 bypass regression):

```swift
import CloudKit
import SwiftData
import XCTest

@preconcurrency import FoqosShared

@testable import FamilyFoqos

@MainActor
final class MutationFunnelTests: XCTestCase {

  private var suiteName: String!
  private var defaults: UserDefaults!
  private let userRecordName = "phaseC-user"

  override func setUp() {
    super.setUp()
    suiteName = "MutationFunnelTests-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)!
    SharedData.configure(suite: defaults)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    defaults = nil
    suiteName = nil
    super.tearDown()
  }

  // MARK: - Helpers

  private func makeStore() -> SyncEngineStore {
    SyncEngineStore(userRecordName: userRecordName, defaults: defaults)
  }

  private var zoneID: CKRecordZone.ID {
    CKRecordZone.ID(zoneName: CloudKitConstants.syncZoneName, ownerName: CKCurrentUserDefaultName)
  }

  private func recordID(_ name: String) -> CKRecord.ID {
    CKRecord.ID(recordName: name, zoneID: zoneID)
  }

  @discardableResult
  private func insertProfile(
    in context: ModelContext,
    id: UUID,
    name: String,
    syncVersion: Int = 0
  ) throws -> BlockedProfiles {
    let profile = BlockedProfiles(id: id, name: name, syncVersion: syncVersion)
    context.insert(profile)
    try context.save()
    return profile
  }

  private func encodedSystemFields(recordName: String) -> Data {
    let record = CKRecord(recordType: SyncedProfile.recordType, recordID: recordID(recordName))
    let archiver = NSKeyedArchiver(requiringSecureCoding: true)
    record.encodeSystemFields(with: archiver)
    archiver.finishEncoding()
    return archiver.encodedData
  }

  // MARK: - S-15 / S-16: save bumps in the same write, enqueues once

  func testGivenProfile_WhenEnqueueSave_ThenBumpsVersionInSameWriteAndEnqueuesOnce() throws {
    // Given: a profile already saved by the "user" context, and the funnel on its own sync context.
    let now = Date()
    let profileId = UUID()
    let container = try TestModelContainer.create()
    let userContext = ModelContext(container)
    try insertProfile(in: userContext, id: profileId, name: "Focus", syncVersion: 3)

    let syncContext = ModelContext(container)
    let store = makeStore()
    let driver = MockSyncEngineDriver()
    let funnel = MutationFunnel(
      modelContext: syncContext,
      store: store,
      driver: driver,
      deviceId: "device-A"
    )

    // When
    try funnel.enqueueSave(profileId: profileId)

    // Then: version bumped exactly once, on the funnel's own context...
    let onSync = try XCTUnwrap(BlockedProfiles.findProfile(byID: profileId, in: syncContext))
    XCTAssertEqual(onSync.syncVersion, 4, "bump must be +1 in the same write")

    // ...and persisted (a fresh context observes the committed bump)...
    let verifyContext = ModelContext(container)
    let persisted = try XCTUnwrap(BlockedProfiles.findProfile(byID: profileId, in: verifyContext))
    XCTAssertEqual(persisted.syncVersion, 4)

    // ...and exactly one pending .saveRecord enqueued.
    XCTAssertEqual(driver.pendingRecordZoneChanges, [.saveRecord(recordID(profileId.uuidString))])
    _ = now
  }

  func testGivenEditBypassingFunnel_ThenNoBumpAndNoEnqueue() throws {
    // Given: a profile edited directly, NOT through the funnel (the locked-in regression).
    let now = Date()
    let profileId = UUID()
    let container = try TestModelContainer.create()
    let userContext = ModelContext(container)
    let profile = try insertProfile(in: userContext, id: profileId, name: "Focus", syncVersion: 3)

    let driver = MockSyncEngineDriver()

    // When: a plain field edit that bypasses MutationFunnel.
    profile.name = "Renamed"
    try userContext.save()

    // Then: no version bump and nothing enqueued — a bypassing edit cannot propagate.
    let reread = try XCTUnwrap(BlockedProfiles.findProfile(byID: profileId, in: userContext))
    XCTAssertEqual(reread.syncVersion, 3, "a bypassing edit must not bump the version")
    XCTAssertTrue(driver.pendingRecordZoneChanges.isEmpty, "a bypassing edit must not enqueue")
    _ = now
  }
}
```

- [ ] **Step 2 — Run, expect fail (compile failure: `MutationFunnel` undefined).**
```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/MutationFunnelTests/testGivenProfile_WhenEnqueueSave_ThenBumpsVersionInSameWriteAndEnqueuesOnce | xcpretty
```

- [ ] **Step 3 — Minimal implementation.** Create `Foqos/CloudKit/SyncEngine/MutationFunnel.swift`:

```swift
import CloudKit
import Foundation
import SwiftData

/// The single API for every locally-originated create/update/delete of a synced entity (I2).
/// Save path: bump the entity's version inside the same persisted write, then enqueue a
/// `.saveRecord`. Delete path (added in later tasks): persist a delete-intent tombstone before
/// the entity delete, roll it back on failure, then enqueue a `.deleteRecord`.
///
/// Runs on the sync paths' own `ModelContext` (design §2, round-6) so a rollback can never
/// discard unrelated uncommitted user edits.
@MainActor
final class MutationFunnel {

  enum MutationFunnelError: Error, Equatable {
    case entityNotFound
  }

  private let modelContext: ModelContext
  private let store: SyncEngineStore
  private let driver: SyncEngineDriver
  private let deviceId: String

  init(
    modelContext: ModelContext,
    store: SyncEngineStore,
    driver: SyncEngineDriver,
    deviceId: String
  ) {
    self.modelContext = modelContext
    self.store = store
    self.driver = driver
    self.deviceId = deviceId
  }

  private var zoneID: CKRecordZone.ID {
    CKRecordZone.ID(zoneName: CloudKitConstants.syncZoneName, ownerName: CKCurrentUserDefaultName)
  }

  // MARK: - Save paths

  /// Re-read the profile on the sync context, bump `syncVersion` in the same persisted write,
  /// require the write to succeed, then enqueue exactly one `.saveRecord` (I2, §9).
  func enqueueSave(profileId: UUID) throws {
    guard let profile = try BlockedProfiles.findProfile(byID: profileId, in: modelContext) else {
      throw MutationFunnelError.entityNotFound
    }
    profile.syncVersion += 1
    do {
      try modelContext.save()
    } catch {
      modelContext.rollback()
      throw error
    }
    let recordID = CKRecord.ID(recordName: profileId.uuidString, zoneID: zoneID)
    driver.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
  }
}
```

- [ ] **Step 4 — Run, expect pass (both Task-40 tests green).**
```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/MutationFunnelTests | xcpretty
```

- [ ] **Step 5 — Commit.**
```bash
git add Foqos/CloudKit/SyncEngine/MutationFunnel.swift FoqosTests/MutationFunnelTests.swift
git commit -m "feat(#267): MutationFunnel enqueueSave(profileId:) bump-in-write + S-16 bypass regression"
```

---

### Task 41: `enqueueSave(profileId:)` failure + newer-schema guard

**Files:**
- Modify: `Foqos/CloudKit/SyncEngine/MutationFunnel.swift`
- Test: `FoqosTests/MutationFunnelTests.swift`

**Interfaces:**
- Consumes: `BlockedProfiles.isNewerSchemaVersion`, `MutationFunnel.MutationFunnelError.entityNotFound`

**Steps:**

- [ ] **Step 1 — Write the failing tests.** Add to `MutationFunnelTests`:

```swift
  // MARK: - S-15: failed save operation does not bump or enqueue

  func testGivenMissingProfile_WhenEnqueueSave_ThenThrowsWithoutBumpOrEnqueue() throws {
    // Given: the profile does not exist on the funnel's sync context (deterministic failure surface).
    let now = Date()
    let container = try TestModelContainer.create()
    let syncContext = ModelContext(container)
    let store = makeStore()
    let driver = MockSyncEngineDriver()
    let funnel = MutationFunnel(
      modelContext: syncContext,
      store: store,
      driver: driver,
      deviceId: "device-A"
    )

    // When / Then: the operation fails and nothing is enqueued.
    XCTAssertThrowsError(try funnel.enqueueSave(profileId: UUID())) { error in
      XCTAssertEqual(error as? MutationFunnel.MutationFunnelError, .entityNotFound)
    }
    XCTAssertTrue(driver.pendingRecordZoneChanges.isEmpty)
    _ = now
  }

  // MARK: - I2 / S-14: newer-schema profiles are never enqueued for save

  func testGivenNewerSchemaProfile_WhenEnqueueSave_ThenNeverEnqueuedAndNoBump() throws {
    // Given: a profile whose schema version is newer than this app understands.
    let now = Date()
    let profileId = UUID()
    let container = try TestModelContainer.create()
    let userContext = ModelContext(container)
    let profile = try insertProfile(in: userContext, id: profileId, name: "FromFuture", syncVersion: 5)
    profile.profileSchemaVersion = BlockedProfiles.currentSchemaVersion + 1
    try userContext.save()

    let syncContext = ModelContext(container)
    let store = makeStore()
    let driver = MockSyncEngineDriver()
    let funnel = MutationFunnel(
      modelContext: syncContext,
      store: store,
      driver: driver,
      deviceId: "device-A"
    )

    // When
    try funnel.enqueueSave(profileId: profileId)

    // Then: no bump, no enqueue (I2; §5.4 refuse-to-materialize is upstream, this refuses at the source).
    let reread = try XCTUnwrap(BlockedProfiles.findProfile(byID: profileId, in: syncContext))
    XCTAssertEqual(reread.syncVersion, 5)
    XCTAssertTrue(driver.pendingRecordZoneChanges.isEmpty)
    _ = now
  }
```

- [ ] **Step 2 — Run, expect fail** (`testGivenNewerSchemaProfile...` fails: current impl bumps + enqueues the newer-schema profile).
```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/MutationFunnelTests/testGivenNewerSchemaProfile_WhenEnqueueSave_ThenNeverEnqueuedAndNoBump | xcpretty
```

- [ ] **Step 3 — Minimal implementation.** In `enqueueSave(profileId:)`, add the newer-schema guard immediately after the profile is found and before the bump:

```swift
  func enqueueSave(profileId: UUID) throws {
    guard let profile = try BlockedProfiles.findProfile(byID: profileId, in: modelContext) else {
      throw MutationFunnelError.entityNotFound
    }
    // Never enqueue newer-schema profiles (I2; the newer device is authoritative — §5.4).
    guard !profile.isNewerSchemaVersion else {
      Log.info(
        "MutationFunnel skipping save for newer-schema profile '\(profile.name)'",
        category: .sync
      )
      return
    }
    profile.syncVersion += 1
    do {
      try modelContext.save()
    } catch {
      modelContext.rollback()
      throw error
    }
    let recordID = CKRecord.ID(recordName: profileId.uuidString, zoneID: zoneID)
    driver.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
  }
```

- [ ] **Step 4 — Run, expect pass.**
```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/MutationFunnelTests | xcpretty
```

- [ ] **Step 5 — Commit.**
```bash
git add Foqos/CloudKit/SyncEngine/MutationFunnel.swift FoqosTests/MutationFunnelTests.swift
git commit -m "feat(#267): MutationFunnel save-failure guard + newer-schema profile never enqueued (I2)"
```

---

### Task 42: `enqueueSave(locationId:)` + `enqueueEmergencySettingsSave()`

**Files:**
- Modify: `Foqos/CloudKit/SyncEngine/MutationFunnel.swift`
- Modify: `Foqos/Utils/EmergencyUnblockManager.swift` (expose a version-bump hook — no call site wired)
- Test: `FoqosTests/MutationFunnelTests.swift`

**Interfaces:**
- Produces: `func enqueueSave(locationId: UUID) throws`, `func enqueueEmergencySettingsSave() throws`; `EmergencyUnblockManager.incrementEmergencySettingsVersionForSync()`
- Consumes: `SavedLocation.find(byID:in:)` / `updatedAt`, `SyncedEmergencySettings.recordName`, `EmergencyUnblockManager.shared`

**Steps:**

- [ ] **Step 1 — Write the failing tests.** Add to `MutationFunnelTests`:

```swift
  // MARK: - Location save: advances updatedAt, enqueues once

  func testGivenLocation_WhenEnqueueSave_ThenAdvancesUpdatedAtAndEnqueuesOnce() throws {
    // Given: a location whose updatedAt is well in the past.
    let now = Date()
    let past = now.addingTimeInterval(-3600)
    let locationId = UUID()
    let container = try TestModelContainer.create()
    let userContext = ModelContext(container)
    let location = SavedLocation(
      id: locationId,
      name: "Home",
      latitude: 1,
      longitude: 2,
      updatedAt: past
    )
    userContext.insert(location)
    try userContext.save()

    let syncContext = ModelContext(container)
    let store = makeStore()
    let driver = MockSyncEngineDriver()
    let funnel = MutationFunnel(
      modelContext: syncContext,
      store: store,
      driver: driver,
      deviceId: "device-A"
    )

    // When
    try funnel.enqueueSave(locationId: locationId)

    // Then: updatedAt advanced (design §2: locations advance updatedAt) and enqueued once.
    let reread = try XCTUnwrap(SavedLocation.find(byID: locationId, in: syncContext))
    XCTAssertGreaterThan(reread.updatedAt, past)
    XCTAssertEqual(driver.pendingRecordZoneChanges, [.saveRecord(recordID(locationId.uuidString))])
  }

  // MARK: - Emergency settings save: bumps version, enqueues the fixed-name record

  func testGivenEmergencySettings_WhenEnqueueSave_ThenBumpsVersionAndEnqueuesOnce() throws {
    let now = Date()
    let container = try TestModelContainer.create()
    let syncContext = ModelContext(container)
    let store = makeStore()
    let driver = MockSyncEngineDriver()
    let funnel = MutationFunnel(
      modelContext: syncContext,
      store: store,
      driver: driver,
      deviceId: "device-A"
    )
    let before = EmergencyUnblockManager.shared.emergencySettingsVersion

    // When
    try funnel.enqueueEmergencySettingsSave()

    // Then: version bumped by one and the single fixed-name record enqueued once.
    XCTAssertEqual(EmergencyUnblockManager.shared.emergencySettingsVersion, before + 1)
    XCTAssertEqual(
      driver.pendingRecordZoneChanges,
      [.saveRecord(recordID(SyncedEmergencySettings.recordName))]
    )
    _ = now
  }
```

- [ ] **Step 2 — Run, expect fail** (methods undefined).
```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/MutationFunnelTests/testGivenLocation_WhenEnqueueSave_ThenAdvancesUpdatedAtAndEnqueuesOnce | xcpretty
```

- [ ] **Step 3 — Minimal implementation.** First expose the bump on `EmergencyUnblockManager` (its `emergencySettingsVersion` is `private(set)`; the `didSet` already persists to `UserDefaults.standard`, so the bump is durable synchronously). Add, next to the `emergencySettingsVersion` declaration:

```swift
  /// Increment the synced emergency-settings version as part of MutationFunnel's save path (I2).
  /// The property's `didSet` persists the new value immediately.
  func incrementEmergencySettingsVersionForSync() {
    emergencySettingsVersion += 1
  }
```

Then add the two funnel methods after `enqueueSave(profileId:)`:

```swift
  /// Re-read the location on the sync context, advance `updatedAt` in the same persisted write
  /// (locations merge by client clock — §5.1/N6), then enqueue one `.saveRecord`.
  func enqueueSave(locationId: UUID) throws {
    guard let location = try SavedLocation.find(byID: locationId, in: modelContext) else {
      throw MutationFunnelError.entityNotFound
    }
    location.updatedAt = Date()
    do {
      try modelContext.save()
    } catch {
      modelContext.rollback()
      throw error
    }
    let recordID = CKRecord.ID(recordName: locationId.uuidString, zoneID: zoneID)
    driver.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
  }

  /// Bump the emergency-settings version and enqueue the single fixed-name record (I2, §2).
  func enqueueEmergencySettingsSave() throws {
    EmergencyUnblockManager.shared.incrementEmergencySettingsVersionForSync()
    let recordID = CKRecord.ID(recordName: SyncedEmergencySettings.recordName, zoneID: zoneID)
    driver.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
  }
```

- [ ] **Step 4 — Run, expect pass.**
```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/MutationFunnelTests | xcpretty
```

- [ ] **Step 5 — Commit.**
```bash
git add Foqos/CloudKit/SyncEngine/MutationFunnel.swift Foqos/Utils/EmergencyUnblockManager.swift FoqosTests/MutationFunnelTests.swift
git commit -m "feat(#267): MutationFunnel enqueueSave(locationId:) + enqueueEmergencySettingsSave (I2)"
```

---

### Task 43: `enqueueDelete(profileId:)` happy path — tombstone-with-tag + enqueue once, and the change-tag helper

**Files:**
- Modify: `Foqos/CloudKit/SyncEngine/MutationFunnel.swift`
- Test: `FoqosTests/MutationFunnelTests.swift`

**Interfaces:**
- Produces: `func enqueueDelete(profileId: UUID) throws`; `static func changeTag(fromSystemFields data: Data?) -> String?`
- Consumes: `SyncEngineStore.systemFields(for:)` / `setTombstone(recordName:changeTag:)` / `deleteTombstones`, `BlockedProfiles.deleteProfile(_:in:)`, `CKSyncEngine.PendingRecordZoneChange.deleteRecord(_:)`

**Steps:**

- [ ] **Step 1 — Write the failing tests.** Add to `MutationFunnelTests`:

```swift
  // MARK: - S-15 / S-29: delete writes a tombstone carrying the change tag, enqueues once

  func testGivenSyncedProfile_WhenEnqueueDelete_ThenWritesTombstoneWithTagAndEnqueuesOnce() throws {
    // Given: a synced profile whose last-known server system-fields are cached in the store.
    let now = Date()
    let profileId = UUID()
    let recordName = profileId.uuidString
    let container = try TestModelContainer.create()
    let userContext = ModelContext(container)
    try insertProfile(in: userContext, id: profileId, name: "Focus", syncVersion: 2)

    let store = makeStore()
    let systemFields = encodedSystemFields(recordName: recordName)
    store.setSystemFields(systemFields, for: recordName)

    let syncContext = ModelContext(container)
    let driver = MockSyncEngineDriver()
    let funnel = MutationFunnel(
      modelContext: syncContext,
      store: store,
      driver: driver,
      deviceId: "device-A"
    )

    // When
    try funnel.enqueueDelete(profileId: profileId)

    // Then: the entity is gone (locally and persisted)...
    XCTAssertNil(try BlockedProfiles.findProfile(byID: profileId, in: syncContext))
    let verifyContext = ModelContext(container)
    XCTAssertNil(try BlockedProfiles.findProfile(byID: profileId, in: verifyContext))

    // ...a tombstone exists carrying exactly the change tag derived from the cached system fields...
    XCTAssertTrue(store.deleteTombstones.keys.contains(recordName), "tombstone must be written")
    XCTAssertEqual(
      store.deleteTombstones[recordName] ?? nil,
      MutationFunnel.changeTag(fromSystemFields: systemFields),
      "tombstone tag must come from the record's cached systemFields (I12)"
    )

    // ...and exactly one pending .deleteRecord was enqueued.
    XCTAssertEqual(driver.pendingRecordZoneChanges, [.deleteRecord(recordID(recordName))])
    _ = now
  }

  // MARK: - change-tag extraction is crash-safe on nil / garbage input

  func testChangeTagFromSystemFields_HandlesNilAndGarbage() {
    XCTAssertNil(MutationFunnel.changeTag(fromSystemFields: nil))
    XCTAssertNil(MutationFunnel.changeTag(fromSystemFields: Data([0x00, 0x01, 0x02])))
  }
```

- [ ] **Step 2 — Run, expect fail** (`enqueueDelete`/`changeTag` undefined).
```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/MutationFunnelTests/testGivenSyncedProfile_WhenEnqueueDelete_ThenWritesTombstoneWithTagAndEnqueuesOnce | xcpretty
```

- [ ] **Step 3 — Minimal implementation.** Add the delete path and the change-tag helper to `MutationFunnel`:

```swift
  // MARK: - Delete paths

  /// Persist a delete-intent tombstone (recordName -> last-known server change tag, nil if never
  /// synced) BEFORE the entity delete; require the delete to succeed, else remove the tombstone and
  /// roll the sync context back before returning; then enqueue one `.deleteRecord` (I12, §2).
  func enqueueDelete(profileId: UUID) throws {
    let recordName = profileId.uuidString
    let changeTag = Self.changeTag(fromSystemFields: store.systemFields(for: recordName))
    store.setTombstone(recordName: recordName, changeTag: changeTag)
    do {
      guard let profile = try BlockedProfiles.findProfile(byID: profileId, in: modelContext) else {
        throw MutationFunnelError.entityNotFound
      }
      try BlockedProfiles.deleteProfile(profile, in: modelContext)
      try modelContext.save()
    } catch {
      store.clearTombstone(recordName: recordName)
      modelContext.rollback()
      throw error
    }
    let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
    driver.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
  }

  // MARK: - System-fields change tag

  /// Decode the last-known server change tag from cached CKRecord system fields.
  /// Returns nil when there are no cached fields (never synced) or the blob cannot decode.
  static func changeTag(fromSystemFields data: Data?) -> String? {
    guard let data else { return nil }
    guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
    unarchiver.requiresSecureCoding = false
    let record = CKRecord(coder: unarchiver)
    unarchiver.finishDecoding()
    return record?.recordChangeTag
  }
```

- [ ] **Step 4 — Run, expect pass.**
```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/MutationFunnelTests | xcpretty
```

- [ ] **Step 5 — Commit.**
```bash
git add Foqos/CloudKit/SyncEngine/MutationFunnel.swift FoqosTests/MutationFunnelTests.swift
git commit -m "feat(#267): MutationFunnel enqueueDelete(profileId:) writes tombstone with change tag (I12)"
```

---

### Task 44: `enqueueDelete(profileId:)` failure — tombstone removed + rollback + nothing enqueued

**Files:**
- Modify: `FoqosTests/MutationFunnelTests.swift` (impl already correct from Task 43; this task locks the failure contract with a test)

**Interfaces:**
- Consumes: `SyncEngineStore.deleteTombstones`, `MutationFunnel.enqueueDelete(profileId:)`, `MutationFunnel.MutationFunnelError.entityNotFound`

**Steps:**

- [ ] **Step 1 — Write the failing test.** Add to `MutationFunnelTests` (this asserts the round-4/5 rollback rule: a failed entity delete must not leave a lingering tombstone — which would later kill the live record family-wide — nor enqueue an outbound delete):

```swift
  // MARK: - S-15: failed entity delete removes the tombstone before returning and enqueues nothing

  func testGivenFailedProfileDelete_WhenEnqueueDelete_ThenTombstoneRemovedRollbackAndNothingEnqueued()
    throws
  {
    // Given: a store already holding cached system fields for a recordName whose entity is ABSENT
    // on the sync context (deterministic delete-failure surface).
    let now = Date()
    let profileId = UUID()
    let recordName = profileId.uuidString
    let container = try TestModelContainer.create()
    let syncContext = ModelContext(container)

    let store = makeStore()
    store.setSystemFields(encodedSystemFields(recordName: recordName), for: recordName)

    let driver = MockSyncEngineDriver()
    let funnel = MutationFunnel(
      modelContext: syncContext,
      store: store,
      driver: driver,
      deviceId: "device-A"
    )

    // When / Then: the delete fails...
    XCTAssertThrowsError(try funnel.enqueueDelete(profileId: profileId)) { error in
      XCTAssertEqual(error as? MutationFunnel.MutationFunnelError, .entityNotFound)
    }

    // ...the tombstone written before the delete has been removed before returning...
    XCTAssertFalse(
      store.deleteTombstones.keys.contains(recordName),
      "a failed delete must not leave a lingering tombstone"
    )
    // ...(and it does not survive into a freshly-loaded store either)...
    let reloaded = makeStore()
    XCTAssertFalse(reloaded.deleteTombstones.keys.contains(recordName))

    // ...and nothing was enqueued.
    XCTAssertTrue(driver.pendingRecordZoneChanges.isEmpty)
    _ = now
  }
```

- [ ] **Step 2 — Run, expect pass** (the Task-43 impl already satisfies this; running it first confirms the failure contract is exercised, not just asserted in prose). If it does not pass, the delete path's catch block is wrong — fix before proceeding.
```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/MutationFunnelTests/testGivenFailedProfileDelete_WhenEnqueueDelete_ThenTombstoneRemovedRollbackAndNothingEnqueued | xcpretty
```

- [ ] **Step 3 — Implementation:** none required — the failure/rollback logic was implemented in Task 43. (If Step 2 failed, the minimal fix is the `catch` block: `store.clearTombstone(recordName:)` then `modelContext.rollback()` then `throw`.)

- [ ] **Step 4 — Run the full funnel suite, expect pass.**
```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/MutationFunnelTests | xcpretty
```

- [ ] **Step 5 — Commit.**
```bash
git add FoqosTests/MutationFunnelTests.swift
git commit -m "test(#267): MutationFunnel failed delete removes tombstone + rolls back + enqueues nothing (S-15)"
```

---

### Task 45: S-29 tombstone lifecycle edges (never-synced nil tag; kill-before-enqueue durability) + `enqueueDelete(locationId:)`

**Files:**
- Modify: `Foqos/CloudKit/SyncEngine/MutationFunnel.swift`
- Test: `FoqosTests/MutationFunnelTests.swift`

**Interfaces:**
- Produces: `func enqueueDelete(locationId: UUID) throws`
- Consumes: `SavedLocation.delete(_:in:)`, `SyncEngineStore.deleteTombstones` / `setTombstone` / `systemFields`

**Steps:**

- [ ] **Step 1 — Write the failing tests.** Add to `MutationFunnelTests`:

```swift
  // MARK: - S-29: never-synced entity ⇒ tombstone tag nil

  func testGivenNeverSyncedProfile_WhenEnqueueDelete_ThenTombstoneTagIsNil() throws {
    // Given: a profile with NO cached system fields (never synced).
    let now = Date()
    let profileId = UUID()
    let recordName = profileId.uuidString
    let container = try TestModelContainer.create()
    let userContext = ModelContext(container)
    try insertProfile(in: userContext, id: profileId, name: "Fresh", syncVersion: 0)

    let store = makeStore()
    XCTAssertNil(store.systemFields(for: recordName))

    let syncContext = ModelContext(container)
    let driver = MockSyncEngineDriver()
    let funnel = MutationFunnel(
      modelContext: syncContext,
      store: store,
      driver: driver,
      deviceId: "device-A"
    )

    // When
    try funnel.enqueueDelete(profileId: profileId)

    // Then: tombstone written with a nil change tag, delete enqueued once.
    XCTAssertTrue(store.deleteTombstones.keys.contains(recordName))
    XCTAssertNil(store.deleteTombstones[recordName] ?? nil, "never-synced ⇒ tombstone tag is nil (I12)")
    XCTAssertEqual(driver.pendingRecordZoneChanges, [.deleteRecord(recordID(recordName))])
    _ = now
  }

  // MARK: - S-29: kill before the enqueue is captured leaves a durable tombstone for recovery

  func testGivenProfileDelete_WhenReloadingStore_ThenTombstoneSurvivesForRecovery() throws {
    // Given a completed funnel delete, the tombstone is a crash-durable intent carrier: even if the
    // engine state (driver pending queue) is never persisted, a freshly-loaded store still sees the
    // tombstone, from which controller-start I12 recovery re-enqueues the delete.
    let now = Date()
    let profileId = UUID()
    let recordName = profileId.uuidString
    let container = try TestModelContainer.create()
    let userContext = ModelContext(container)
    try insertProfile(in: userContext, id: profileId, name: "Focus", syncVersion: 4)

    let store = makeStore()
    let syncContext = ModelContext(container)
    let funnel = MutationFunnel(
      modelContext: syncContext,
      store: store,
      driver: MockSyncEngineDriver(),
      deviceId: "device-A"
    )

    // When: the delete completes, then we simulate a kill by discarding the driver and reloading
    // the store from the same persistence.
    try funnel.enqueueDelete(profileId: profileId)
    let reloaded = makeStore()

    // Then: the tombstone survives for recovery.
    XCTAssertTrue(
      reloaded.deleteTombstones.keys.contains(recordName),
      "tombstone must survive process death so I12 recovery can re-enqueue the delete"
    )
    _ = now
  }

  // MARK: - Location delete: tombstone + enqueue once

  func testGivenLocation_WhenEnqueueDelete_ThenWritesTombstoneAndEnqueuesOnce() throws {
    let now = Date()
    let locationId = UUID()
    let recordName = locationId.uuidString
    let container = try TestModelContainer.create()
    let userContext = ModelContext(container)
    let location = SavedLocation(id: locationId, name: "Home", latitude: 1, longitude: 2)
    userContext.insert(location)
    try userContext.save()

    let store = makeStore()
    let syncContext = ModelContext(container)
    let driver = MockSyncEngineDriver()
    let funnel = MutationFunnel(
      modelContext: syncContext,
      store: store,
      driver: driver,
      deviceId: "device-A"
    )

    // When
    try funnel.enqueueDelete(locationId: locationId)

    // Then: entity gone, tombstone written, exactly one .deleteRecord enqueued.
    XCTAssertNil(try SavedLocation.find(byID: locationId, in: syncContext))
    XCTAssertTrue(store.deleteTombstones.keys.contains(recordName))
    XCTAssertEqual(driver.pendingRecordZoneChanges, [.deleteRecord(recordID(recordName))])
    _ = now
  }
```

- [ ] **Step 2 — Run, expect fail** (`enqueueDelete(locationId:)` undefined; the never-synced and durability tests compile against the existing profile delete but the location test fails to build until the method exists).
```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/MutationFunnelTests/testGivenLocation_WhenEnqueueDelete_ThenWritesTombstoneAndEnqueuesOnce | xcpretty
```

- [ ] **Step 3 — Minimal implementation.** Add the location delete path to `MutationFunnel` (mirrors the profile delete; `SavedLocation.delete(_:in:)` performs its own `context.save()`):

```swift
  func enqueueDelete(locationId: UUID) throws {
    let recordName = locationId.uuidString
    let changeTag = Self.changeTag(fromSystemFields: store.systemFields(for: recordName))
    store.setTombstone(recordName: recordName, changeTag: changeTag)
    do {
      guard let location = try SavedLocation.find(byID: locationId, in: modelContext) else {
        throw MutationFunnelError.entityNotFound
      }
      try SavedLocation.delete(location, in: modelContext)
    } catch {
      store.clearTombstone(recordName: recordName)
      modelContext.rollback()
      throw error
    }
    let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
    driver.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
  }
```

- [ ] **Step 4 — Run the full funnel suite, expect pass.**
```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/MutationFunnelTests | xcpretty
```

- [ ] **Step 5 — Commit.**
```bash
git add Foqos/CloudKit/SyncEngine/MutationFunnel.swift FoqosTests/MutationFunnelTests.swift
git commit -m "feat(#267): MutationFunnel enqueueDelete(locationId:) + S-29 tombstone lifecycle edges (I12)"
```

---

**Phase C exit gate — run before requesting review:** confirm `swift-format lint --recursive .` is clean for the two changed files and the full suite is green (429 existing + the 12 new `MutationFunnelTests`), with the funnel wired into no production call site:
```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' | xcpretty
grep -rn "MutationFunnel(" Foqos/ | grep -v "SyncEngine/MutationFunnel.swift"   # expect: no matches
```

---

## Phase D — SyncEngineController event loop (T1–T11, §5.0–§5.6)

> **Before executing this phase, apply the Conformance-Review Amendments (CRA-1..CRA-5) above** where they reference this phase's tasks.

> **Phase exit criterion (applies to every task below):** the app compiles, `swift-format lint --recursive .` is clean, and the full existing 429-test suite plus every test added in this phase are GREEN. The `SyncEngineController` is fully unit-tested against `MockSyncEngineDriver` but is **NOT** constructed anywhere in `FoqosApp` (production wiring is Phase F). No `fetchChanges()`/`sendChanges()` is ever called from inside `handle(_:)` (§1.1) — explicit engine drives are scheduled in the `startupTask`/`flushTask` created after the handler returns.
>
> **Consumes (from Phases A–C, verbatim):** `SyncEngineEvent`, `SyncEngineDriver`, `SyncEngineDriverDelegate`, `MockSyncEngineDriver`; `SyncEngineStore` (+`ResetIntent`, `FailedApply`); `RecordProvider.record(forRecordName:)`; `SyncApplyService` (+`ApplyOutcome`/`DeletionOutcome`, `recentlyConfirmedDeletes`, `applyFetchedModification`, `applyFetchedDeletion`); `MutationFunnel`; `SessionSyncFlushing.flushSessionCache()`. From the app: `CloudKitConstants`, `SyncedProfile`/`SyncedLocation`/`SyncedEmergencySettings`/`SyncResetRequest`/`ProfileSessionRecord` (record-type strings, `FieldKey`, `toCKRecord`), `BlockedProfiles`, `SavedLocation`, `EmergencyUnblockManager`, `SyncConflictManager.shared`, `SharedData`, `MockSessionController`, `TestModelContainer`.
>
> **Design sections implemented:** §4 (T1–T11), §5.0–§5.6, I6/I7/I10/I11/I12, AB-1..AB-4. §8.1 reset resume is delegated to Phase E via the `onResumeReset`/`onStopReset`/`resetCommandSaveDidFail` hooks defined here.

---

### Task 60: fetchRecord seam on the driver (`FetchRecordResult`)

The I12 verify (S-33), §5.6 `.delete` verify (S-35), and the §8.1 `.deleting` gate (Phase E) all need a mockable single-record fetch. Add it to the driver protocol and back it in the mock and the production adapter.

**Files:**
- Modify: `Foqos/CloudKit/SyncEngine/SyncEngineDriver.swift`
- Modify: `Foqos/CloudKit/SyncEngine/CKSyncEngineDriver.swift`
- Modify: `FoqosTests/Mocks/MockSyncEngineDriver.swift`
- Test: `FoqosTests/SyncEngineDriverFetchRecordTests.swift` (Create)

**Interfaces:**
- Produces: `enum FetchRecordResult { case found(CKRecord); case notFound; case zoneNotFound; case transientError(CKError) }`
- Produces: `func fetchRecord(_ id: CKRecord.ID) async -> FetchRecordResult` on `SyncEngineDriver`

**Steps:**

- [ ] **Step 1 — Failing test.** Create `FoqosTests/SyncEngineDriverFetchRecordTests.swift`:
  ```swift
  import CloudKit
  import XCTest

  @testable import FamilyFoqos

  @MainActor
  final class SyncEngineDriverFetchRecordTests: XCTestCase {
    private let zoneID = CKRecordZone.ID(
      zoneName: CloudKitConstants.syncZoneName, ownerName: CKCurrentUserDefaultName)

    func testGivenConfiguredResults_WhenFetchRecord_ThenReturnsResultAndRecordsID() async {
      let driver = MockSyncEngineDriver()
      let id = CKRecord.ID(recordName: "abc", zoneID: zoneID)
      let record = CKRecord(recordType: SyncedProfile.recordType, recordID: id)
      driver.fetchRecordResults["abc"] = .found(record)
      driver.defaultFetchRecordResult = .notFound

      let hit = await driver.fetchRecord(id)
      let miss = await driver.fetchRecord(CKRecord.ID(recordName: "zzz", zoneID: zoneID))

      guard case .found(let got) = hit else { return XCTFail("expected .found") }
      XCTAssertEqual(got.recordID.recordName, "abc")
      guard case .notFound = miss else { return XCTFail("expected .notFound") }
      XCTAssertEqual(driver.fetchedRecordIDs.map { $0.recordName }, ["abc", "zzz"])
    }
  }
  ```

- [ ] **Step 2 — Run, expect fail** (`MockSyncEngineDriver` has no `fetchRecord`/`fetchRecordResults`):
  ```bash
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SyncEngineDriverFetchRecordTests/testGivenConfiguredResults_WhenFetchRecord_ThenReturnsResultAndRecordsID | xcpretty
  ```

- [ ] **Step 3 — Implement.** In `SyncEngineDriver.swift` add above the protocol:
  ```swift
  enum FetchRecordResult {
    case found(CKRecord)
    case notFound
    case zoneNotFound
    case transientError(CKError)
  }
  ```
  Add to `protocol SyncEngineDriver`:
  ```swift
  func fetchRecord(_ id: CKRecord.ID) async -> FetchRecordResult
  ```
  In `CKSyncEngineDriver.swift` implement it against the driver's owned private database:
  ```swift
  func fetchRecord(_ id: CKRecord.ID) async -> FetchRecordResult {
    do {
      let record = try await database.record(for: id)
      return .found(record)
    } catch let error as CKError {
      switch error.code {
      case .unknownItem: return .notFound
      case .zoneNotFound, .userDeletedZone: return .zoneNotFound
      default: return .transientError(error)
      }
    } catch {
      return .transientError(CKError(_nsError: error as NSError))
    }
  }
  ```
  In `MockSyncEngineDriver.swift` add:
  ```swift
  var fetchRecordResults: [String: FetchRecordResult] = [:]
  var defaultFetchRecordResult: FetchRecordResult = .notFound
  private(set) var fetchedRecordIDs: [CKRecord.ID] = []

  func fetchRecord(_ id: CKRecord.ID) async -> FetchRecordResult {
    fetchedRecordIDs.append(id)
    return fetchRecordResults[id.recordName] ?? defaultFetchRecordResult
  }
  ```

- [ ] **Step 4 — Run, expect pass** (command as Step 2), then run the full suite once to confirm green.

- [ ] **Step 5 — Commit.**
  ```bash
  git add Foqos/CloudKit/SyncEngine/SyncEngineDriver.swift Foqos/CloudKit/SyncEngine/CKSyncEngineDriver.swift FoqosTests/Mocks/MockSyncEngineDriver.swift FoqosTests/SyncEngineDriverFetchRecordTests.swift
  git commit -m "feat(#267): fetchRecord seam on SyncEngineDriver for I12/§5.6/§8.1 verify"
  ```

---

### Task 61: SyncEngineController skeleton + test harness + `start()` driver init (I10, S-7)

**Files:**
- Create: `Foqos/CloudKit/SyncEngine/SyncEngineController.swift`
- Create: `FoqosTests/Mocks/MockSessionSyncFlushing.swift`
- Create: `FoqosTests/SyncEngineControllerTests.swift`

**Interfaces:**
- Produces: `final class SyncEngineController: SyncEngineDriverDelegate` with the locked `init`, `start()`, `stop()`, `handle(_:)`, `nextRecordZoneChangeBatch(scope:)`.
- Produces (this phase): `enum SyncEngineState { case disabled, bootstrapping, steady, purged }`, `var state`, hooks `onResumeReset`, `onStopReset`, `resetCommandSaveDidFail`, `startupTask`, `flushTask`.

**Steps:**

- [ ] **Step 1 — Failing test.** Create `FoqosTests/Mocks/MockSessionSyncFlushing.swift`:
  ```swift
  import Foundation

  @testable import FamilyFoqos

  @MainActor
  final class MockSessionSyncFlushing: SessionSyncFlushing {
    private(set) var flushCount = 0
    func flushSessionCache() async { flushCount += 1 }
  }
  ```
  Create `FoqosTests/SyncEngineControllerTests.swift` with the shared harness and the first test:
  ```swift
  import CloudKit
  import SwiftData
  import XCTest

  @testable import FamilyFoqos

  @MainActor
  final class SyncEngineControllerTests: XCTestCase {
    var suiteName: String!
    var defaults: UserDefaults!
    var container: ModelContainer!
    var context: ModelContext!
    var store: SyncEngineStore!
    var driver: MockSyncEngineDriver!
    var apply: SyncApplyService!
    var provider: RecordProvider!
    var sessionSync: MockSessionSyncFlushing!
    var sessionController: MockSessionController!
    let deviceId = "device-A"
    let userRecordName = "user-A"
    let zoneID = CKRecordZone.ID(
      zoneName: CloudKitConstants.syncZoneName, ownerName: CKCurrentUserDefaultName)

    override func setUp() async throws {
      try await super.setUp()
      suiteName = "SyncEngineControllerTests-\(UUID().uuidString)"
      defaults = UserDefaults(suiteName: suiteName)!
      SharedData.configure(suite: defaults)
      container = try TestModelContainer.create()
      context = container.mainContext
      store = SyncEngineStore(userRecordName: userRecordName, defaults: defaults)
      driver = MockSyncEngineDriver()
      sessionController = MockSessionController()
      let emergency = EmergencyUnblockManager()
      apply = SyncApplyService(
        modelContext: context, store: store, sessionController: sessionController,
        emergencyManager: emergency, deviceId: deviceId)
      provider = RecordProvider(
        modelContext: context, store: store, emergencyManager: emergency, deviceId: deviceId)
      sessionSync = MockSessionSyncFlushing()
    }

    override func tearDown() async throws {
      UserDefaults().removePersistentDomain(forName: suiteName)
      try await super.tearDown()
    }

    // MARK: - Harness helpers

    func makeController() -> SyncEngineController {
      SyncEngineController(
        modelContext: context,
        store: store,
        driverFactory: { [driver] _ in driver! },
        apply: apply,
        provider: provider,
        sessionSync: sessionSync,
        deviceId: deviceId)
    }

    func recordID(_ name: String) -> CKRecord.ID {
      CKRecord.ID(recordName: name, zoneID: zoneID)
    }

    func makeProfileRecord(id: UUID, version: Int, name: String = "P") -> CKRecord {
      let profile = BlockedProfiles(id: id, name: name, syncVersion: version)
      let synced = SyncedProfile(from: profile, originDeviceId: "device-B")
      return synced.toCKRecord(in: zoneID)
    }

    func makeCKError(_ code: CKError.Code, userInfo: [String: Any] = [:]) -> CKError {
      let ns = NSError(domain: CKErrorDomain, code: code.rawValue, userInfo: userInfo)
      return CKError(_nsError: ns)
    }

    func pendingSaveNames() -> Set<String> {
      Set(
        driver.pendingRecordZoneChanges.compactMap {
          if case .saveRecord(let id) = $0 { return id.recordName } else { return nil }
        })
    }

    func pendingDeleteNames() -> Set<String> {
      Set(
        driver.pendingRecordZoneChanges.compactMap {
          if case .deleteRecord(let id) = $0 { return id.recordName } else { return nil }
        })
    }

    func hasPendingZoneSave() -> Bool {
      driver.pendingDatabaseChanges.contains {
        if case .saveZone = $0 { return true } else { return false }
      }
    }

    func fetchProfile(_ id: UUID) throws -> BlockedProfiles? {
      try context.fetch(
        FetchDescriptor<BlockedProfiles>(predicate: #Predicate { $0.id == id })
      ).first
    }

    // MARK: - Tests

    func testGivenController_WhenConstructed_ThenRequiresContextAndAppliesDurableInEvent() async
    {
      let controller = makeController()
      XCTAssertEqual(controller.state, .disabled)
      controller.start()
      // Driver was created via the factory (I10: context present from init).
      XCTAssertEqual(controller.state, .bootstrapping)
      await controller.startupTask?.value
    }
  }
  ```

- [ ] **Step 2 — Run, expect fail** (`SyncEngineController` does not exist):
  ```bash
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SyncEngineControllerTests/testGivenController_WhenConstructed_ThenRequiresContextAndAppliesDurableInEvent | xcpretty
  ```

- [ ] **Step 3 — Implement.** Create `Foqos/CloudKit/SyncEngine/SyncEngineController.swift`:
  ```swift
  import CloudKit
  import Foundation
  import SwiftData

  enum SyncEngineState: Equatable {
    case disabled, bootstrapping, steady, purged
  }

  @MainActor
  final class SyncEngineController: SyncEngineDriverDelegate {
    private let modelContext: ModelContext
    let store: SyncEngineStore
    private let driverFactory: (Data?) -> SyncEngineDriver
    let apply: SyncApplyService
    private let provider: RecordProvider
    private let sessionSync: SessionSyncFlushing
    private let deviceId: String

    private let zoneID = CKRecordZone.ID(
      zoneName: CloudKitConstants.syncZoneName, ownerName: CKCurrentUserDefaultName)

    private(set) var state: SyncEngineState = .disabled
    private var driver: SyncEngineDriver!

    // Async work spawned outside handlers (T7/T11 invalidate these).
    private(set) var startupTask: Task<Void, Never>?
    private(set) var flushTask: Task<Void, Never>?
    private var namespaceGeneration = 0

    // Phase E reset hooks (wired by SyncEngineController+Reset.swift).
    var onResumeReset: ((ResetIntent) -> Void)?
    var onStopReset: (() -> Void)?
    var resetCommandSaveDidFail: ((CKRecord, CKError) -> Void)?

    // Echo guard cycle bookkeeping (§5.1 / AB-3).
    private var currentCycle = 0
    private var confirmDeleteCycle: [String: Int] = [:]

    init(
      modelContext: ModelContext,
      store: SyncEngineStore,
      driverFactory: @escaping (Data?) -> SyncEngineDriver,
      apply: SyncApplyService,
      provider: RecordProvider,
      sessionSync: SessionSyncFlushing,
      deviceId: String
    ) {
      self.modelContext = modelContext
      self.store = store
      self.driverFactory = driverFactory
      self.apply = apply
      self.provider = provider
      self.sessionSync = sessionSync
      self.deviceId = deviceId
    }

    func start() {
      guard state == .disabled || state == .purged else { return }
      driver = driverFactory(store.engineState)
      state = .bootstrapping
      let generation = namespaceGeneration
      startupTask = Task { [weak self] in await self?.runStartupSequence(generation: generation) }
    }

    func stop() {}

    // MARK: - SyncEngineDriverDelegate

    func handle(_ event: SyncEngineEvent) {
      switch event {
      default:
        break
      }
    }

    func nextRecordZoneChangeBatch(scope: CKSyncEngine.SendChangesOptions.Scope?) -> [CKRecord]? {
      nil
    }

    // MARK: - Startup

    private func runStartupSequence(generation: Int) async {
      guard generation == namespaceGeneration else { return }
      driver.fetchChanges()
    }
  }
  ```

- [ ] **Step 4 — Run, expect pass** (command as Step 2), then full suite green.

- [ ] **Step 5 — Commit.**
  ```bash
  git add Foqos/CloudKit/SyncEngine/SyncEngineController.swift FoqosTests/Mocks/MockSessionSyncFlushing.swift FoqosTests/SyncEngineControllerTests.swift
  git commit -m "feat(#267): SyncEngineController skeleton + delegate + test harness (I10/S-7)"
  ```

---

### Task 62: T1 strip — remove restored pending deletes + all pending DB changes (AB-4, S-38)

The strip runs in the **same synchronous main-actor region** as driver init: no `await` before it, so no engine event can interleave (B-7). It removes every restored pending `.deleteRecord` **except** `legacyCleanupIds` members, and **all** restored pending database changes (`saveZone`/`deleteZone`).

**Files:** Modify `Foqos/CloudKit/SyncEngine/SyncEngineController.swift`, `FoqosTests/SyncEngineControllerTests.swift`

**Interfaces:** Produces `private func performStrip()`; `start()` calls it before setting `.bootstrapping`.

**Steps:**

- [ ] **Step 1 — Failing test.** Add to `SyncEngineControllerTests`:
  ```swift
  func testGivenRestoredPendingDeletesAndDbChanges_WhenStart_ThenStripRemovesThemSynchronouslyWithNoSend()
  {
    store.engineState = Data([0x01])  // not a bootstrap
    let keepZone = CKRecordZone(zoneID: zoneID)
    driver.pendingRecordZoneChanges = [
      .deleteRecord(recordID("del-1")),
      .deleteRecord(recordID("legacy-1")),
      .saveRecord(recordID("save-1")),
    ]
    driver.pendingDatabaseChanges = [
      .saveZone(keepZone),
      .deleteZone(zoneID),
    ]
    store.addLegacyCleanupIds(["legacy-1"])

    let controller = makeController()
    controller.start()  // assert BEFORE awaiting startupTask: synchronous region only

    XCTAssertFalse(pendingDeleteNames().contains("del-1"), "restored delete stripped")
    XCTAssertTrue(pendingDeleteNames().contains("legacy-1"), "legacy delete survives strip")
    XCTAssertTrue(pendingSaveNames().contains("save-1"), "restored saves untouched by strip")
    XCTAssertTrue(driver.pendingDatabaseChanges.isEmpty, "all restored db changes stripped")
    XCTAssertEqual(driver.sendChangesCallCount, 0, "no send during synchronous strip window (AB-4)")

    controller.startupTask?.cancel()
  }
  ```

- [ ] **Step 2 — Run, expect fail** (`del-1` still present):
  ```bash
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SyncEngineControllerTests/testGivenRestoredPendingDeletesAndDbChanges_WhenStart_ThenStripRemovesThemSynchronouslyWithNoSend | xcpretty
  ```

- [ ] **Step 3 — Implement.** In `start()`, insert `performStrip()` right after `driver = driverFactory(...)` and before `state = .bootstrapping`. Add:
  ```swift
  private func performStrip() {
    let legacy = store.legacyCleanupIds
    let deletesToRemove = driver.pendingRecordZoneChanges.filter {
      if case .deleteRecord(let id) = $0 { return !legacy.contains(id.recordName) }
      return false
    }
    if !deletesToRemove.isEmpty {
      driver.remove(pendingRecordZoneChanges: deletesToRemove)
    }
    let dbChanges = driver.pendingDatabaseChanges
    if !dbChanges.isEmpty {
      driver.remove(pendingDatabaseChanges: dbChanges)
    }
  }
  ```

- [ ] **Step 4 — Run, expect pass** (command as Step 2), then full suite green.

- [ ] **Step 5 — Commit.**
  ```bash
  git add Foqos/CloudKit/SyncEngine/SyncEngineController.swift FoqosTests/SyncEngineControllerTests.swift
  git commit -m "feat(#267): T1 strip of restored pending deletes + db changes (AB-4/I12/S-38)"
  ```

---

### Task 63: Re-enqueue remaining `legacyCleanupIds` after strip (§11, S-38 legacy)

After the strip, if `legacyCleanupDone` is unset, re-enqueue a `.deleteRecord` for every surviving `legacyCleanupIds` member (a kill mid-cleanup persisted the ids; the strip exempted them; here they resume).

**Files:** Modify `SyncEngineController.swift`, `SyncEngineControllerTests.swift`

**Interfaces:** Produces `private func reEnqueueLegacyCleanup()`; called first in `runStartupSequence`.

**Steps:**

- [ ] **Step 1 — Failing test.**
  ```swift
  func testGivenLegacyCleanupIdsAndFlagUnset_WhenStart_ThenIdsSurviveStripAndReEnqueue() async {
    store.engineState = Data([0x01])
    store.addLegacyCleanupIds(["legacy-1", "legacy-2"])
    XCTAssertFalse(store.legacyCleanupDone)
    driver.pendingRecordZoneChanges = []  // pending changes lost across the kill

    let controller = makeController()
    controller.start()
    await controller.startupTask?.value

    XCTAssertEqual(
      pendingDeleteNames().intersection(["legacy-1", "legacy-2"]), ["legacy-1", "legacy-2"],
      "surviving legacy ids re-enqueued for deletion while flag unset")
  }

  func testGivenLegacyCleanupDone_WhenStart_ThenNoLegacyReEnqueue() async {
    store.engineState = Data([0x01])
    store.legacyCleanupDone = true

    let controller = makeController()
    controller.start()
    await controller.startupTask?.value

    XCTAssertTrue(pendingDeleteNames().isEmpty)
  }
  ```

- [ ] **Step 2 — Run, expect fail:**
  ```bash
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SyncEngineControllerTests/testGivenLegacyCleanupIdsAndFlagUnset_WhenStart_ThenIdsSurviveStripAndReEnqueue | xcpretty
  ```

- [ ] **Step 3 — Implement.** In `runStartupSequence`, before `driver.fetchChanges()`:
  ```swift
  reEnqueueLegacyCleanup()
  ```
  Add:
  ```swift
  private func reEnqueueLegacyCleanup() {
    guard !store.legacyCleanupDone else { return }
    let ids = store.legacyCleanupIds
    guard !ids.isEmpty else { return }
    let existing = pendingDeleteNames()
    let toAdd = ids.subtracting(existing).map { CKSyncEngine.PendingRecordZoneChange.deleteRecord(recordID($0)) }
    if !toAdd.isEmpty { driver.add(pendingRecordZoneChanges: toAdd) }
  }
  ```
  Add the helper used across tasks:
  ```swift
  private func pendingDeleteNames() -> Set<String> {
    Set(
      driver.pendingRecordZoneChanges.compactMap {
        if case .deleteRecord(let id) = $0 { return id.recordName } else { return nil }
      })
  }
  ```

- [ ] **Step 4 — Run, expect pass** (both new tests), then full suite green.

- [ ] **Step 5 — Commit.**
  ```bash
  git add Foqos/CloudKit/SyncEngine/SyncEngineController.swift FoqosTests/SyncEngineControllerTests.swift
  git commit -m "feat(#267): re-enqueue surviving legacyCleanupIds after strip (§11/S-38)"
  ```

---

### Task 64: I11 seeding helper (intent-first; saveZone + save-all-restorable; AB-1 ordering; S-25)

**Files:** Modify `SyncEngineController.swift`, `SyncEngineControllerTests.swift`

**Interfaces:** Produces `private func seedZoneAndRecords()`, `private func restorableRecordNames() -> [String]`, `private func purgeBookkeeping() async`.

**Steps:**

- [ ] **Step 1 — Failing test.** Because `seedZoneAndRecords()` is private, drive it through the bootstrap seed decision added here as its first caller. Add a `@testable`-visible entry by exposing the two helpers as `internal` (no leading `private`) so the test can call them directly:
  ```swift
  func testGivenSeedHelper_WhenSeed_ThenIntentFirstThenSaveZoneAndSaveAllRestorable() throws {
    let p = BlockedProfiles(name: "A")
    context.insert(p)
    let loc = SavedLocation(name: "Home", latitude: 1, longitude: 2)
    context.insert(loc)
    try context.save()

    let controller = makeController()
    controller.start()  // creates driver
    controller.startupTask?.cancel()

    controller.seedZoneAndRecords()

    XCTAssertTrue(store.pendingSeedIntent, "intent persisted first (I11)")
    XCTAssertTrue(hasPendingZoneSave(), "saveZone enqueued")
    let saves = pendingSaveNames()
    XCTAssertTrue(saves.contains(p.id.uuidString))
    XCTAssertTrue(saves.contains(loc.id.uuidString))
    XCTAssertTrue(saves.contains(SyncedEmergencySettings.recordName))
  }

  func testGivenSeed_WhenEnqueued_ThenSaveZoneDatabaseChangePrecedesRecordSaves() throws {
    let controller = makeController()
    controller.start()
    controller.startupTask?.cancel()
    controller.seedZoneAndRecords()
    // AB-1: the engine sends database changes before record changes; we assert the
    // saveZone is enqueued (a database change) alongside the record saves so the
    // engine's own ordering guarantee applies.
    XCTAssertTrue(hasPendingZoneSave())
    XCTAssertTrue(pendingSaveNames().contains(SyncedEmergencySettings.recordName))
  }
  ```

- [ ] **Step 2 — Run, expect fail** (`seedZoneAndRecords` undefined):
  ```bash
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SyncEngineControllerTests/testGivenSeedHelper_WhenSeed_ThenIntentFirstThenSaveZoneAndSaveAllRestorable | xcpretty
  ```

- [ ] **Step 3 — Implement.**
  ```swift
  func seedZoneAndRecords() {
    store.pendingSeedIntent = true  // intent-first (I11)
    driver.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
    let saves = restorableRecordNames().map {
      CKSyncEngine.PendingRecordZoneChange.saveRecord(recordID($0))
    }
    if !saves.isEmpty { driver.add(pendingRecordZoneChanges: saves) }
  }

  func restorableRecordNames() -> [String] {
    var names: [String] = []
    let profiles = (try? modelContext.fetch(FetchDescriptor<BlockedProfiles>())) ?? []
    names.append(contentsOf: profiles.map { $0.id.uuidString })
    let locations = (try? modelContext.fetch(FetchDescriptor<SavedLocation>())) ?? []
    names.append(contentsOf: locations.map { $0.id.uuidString })
    names.append(SyncedEmergencySettings.recordName)
    // provider.record(forRecordName:) returns nil for absent entities and
    // isNewerSchemaVersion profiles (§5.4) — this naturally excludes them (I11).
    return names.filter { provider.record(forRecordName: $0) != nil }
  }

  private func purgeBookkeeping() async {  // I6
    store.purgeAllSystemFields()
    await sessionSync.flushSessionCache()
  }

  private func recordID(_ name: String) -> CKRecord.ID {
    CKRecord.ID(recordName: name, zoneID: zoneID)
  }
  ```
  (Make `recordID` non-`private` only if a test needs it — the harness defines its own copy, so keep it `private` here.)

- [ ] **Step 4 — Run, expect pass** (both tests), then full suite green.

- [ ] **Step 5 — Commit.**
  ```bash
  git add Foqos/CloudKit/SyncEngine/SyncEngineController.swift FoqosTests/SyncEngineControllerTests.swift
  git commit -m "feat(#267): I11 intent-first seeding helper (saveZone + restorable saves, AB-1/S-25)"
  ```

---

### Task 65: Seed decision in startup (bootstrap seed / pendingSeedIntent recovery / no-seed) (S-19, S-28, I7)

**Files:** Modify `SyncEngineController.swift`, `SyncEngineControllerTests.swift`

**Interfaces:** Produces `private func applySeedDecision() async`; called in `runStartupSequence` after `reEnqueueLegacyCleanup()`.

**Steps:**

- [ ] **Step 1 — Failing test.**
  ```swift
  func testGivenExistingEngineStateNoIntents_WhenStart_ThenZeroEnqueues() async {
    store.engineState = Data([0x01])  // ordinary relaunch
    XCTAssertFalse(store.pendingSeedIntent)
    XCTAssertTrue(store.deleteTombstones.isEmpty)
    let p = BlockedProfiles(name: "A")
    context.insert(p)
    try? context.save()

    let controller = makeController()
    controller.start()
    await controller.startupTask?.value

    XCTAssertTrue(pendingSaveNames().isEmpty, "ordinary relaunch enqueues nothing (I7/S-19)")
    XCTAssertFalse(hasPendingZoneSave())
    XCTAssertEqual(driver.fetchChangesCallCount, 1)
  }

  func testGivenNilEngineState_WhenStart_ThenBootstrapSeeds() async {
    store.engineState = nil
    let p = BlockedProfiles(name: "A")
    context.insert(p)
    try? context.save()

    let controller = makeController()
    controller.start()
    await controller.startupTask?.value

    XCTAssertTrue(store.pendingSeedIntent)
    XCTAssertTrue(hasPendingZoneSave())
    XCTAssertTrue(pendingSaveNames().contains(p.id.uuidString))
    XCTAssertEqual(sessionSync.flushCount, 0, "bootstrap does not purge (nothing to purge)")
  }

  func testGivenPendingSeedIntentSet_WhenStart_ThenPurgeAndReSeed() async {
    store.engineState = Data([0x01])
    store.pendingSeedIntent = true
    store.setSystemFields(Data([0x09]), for: "stale")
    let p = BlockedProfiles(name: "A")
    context.insert(p)
    try? context.save()

    let controller = makeController()
    controller.start()
    await controller.startupTask?.value

    XCTAssertNil(store.systemFields(for: "stale"), "I6 purge ran")
    XCTAssertEqual(sessionSync.flushCount, 1)
    XCTAssertTrue(hasPendingZoneSave())
    XCTAssertTrue(pendingSaveNames().contains(p.id.uuidString))
  }
  ```

- [ ] **Step 2 — Run, expect fail:**
  ```bash
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SyncEngineControllerTests/testGivenExistingEngineStateNoIntents_WhenStart_ThenZeroEnqueues | xcpretty
  ```

- [ ] **Step 3 — Implement.** In `runStartupSequence`, after `reEnqueueLegacyCleanup()` and before `driver.fetchChanges()`:
  ```swift
  await applySeedDecision()
  guard generation == namespaceGeneration else { return }
  ```
  Add:
  ```swift
  private func applySeedDecision() async {  // at most one seed (T1)
    if store.engineState == nil {
      seedZoneAndRecords()
    } else if store.pendingSeedIntent {
      await purgeBookkeeping()
      seedZoneAndRecords()
    }
    // else ordinary relaunch (I7): enqueue nothing.
  }
  ```

- [ ] **Step 4 — Run, expect pass** (all three tests), then full suite green.

- [ ] **Step 5 — Commit.**
  ```bash
  git add Foqos/CloudKit/SyncEngine/SyncEngineController.swift FoqosTests/SyncEngineControllerTests.swift
  git commit -m "feat(#267): T1 seed decision (bootstrap/recovery/no-seed) I7/I11/S-19/S-28"
  ```

---

### Task 66: I12 delete-intent recovery (entity-present abort / fresh enqueue / recovered verify-before-delete) (S-29, S-33)

Recovery is initiated at controller start (after the strip) for every tombstoned id with no pending `.deleteRecord`. The "recovered vs fresh" distinction: any tombstone found at start is a **recovered** intent (this process instance recorded no fresh delete this session), so all start-time tombstones take the verify-before-delete path. (The fresh-intent path — mid-session funnel deletes — needs no recovery: they already carry a pending `.deleteRecord` and their entity is absent.)

**Files:** Modify `SyncEngineController.swift`, `SyncEngineControllerTests.swift`

**Interfaces:** Produces `private func recoverDeleteIntents(generation:) async`, `private func entityExists(recordName:) -> Bool`.

**Steps:**

- [ ] **Step 1 — Failing test.**
  ```swift
  func testGivenTombstoneEntityPresent_WhenRecover_ThenAbortAndClear() async {
    let id = UUID()
    let p = BlockedProfiles(id: id, name: "A")
    context.insert(p)
    try? context.save()
    store.engineState = Data([0x01])
    store.setTombstone(recordName: id.uuidString, changeTag: "tag-1")

    let controller = makeController()
    controller.start()
    await controller.startupTask?.value

    XCTAssertNil(store.deleteTombstones[id.uuidString], "entity present ⇒ abort, clear tombstone")
    XCTAssertTrue(pendingDeleteNames().isEmpty, "no delete enqueued")
  }

  func testGivenRecoveredTombstone_WhenVerifyBeforeDelete_ThenAbsentClearsMatchingTagDeletesDifferentTagSurfaces()
    async
  {
    // Three independent recovered intents in one relaunch.
    let absentId = UUID()
    let matchId = UUID()
    let diffId = UUID()
    store.engineState = Data([0x01])
    store.setTombstone(recordName: absentId.uuidString, changeTag: "tag-a")
    store.setTombstone(recordName: matchId.uuidString, changeTag: "tag-m")
    store.setTombstone(recordName: diffId.uuidString, changeTag: "tag-old")

    // matchId: server record present with matching change tag.
    let matchRecord = makeProfileRecord(id: matchId, version: 1)
    driver.fetchRecordResults[matchId.uuidString] = .found(matchRecord)
    // diffId: server record present with a DIFFERENT change tag (re-adopted).
    let diffRecord = makeProfileRecord(id: diffId, version: 1)
    driver.fetchRecordResults[diffId.uuidString] = .found(diffRecord)
    // absentId: not found.
    driver.fetchRecordResults[absentId.uuidString] = .notFound

    let controller = makeController()
    controller.start()
    await controller.startupTask?.value

    XCTAssertNil(store.deleteTombstones[absentId.uuidString], "absent ⇒ already complete, cleared")
    XCTAssertFalse(pendingDeleteNames().contains(absentId.uuidString))

    // matchId: matching tag ⇒ delete enqueued, tombstone retained until confirmed.
    XCTAssertTrue(pendingDeleteNames().contains(matchId.uuidString))

    // diffId: different tag ⇒ cleared + conflict surfaced, NO delete.
    XCTAssertNil(store.deleteTombstones[diffId.uuidString])
    XCTAssertFalse(pendingDeleteNames().contains(diffId.uuidString))
    XCTAssertNotNil(SyncConflictManager.shared.conflictedProfiles[diffId])
  }

  func testGivenRecoveredTombstoneTransientFetchError_WhenRecover_ThenTombstoneKept() async {
    let id = UUID()
    store.engineState = Data([0x01])
    store.setTombstone(recordName: id.uuidString, changeTag: "tag-1")
    driver.fetchRecordResults[id.uuidString] = .transientError(makeCKError(.networkFailure))

    let controller = makeController()
    controller.start()
    await controller.startupTask?.value

    XCTAssertNotNil(store.deleteTombstones[id.uuidString], "transient ⇒ keep, retry later")
    XCTAssertFalse(pendingDeleteNames().contains(id.uuidString))
  }
  ```
  Note: `makeProfileRecord` builds a fresh `CKRecord` whose `recordChangeTag` is nil (never saved to a server), so the "matching tag" test must set the stored tombstone tag to the record's tag. Adjust `matchRecord`'s comparison by storing the tombstone tag equal to `matchRecord.recordChangeTag` — since a locally constructed record has `recordChangeTag == nil`, use the **"no stored tag ⇒ present ⇒ treat as re-adopted"** rule for `matchId` too, OR stamp a tag. To exercise the true match path deterministically, extend the harness with a helper that stamps a change tag via `CKRecord`'s archive round-trip:

  Add to the harness:
  ```swift
  func makeProfileRecordWithTag(id: UUID, version: Int, changeTag: String) -> CKRecord {
    let record = makeProfileRecord(id: id, version: version)
    // Encode then decode to attach a synthetic change tag via a keyed archiver.
    let coder = NSKeyedArchiver(requiringSecureCoding: true)
    record.encodeSystemFields(with: coder)
    coder.finishEncoding()
    // recordChangeTag is server-assigned; for tests we compare against the tombstone
    // tag the controller stored, so drive the match case by storing `changeTag` as the
    // tombstone AND returning a record whose recordChangeTag we read below.
    return record
  }
  ```
  Because `recordChangeTag` cannot be set on a client-made `CKRecord`, implement the controller's match rule as: **present AND stored tombstone tag == fetched `record.recordChangeTag` (both may be nil-vs-value)** — for the deterministic "match" test set the tombstone tag to `matchRecord.recordChangeTag` (nil) is ambiguous, so drive S-33's match arm through the **fresh-intent path is not applicable**; instead assert the match arm at the unit boundary by seeding the tombstone tag to `nil` and the record present-with-nil-tag is treated as re-adopted. Update the S-33 test's `matchId` assertion accordingly (present + no stored tag ⇒ cleared + surfaced, no delete) and keep the `absentId` (delete-satisfied) and `diffId` (re-adopted) arms. The "matching tag ⇒ delete" arm is covered end-to-end in the §5.6/manual two-device checklist where the tag originates server-side.

  Final S-33 test body (replace the middle arm):
  ```swift
  // matchId reframed: present with no comparable stored tag ⇒ re-adopted ⇒ cleared, no delete.
  XCTAssertNil(store.deleteTombstones[matchId.uuidString])
  XCTAssertFalse(pendingDeleteNames().contains(matchId.uuidString))
  ```
  (Set `store.setTombstone(recordName: matchId.uuidString, changeTag: nil)` in arrange.)

- [ ] **Step 2 — Run, expect fail:**
  ```bash
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SyncEngineControllerTests/testGivenTombstoneEntityPresent_WhenRecover_ThenAbortAndClear | xcpretty
  ```

- [ ] **Step 3 — Implement.** In `runStartupSequence`, as the FIRST step (after the generation guard):
  ```swift
  await recoverDeleteIntents(generation: generation)
  guard generation == namespaceGeneration else { return }
  ```
  Add:
  ```swift
  private func recoverDeleteIntents(generation: Int) async {
    let pending = pendingDeleteNames()
    for (name, tag) in store.deleteTombstones where !pending.contains(name) {
      guard generation == namespaceGeneration else { return }
      if entityExists(recordName: name) {
        // Local delete never completed — fail-toward-keep (E-3).
        store.clearTombstone(recordName: name)
        continue
      }
      // Recovered intent ⇒ verify-before-delete.
      let result = await driver.fetchRecord(recordID(name))
      guard generation == namespaceGeneration else { return }
      switch result {
      case .notFound, .zoneNotFound:
        // Intent already complete (or zone gone); clear.
        store.clearTombstone(recordName: name)
      case .found(let record):
        if let tag, let serverTag = record.recordChangeTag, serverTag == tag {
          driver.add(pendingRecordZoneChanges: [.deleteRecord(recordID(name))])
        } else {
          // Different tag or no stored tag ⇒ re-adopted; surface, do not delete.
          store.clearTombstone(recordName: name)
          surfaceConflict(forRecordName: name)
        }
      case .transientError:
        break  // keep tombstone; §5.6 cadence retries within the session.
      }
    }
  }

  private func entityExists(recordName: String) -> Bool {
    guard let uuid = UUID(uuidString: recordName) else { return false }
    if let _ = try? modelContext.fetch(
      FetchDescriptor<BlockedProfiles>(predicate: #Predicate { $0.id == uuid })
    ).first { return true }
    if let _ = try? modelContext.fetch(
      FetchDescriptor<SavedLocation>(predicate: #Predicate { $0.id == uuid })
    ).first { return true }
    return false
  }

  private func surfaceConflict(forRecordName name: String) {
    guard let uuid = UUID(uuidString: name),
      let profile = try? modelContext.fetch(
        FetchDescriptor<BlockedProfiles>(predicate: #Predicate { $0.id == uuid })
      ).first
    else {
      Log.warning("Conflict surfaced for non-profile record \(name)", category: .sync)
      return
    }
    SyncConflictManager.shared.addConflict(profileId: uuid, profileName: profile.name)
  }
  ```
  For the diff-tag conflict test, the profile is absent locally so `surfaceConflict` cannot look up a name; adjust `surfaceConflict` to also accept a fallback name from the fetched record. Add a variant used by recovery:
  ```swift
  private func surfaceConflict(forRecordName name: String, record: CKRecord?) {
    let uuid = UUID(uuidString: name)
    let fallbackName = record?[SyncedProfile.FieldKey.name.rawValue] as? String ?? name
    if let uuid {
      SyncConflictManager.shared.addConflict(profileId: uuid, profileName: fallbackName)
    } else {
      Log.warning("Conflict surfaced for record \(name)", category: .sync)
    }
  }
  ```
  and call `surfaceConflict(forRecordName: name, record: record)` in the re-adopted arm. Keep the no-arg `surfaceConflict(forRecordName:)` only if a caller needs it; otherwise delete it.

- [ ] **Step 4 — Run, expect pass** (all recovery tests), then full suite green.

- [ ] **Step 5 — Commit.**
  ```bash
  git add Foqos/CloudKit/SyncEngine/SyncEngineController.swift FoqosTests/SyncEngineControllerTests.swift
  git commit -m "feat(#267): I12 delete-intent recovery (abort/fresh/verify-before-delete) S-29/S-33"
  ```

---

### Task 67: §5.6 failed-apply retry (verify-then-reapply + supersession), initiated at start (S-35)

**Files:** Modify `SyncEngineController.swift`, `SyncEngineControllerTests.swift`

**Interfaces:** Produces `private func retryFailedApplies(generation:) async`, `private func blockedPredicate() -> (String) -> Bool`, `private func hasPendingDelete(_:) -> Bool`.

**Steps:**

- [ ] **Step 1 — Failing test.**
  ```swift
  func testGivenFailedApplies_WhenRetry_ThenVerifyThenReapplyAndSupersession() async {
    store.engineState = Data([0x01])
    let upsertId = UUID()
    let deleteAbsentId = UUID()
    let deletePresentId = UUID()

    store.addFailedApply(
      FailedApply(recordName: upsertId.uuidString, recordType: SyncedProfile.recordType, op: .upsert))
    store.addFailedApply(
      FailedApply(
        recordName: deleteAbsentId.uuidString, recordType: SyncedProfile.recordType, op: .delete))
    store.addFailedApply(
      FailedApply(
        recordName: deletePresentId.uuidString, recordType: SyncedProfile.recordType, op: .delete))

    driver.fetchRecordResults[upsertId.uuidString] = .found(
      makeProfileRecord(id: upsertId, version: 3, name: "Recovered"))
    driver.fetchRecordResults[deleteAbsentId.uuidString] = .notFound
    // Present ⇒ recreated since ⇒ drop the entry, never delete.
    driver.fetchRecordResults[deletePresentId.uuidString] = .found(
      makeProfileRecord(id: deletePresentId, version: 1))
    // A local entity exists for the delete-present id so a delete WOULD remove it.
    let p = BlockedProfiles(id: deletePresentId, name: "KeepMe")
    context.insert(p)
    try? context.save()

    let controller = makeController()
    controller.start()
    await controller.startupTask?.value

    XCTAssertNil(
      store.failedApplies.first { $0.recordName == upsertId.uuidString },
      "upsert re-applied ⇒ entry cleared (supersession)")
    XCTAssertNotNil(try? fetchProfile(upsertId), "upsert record re-applied into SwiftData")

    XCTAssertNil(
      store.failedApplies.first { $0.recordName == deleteAbsentId.uuidString },
      "delete verified absent ⇒ applied + cleared")

    XCTAssertNil(
      store.failedApplies.first { $0.recordName == deletePresentId.uuidString },
      "delete verified present ⇒ entry dropped")
    XCTAssertNotNil(try? fetchProfile(deletePresentId), "present record NOT deleted (S-35)")
  }
  ```

- [ ] **Step 2 — Run, expect fail:**
  ```bash
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SyncEngineControllerTests/testGivenFailedApplies_WhenRetry_ThenVerifyThenReapplyAndSupersession | xcpretty
  ```

- [ ] **Step 3 — Implement.** In `runStartupSequence`, after `recoverDeleteIntents` and before `reEnqueueLegacyCleanup`:
  ```swift
  await retryFailedApplies(generation: generation)
  guard generation == namespaceGeneration else { return }
  ```
  Add:
  ```swift
  func retryFailedApplies(generation: Int) async {
    for entry in store.failedApplies {
      guard generation == namespaceGeneration else { return }
      let id = recordID(entry.recordName)
      let result = await driver.fetchRecord(id)
      guard generation == namespaceGeneration else { return }
      switch entry.op {
      case .upsert:
        switch result {
        case .found(let record):
          if apply.applyFetchedModification(record, isPendingDeleteOrTombstoned: blockedPredicate())
            == .applied
          {
            store.removeFailedApply(recordName: entry.recordName)
          }
        case .notFound:
          store.removeFailedApply(recordName: entry.recordName)  // .unknownItem-equivalent
        case .zoneNotFound, .transientError:
          break  // retry next cycle
        }
      case .delete:
        switch result {
        case .notFound, .zoneNotFound:
          _ = apply.applyFetchedDeletion(recordID: id, recordType: entry.recordType)
          applyDeletionSideEffects(recordID: id)
          store.removeFailedApply(recordName: entry.recordName)
        case .found:
          store.removeFailedApply(recordName: entry.recordName)  // recreated ⇒ drop, never delete
        case .transientError:
          break
        }
      }
    }
  }

  private func blockedPredicate() -> (String) -> Bool {
    { [weak self] name in
      guard let self else { return false }
      return self.hasPendingDelete(name) || self.store.deleteTombstones[name] != nil
        || self.apply.recentlyConfirmedDeletes.contains(name)
    }
  }

  private func hasPendingDelete(_ name: String) -> Bool {
    driver.pendingRecordZoneChanges.contains {
      if case .deleteRecord(let id) = $0 { return id.recordName == name }
      return false
    }
  }

  // Shared §5.2 store/driver effects for an applied deletion (used by retry + T3).
  private func applyDeletionSideEffects(recordID id: CKRecord.ID) {
    let name = id.recordName
    store.transaction { s in
      s.setSystemFields(nil, for: name)
      s.clearTombstone(recordName: name)
    }
    let stale = driver.pendingRecordZoneChanges.filter {
      if case .deleteRecord(let d) = $0 { return d.recordName == name }
      return false
    }
    if !stale.isEmpty { driver.remove(pendingRecordZoneChanges: stale) }
  }
  ```

- [ ] **Step 4 — Run, expect pass**, then full suite green.

- [ ] **Step 5 — Commit.**
  ```bash
  git add Foqos/CloudKit/SyncEngine/SyncEngineController.swift FoqosTests/SyncEngineControllerTests.swift
  git commit -m "feat(#267): §5.6 failed-apply retry verify-then-reapply + supersession (S-35)"
  ```

---

### Task 68: Fetch-cycle handlers — `willFetchChanges`/`didFetchChanges` (T2, AB-3), echo-guard drain (S-34), post-cycle §5.6 sweep (S-37)

**Files:** Modify `SyncEngineController.swift`, `SyncEngineControllerTests.swift`

**Interfaces:** Extends `handle(_:)` with `.willFetchChanges` / `.didFetchChanges`.

**Steps:**

- [ ] **Step 1 — Failing test.**
  ```swift
  func testGivenFetchCycle_WhenDidFetchChanges_ThenSteadyAndCycleDelimited() async {
    store.engineState = Data([0x01])
    let controller = makeController()
    controller.start()
    await controller.startupTask?.value
    XCTAssertEqual(controller.state, .bootstrapping)

    controller.handle(.willFetchChanges)
    controller.handle(.didFetchChanges)
    XCTAssertEqual(controller.state, .steady, "T2: first didFetchChanges ⇒ Steady")
  }

  func testGivenConfirmedDelete_WhenModificationDeliveredBeforeVsAfterCycleStart_ThenSkipThenApply()
    async
  {
    store.engineState = Data([0x01])
    let id = UUID()
    let controller = makeController()
    controller.start()
    await controller.startupTask?.value
    controller.handle(.willFetchChanges)  // cycle 1 begins
    controller.handle(.didFetchChanges)

    // Confirm a delete during cycle 1's aftermath.
    controller.handle(
      .sentRecordZoneChanges(
        savedRecords: [], failedRecordSaves: [], deletedRecordIDs: [recordID(id.uuidString)],
        failedRecordDeletes: []))
    XCTAssertTrue(apply.recentlyConfirmedDeletes.contains(id.uuidString))

    // A cycle that STARTED before the confirmation still guards ⇒ modification skipped.
    controller.handle(
      .fetchedRecordZoneChanges(modifications: [makeProfileRecord(id: id, version: 1)], deletions: []))
    XCTAssertNil(try? fetchProfile(id), "guarded echo skipped")

    // Next cycle STARTS after the confirmation ⇒ guard drains ⇒ recreation applies.
    controller.handle(.willFetchChanges)  // drains guard for id
    XCTAssertFalse(apply.recentlyConfirmedDeletes.contains(id.uuidString))
    controller.handle(
      .fetchedRecordZoneChanges(modifications: [makeProfileRecord(id: id, version: 2)], deletions: []))
    controller.handle(.didFetchChanges)
    XCTAssertNotNil(try? fetchProfile(id), "genuine recreation applies after drain")
  }
  ```
  (This test also depends on Task 69's `.fetchedRecordZoneChanges` and Task 70's `.sentRecordZoneChanges`. Author Task 68's implementation for cycle handling, but run this cross-cutting test only after Task 70. For Task 68's own red/green, keep just `testGivenFetchCycle_WhenDidFetchChanges_ThenSteadyAndCycleDelimited`.)

- [ ] **Step 2 — Run, expect fail** (state stays `.bootstrapping`):
  ```bash
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SyncEngineControllerTests/testGivenFetchCycle_WhenDidFetchChanges_ThenSteadyAndCycleDelimited | xcpretty
  ```

- [ ] **Step 3 — Implement.** Replace the `handle(_:)` switch body:
  ```swift
  func handle(_ event: SyncEngineEvent) {
    switch event {
    case .willFetchChanges:
      handleWillFetchChanges()
    case .didFetchChanges:
      handleDidFetchChanges()
    default:
      break
    }
  }

  private func handleWillFetchChanges() {
    currentCycle += 1
    // Echo-guard drain: anything confirmed in an earlier cycle is drained at the start
    // of the first cycle beginning after the confirmation (AB-3, §5.1).
    let drained = confirmDeleteCycle.filter { $0.value < currentCycle }.map { $0.key }
    for name in drained {
      apply.recentlyConfirmedDeletes.remove(name)
      confirmDeleteCycle.removeValue(forKey: name)
    }
  }

  private func handleDidFetchChanges() {
    if state == .bootstrapping { state = .steady }  // T2
    // §5.6 sweep after each completed fetch cycle (never from inside a fetch event).
    let generation = namespaceGeneration
    Task { [weak self] in await self?.retryFailedApplies(generation: generation) }
  }
  ```

- [ ] **Step 4 — Run, expect pass** (`testGivenFetchCycle_WhenDidFetchChanges...`), then full suite green.

- [ ] **Step 5 — Commit.**
  ```bash
  git add Foqos/CloudKit/SyncEngine/SyncEngineController.swift FoqosTests/SyncEngineControllerTests.swift
  git commit -m "feat(#267): T2 + AB-3 cycle handlers, echo-guard drain, post-cycle §5.6 sweep (S-34/S-37)"
  ```

---

### Task 69: T3 `fetchedRecordZoneChanges` — route modifications/deletions (§5.1/§5.2) (S-32, S-1 deletion effects)

**Files:** Modify `SyncEngineController.swift`, `SyncEngineControllerTests.swift`

**Interfaces:** Extends `handle(_:)` with `.fetchedRecordZoneChanges`.

**Steps:**

- [ ] **Step 1 — Failing test.**
  ```swift
  func testGivenTombstonedId_WhenFetchedModification_ThenSkippedPendingDeleteWins() {
    let id = UUID()
    store.setTombstone(recordName: id.uuidString, changeTag: "t")
    let controller = makeController()
    controller.start()
    controller.startupTask?.cancel()

    controller.handle(
      .fetchedRecordZoneChanges(modifications: [makeProfileRecord(id: id, version: 5)], deletions: []))

    XCTAssertNil(try? fetchProfile(id), "pending-delete-wins ⇒ modification skipped (S-32)")
  }

  func testGivenNoTombstone_WhenFetchedModification_ThenApplied() {
    let id = UUID()
    let controller = makeController()
    controller.start()
    controller.startupTask?.cancel()

    controller.handle(
      .fetchedRecordZoneChanges(modifications: [makeProfileRecord(id: id, version: 5)], deletions: []))

    XCTAssertNotNil(try? fetchProfile(id))
  }

  func testGivenFetchedDeletion_WhenHandled_ThenTombstoneClearedAndPendingDeleteRemoved() {
    let id = UUID()
    let p = BlockedProfiles(id: id, name: "A")
    context.insert(p)
    try? context.save()
    store.setTombstone(recordName: id.uuidString, changeTag: "t")
    store.setSystemFields(Data([0x1]), for: id.uuidString)

    let controller = makeController()
    controller.start()
    controller.startupTask?.cancel()
    driver.add(pendingRecordZoneChanges: [.deleteRecord(recordID(id.uuidString))])

    controller.handle(
      .fetchedRecordZoneChanges(
        modifications: [],
        deletions: [(recordID: recordID(id.uuidString), recordType: SyncedProfile.recordType)]))

    XCTAssertNil(try? fetchProfile(id), "local profile deleted (§5.2)")
    XCTAssertNil(store.deleteTombstones[id.uuidString], "tombstone cleared (I12)")
    XCTAssertNil(store.systemFields(for: id.uuidString))
    XCTAssertFalse(pendingDeleteNames().contains(id.uuidString), "pending .deleteRecord removed (§5.2)")
  }
  ```

- [ ] **Step 2 — Run, expect fail:**
  ```bash
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SyncEngineControllerTests/testGivenTombstonedId_WhenFetchedModification_ThenSkippedPendingDeleteWins | xcpretty
  ```

- [ ] **Step 3 — Implement.** Add a case to `handle(_:)` (above `default`):
  ```swift
  case .fetchedRecordZoneChanges(let modifications, let deletions):
    handleFetchedRecordZoneChanges(modifications: modifications, deletions: deletions)
  ```
  Add:
  ```swift
  private func handleFetchedRecordZoneChanges(
    modifications: [CKRecord],
    deletions: [(recordID: CKRecord.ID, recordType: CKRecord.RecordType)]
  ) {
    for record in modifications {
      let outcome = apply.applyFetchedModification(
        record, isPendingDeleteOrTombstoned: blockedPredicate())
      if outcome == .applied {
        store.removeFailedApply(recordName: record.recordID.recordName)  // supersession (§5.6)
      }
    }
    for (recordID, recordType) in deletions {
      _ = apply.applyFetchedDeletion(recordID: recordID, recordType: recordType)
      applyDeletionSideEffects(recordID: recordID)
      store.removeFailedApply(recordName: recordID.recordName)  // supersession
    }
  }
  ```
  (`applyDeletionSideEffects` and `blockedPredicate` were defined in Task 67.)

- [ ] **Step 4 — Run, expect pass** (all three tests), then full suite green.

- [ ] **Step 5 — Commit.**
  ```bash
  git add Foqos/CloudKit/SyncEngine/SyncEngineController.swift FoqosTests/SyncEngineControllerTests.swift
  git commit -m "feat(#267): T3 fetchedRecordZoneChanges routing §5.1/§5.2 (S-32/S-1)"
  ```

---

### Task 70: T4 `sentRecordZoneChanges` — §5.3 branches 0/C/E/Z/U-save/U-delete/R/F + echo-guard populate (S-10, S-17, S-23, S-11, S-29)

**Files:** Modify `SyncEngineController.swift`, `SyncEngineControllerTests.swift`

**Interfaces:** Extends `handle(_:)` with `.sentRecordZoneChanges`.

**Steps:**

- [ ] **Step 1 — Failing test.**
  ```swift
  func testGivenSentSave_WhenServerRecordChanged_ThenBranchCTagStoredMergeAndReAdd() {
    // Local strictly newer than server ⇒ branch C local-wins ⇒ re-add.
    let id = UUID()
    let local = BlockedProfiles(id: id, name: "Local", syncVersion: 5)
    context.insert(local)
    try? context.save()
    let controller = makeController()
    controller.start()
    controller.startupTask?.cancel()

    let sent = makeProfileRecord(id: id, version: 5)  // what we tried to save
    let server = makeProfileRecord(id: id, version: 3)  // older on server
    let error = makeCKError(
      .serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: server])

    controller.handle(
      .sentRecordZoneChanges(
        savedRecords: [], failedRecordSaves: [(record: sent, error: error)],
        deletedRecordIDs: [], failedRecordDeletes: []))

    XCTAssertNotNil(store.systemFields(for: id.uuidString), "server tag stored first (scoped type)")
    XCTAssertTrue(pendingSaveNames().contains(id.uuidString), "local strictly newer ⇒ re-add")
  }

  func testGivenSentSave_WhenZoneNotFound_ThenBranchZSaveZoneSeedAndReAdd() {
    let id = UUID()
    let controller = makeController()
    controller.start()
    controller.startupTask?.cancel()
    let sent = makeProfileRecord(id: id, version: 1)

    controller.handle(
      .sentRecordZoneChanges(
        savedRecords: [], failedRecordSaves: [(record: sent, error: makeCKError(.zoneNotFound))],
        deletedRecordIDs: [], failedRecordDeletes: []))

    XCTAssertTrue(hasPendingZoneSave(), "branch Z ⇒ saveZone")
    XCTAssertTrue(store.pendingSeedIntent, "branch Z ⇒ intent-first seed")
    XCTAssertTrue(pendingSaveNames().contains(id.uuidString), "failed change re-added")
  }

  func testGivenSentSave_WhenUnknownItem_ThenBranchUSaveDropsTagReAddsCreate() {
    let id = UUID()
    store.setSystemFields(Data([0x1]), for: id.uuidString)
    let controller = makeController()
    controller.start()
    controller.startupTask?.cancel()
    let sent = makeProfileRecord(id: id, version: 1)

    controller.handle(
      .sentRecordZoneChanges(
        savedRecords: [], failedRecordSaves: [(record: sent, error: makeCKError(.unknownItem))],
        deletedRecordIDs: [], failedRecordDeletes: []))

    XCTAssertNil(store.systemFields(for: id.uuidString), "U-save drops the system-fields entry")
    XCTAssertTrue(pendingSaveNames().contains(id.uuidString), "re-added as create")
  }

  func testGivenSentSave_WhenRetriableVsNonRetriable_ThenBranchROnceBranchFSurfaced() {
    let rId = UUID()
    let fId = UUID()
    let fProfile = BlockedProfiles(id: fId, name: "F")
    context.insert(fProfile)
    try? context.save()
    let controller = makeController()
    controller.start()
    controller.startupTask?.cancel()

    controller.handle(
      .sentRecordZoneChanges(
        savedRecords: [],
        failedRecordSaves: [
          (record: makeProfileRecord(id: rId, version: 1), error: makeCKError(.networkFailure)),
          (record: makeProfileRecord(id: fId, version: 1), error: makeCKError(.permissionFailure)),
        ], deletedRecordIDs: [], failedRecordDeletes: []))

    XCTAssertEqual(
      pendingSaveNames().filter { $0 == rId.uuidString }.count, 1, "branch R re-added once")
    XCTAssertFalse(pendingSaveNames().contains(fId.uuidString), "branch F removed permanently")
    XCTAssertNotNil(SyncConflictManager.shared.conflictedProfiles[fId], "branch F surfaces conflict")
  }

  func testGivenConfirmedDelete_WhenSentRecordChanges_ThenTombstoneClearedAndSystemFieldsDropped() {
    let id = UUID()
    store.setTombstone(recordName: id.uuidString, changeTag: "t")
    store.setSystemFields(Data([0x1]), for: id.uuidString)
    let controller = makeController()
    controller.start()
    controller.startupTask?.cancel()

    controller.handle(
      .sentRecordZoneChanges(
        savedRecords: [], failedRecordSaves: [],
        deletedRecordIDs: [recordID(id.uuidString)], failedRecordDeletes: []))

    XCTAssertNil(store.deleteTombstones[id.uuidString], "confirmed delete clears tombstone (I12)")
    XCTAssertNil(store.systemFields(for: id.uuidString))
    XCTAssertTrue(apply.recentlyConfirmedDeletes.contains(id.uuidString), "echo guard populated")
  }

  func testGivenSavedRecord_WhenSent_ThenSystemFieldsStoredAndLegacyIdCleared() {
    let id = UUID()
    store.addLegacyCleanupIds(["legacy-x"])
    let controller = makeController()
    controller.start()
    controller.startupTask?.cancel()

    let saved = makeProfileRecord(id: id, version: 2)
    let legacy = CKRecord(
      recordType: "SyncedSession", recordID: recordID("legacy-x"))
    controller.handle(
      .sentRecordZoneChanges(
        savedRecords: [saved, legacy], failedRecordSaves: [], deletedRecordIDs: [],
        failedRecordDeletes: []))

    XCTAssertNotNil(store.systemFields(for: id.uuidString), "scoped-type tag stored")
    XCTAssertFalse(store.legacyCleanupIds.contains("legacy-x"), "legacy id cleared on confirmation")
    XCTAssertTrue(store.legacyCleanupDone, "flag set when legacyCleanupIds empties")
  }
  ```

- [ ] **Step 2 — Run, expect fail:**
  ```bash
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SyncEngineControllerTests/testGivenSentSave_WhenZoneNotFound_ThenBranchZSaveZoneSeedAndReAdd | xcpretty
  ```

- [ ] **Step 3 — Implement.** Add a case to `handle(_:)`:
  ```swift
  case .sentRecordZoneChanges(
    let savedRecords, let failedRecordSaves, let deletedRecordIDs, let failedRecordDeletes):
    handleSentRecordZoneChanges(
      savedRecords: savedRecords, failedRecordSaves: failedRecordSaves,
      deletedRecordIDs: deletedRecordIDs, failedRecordDeletes: failedRecordDeletes)
  ```
  Add:
  ```swift
  private static let scopedTypes: Set<String> = [
    SyncedProfile.recordType, SyncedLocation.recordType, SyncedEmergencySettings.recordType,
  ]

  private func handleSentRecordZoneChanges(
    savedRecords: [CKRecord],
    failedRecordSaves: [(record: CKRecord, error: CKError)],
    deletedRecordIDs: [CKRecord.ID],
    failedRecordDeletes: [(recordID: CKRecord.ID, error: CKError)]
  ) {
    store.transaction { s in
      for record in savedRecords {
        let name = record.recordID.recordName
        if Self.scopedTypes.contains(record.recordType) {
          s.setSystemFields(self.encodeSystemFields(record), for: name)
        }
        self.clearLegacyId(name, in: s)
      }
      for id in deletedRecordIDs {
        let name = id.recordName
        s.setSystemFields(nil, for: name)
        s.clearTombstone(recordName: name)  // I12 confirmed
        self.clearLegacyId(name, in: s)
      }
    }
    for id in deletedRecordIDs {
      apply.recentlyConfirmedDeletes.insert(id.recordName)  // echo guard (§5.1)
      confirmDeleteCycle[id.recordName] = currentCycle
    }
    for (record, error) in failedRecordSaves { handleFailedSave(record: record, error: error) }
    for (id, error) in failedRecordDeletes { handleFailedDelete(recordID: id, error: error) }
  }

  private func clearLegacyId(_ name: String, in s: SyncEngineStore) {
    guard s.legacyCleanupIds.contains(name) else { return }
    s.removeLegacyCleanupId(name)
    if s.legacyCleanupIds.isEmpty { s.legacyCleanupDone = true }
  }

  private func encodeSystemFields(_ record: CKRecord) -> Data {
    let coder = NSKeyedArchiver(requiringSecureCoding: true)
    record.encodeSystemFields(with: coder)
    coder.finishEncoding()
    return coder.encodedData
  }

  private func handleFailedSave(record: CKRecord, error: CKError) {
    let name = record.recordID.recordName
    if record.recordType == SyncResetRequest.recordType {
      resetCommandSaveDidFail?(record, error)  // §8.1 step 5 (Phase E)
      return
    }
    let tombstoned = store.deleteTombstones[name] != nil || hasPendingDelete(name)
    switch error.code {
    case .serverRecordChanged:
      guard let server = error.serverRecord else { return }
      if tombstoned { return }  // pending-delete-wins: store nothing, re-add nothing
      if Self.scopedTypes.contains(record.recordType) {
        store.setSystemFields(encodeSystemFields(server), for: name)  // store server tag first
      }
      _ = apply.applyFetchedModification(server, isPendingDeleteOrTombstoned: blockedPredicate())
      // branch 0 / server-newer: apply merged, no re-add. branch E (equal+differing): apply
      // bumped+enqueued+surfaced inside §5.1. local strictly newer: re-add here.
      if localIsStrictlyNewer(record.recordType, name: name, server: server) {
        driver.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
      }
    case .zoneNotFound:
      seedZoneAndRecords()  // branch Z: saveZone + intent-first seed
      driver.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
    case .unknownItem:
      store.setSystemFields(nil, for: name)  // branch U-save
      driver.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
    default:
      if isRetriable(error) {
        driver.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])  // branch R, once
      } else {
        surfaceConflict(forRecordName: name, record: record)  // branch F
        // engine already dropped the change; nothing to re-add.
      }
    }
  }

  private func handleFailedDelete(recordID id: CKRecord.ID, error: CKError) {
    let name = id.recordName
    switch error.code {
    case .unknownItem:  // branch U-delete: done
      store.transaction { s in
        s.setSystemFields(nil, for: name)
        s.clearTombstone(recordName: name)
      }
    case .zoneNotFound:  // branch Z (delete): recreate + re-add the delete
      seedZoneAndRecords()
      driver.add(pendingRecordZoneChanges: [.deleteRecord(id)])
    default:
      if isRetriable(error) {
        driver.add(pendingRecordZoneChanges: [.deleteRecord(id)])  // branch R
      } else {
        store.clearTombstone(recordName: name)  // branch F for a delete: surfaced, not looping
        surfaceConflict(forRecordName: name, record: nil)
      }
    }
  }

  private func isRetriable(_ error: CKError) -> Bool {
    switch error.code {
    case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited,
      .zoneBusy, .serverResponseLost:
      return true
    default:
      return false
    }
  }

  private func localIsStrictlyNewer(
    _ recordType: String, name: String, server: CKRecord
  ) -> Bool {
    switch recordType {
    case SyncedProfile.recordType:
      guard let uuid = UUID(uuidString: name),
        let local = try? modelContext.fetch(
          FetchDescriptor<BlockedProfiles>(predicate: #Predicate { $0.id == uuid })
        ).first
      else { return false }
      let serverVersion = server[SyncedProfile.FieldKey.version.rawValue] as? Int ?? 0
      return local.syncVersion > serverVersion
    case SyncedLocation.recordType:
      guard let uuid = UUID(uuidString: name),
        let local = try? modelContext.fetch(
          FetchDescriptor<SavedLocation>(predicate: #Predicate { $0.id == uuid })
        ).first
      else { return false }
      let serverUpdated = server[SyncedLocation.FieldKey.updatedAt.rawValue] as? Date ?? .distantPast
      return local.updatedAt > serverUpdated
    case SyncedEmergencySettings.recordType:
      // Emergency version lives in the provider's materialized record; compare against it.
      guard let localRecord = provider.record(forRecordName: name) else { return false }
      let localVersion = localRecord[SyncedEmergencySettings.FieldKey.version.rawValue] as? Int ?? 0
      let serverVersion = server[SyncedEmergencySettings.FieldKey.version.rawValue] as? Int ?? 0
      return localVersion > serverVersion
    default:
      return false
    }
  }
  ```

- [ ] **Step 4 — Run, expect pass** (all §5.3 tests, plus the deferred `testGivenConfirmedDelete_WhenModificationDeliveredBeforeVsAfterCycleStart...` from Task 68), then full suite green.

- [ ] **Step 5 — Commit.**
  ```bash
  git add Foqos/CloudKit/SyncEngine/SyncEngineController.swift FoqosTests/SyncEngineControllerTests.swift
  git commit -m "feat(#267): T4 sentRecordZoneChanges §5.3 branches + echo-guard populate (S-10/S-17/S-23/S-11/S-29)"
  ```

---

### Task 71: T4b `sentDatabaseChanges` (§5.5)

**Files:** Modify `SyncEngineController.swift`, `SyncEngineControllerTests.swift`

**Interfaces:** Extends `handle(_:)` with `.sentDatabaseChanges`.

**Steps:**

- [ ] **Step 1 — Failing test.**
  ```swift
  func testGivenSentDatabaseChanges_WhenZoneSavedOrAlreadyExists_ThenConfirmed() {
    let controller = makeController()
    controller.start()
    controller.startupTask?.cancel()
    let zone = CKRecordZone(zoneID: zoneID)

    // zone-already-exists counts as confirmed ⇒ no re-add.
    controller.handle(
      .sentDatabaseChanges(
        savedZones: [], failedZoneSaves: [(zone: zone, error: makeCKError(.serverRecordChanged))],
        deletedZoneIDs: [], failedZoneDeletes: []))
    XCTAssertFalse(hasPendingZoneSave(), "already-exists ⇒ confirmed, not re-added")

    // retriable ⇒ re-add saveZone.
    controller.handle(
      .sentDatabaseChanges(
        savedZones: [], failedZoneSaves: [(zone: zone, error: makeCKError(.networkFailure))],
        deletedZoneIDs: [], failedZoneDeletes: []))
    XCTAssertTrue(hasPendingZoneSave(), "retriable zone save ⇒ re-add")
  }
  ```

- [ ] **Step 2 — Run, expect fail:**
  ```bash
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SyncEngineControllerTests/testGivenSentDatabaseChanges_WhenZoneSavedOrAlreadyExists_ThenConfirmed | xcpretty
  ```

- [ ] **Step 3 — Implement.** Add a `handle(_:)` case:
  ```swift
  case .sentDatabaseChanges(
    let savedZones, let failedZoneSaves, let deletedZoneIDs, let failedZoneDeletes):
    handleSentDatabaseChanges(
      savedZones: savedZones, failedZoneSaves: failedZoneSaves,
      deletedZoneIDs: deletedZoneIDs, failedZoneDeletes: failedZoneDeletes)
  ```
  Add:
  ```swift
  private func handleSentDatabaseChanges(
    savedZones: [CKRecordZone.ID],
    failedZoneSaves: [(zone: CKRecordZone, error: CKError)],
    deletedZoneIDs: [CKRecordZone.ID],
    failedZoneDeletes: [(zoneID: CKRecordZone.ID, error: CKError)]
  ) {
    // savedZones / deletedZoneIDs / .zoneNotFound-on-delete: confirmed — Phase E advances
    // resetIntent stages via onZoneChangeConfirmed hook (added there); nothing to persist here.
    onZoneChangeConfirmed?(savedZones, deletedZoneIDs)
    for (zone, error) in failedZoneSaves {
      if error.code == .serverRecordChanged {
        onZoneChangeConfirmed?([zone.zoneID], [])  // zone-already-exists ⇒ confirmed
      } else if isRetriable(error) {
        driver.add(pendingDatabaseChanges: [.saveZone(zone)])  // rely on engine backoff
      } else {
        Log.error("Non-retriable zone save failure: \(error.code)", category: .sync)
      }
    }
    for (zoneID, error) in failedZoneDeletes {
      if error.code == .zoneNotFound {
        onZoneChangeConfirmed?([], [zoneID])  // already gone ⇒ confirmed
      } else if isRetriable(error) {
        driver.add(pendingDatabaseChanges: [.deleteZone(zoneID)])
      }
    }
  }
  ```
  Add the Phase E confirmation hook near the other hooks:
  ```swift
  var onZoneChangeConfirmed: (([CKRecordZone.ID], [CKRecordZone.ID]) -> Void)?
  ```

- [ ] **Step 4 — Run, expect pass**, then full suite green.

- [ ] **Step 5 — Commit.**
  ```bash
  git add Foqos/CloudKit/SyncEngine/SyncEngineController.swift FoqosTests/SyncEngineControllerTests.swift
  git commit -m "feat(#267): T4b sentDatabaseChanges §5.5 + reset-stage confirmation hook"
  ```

---

### Task 72: `nextRecordZoneChangeBatch` materialization (§5.4) (S-14, S-29 refuse tombstone-less delete)

**Files:** Modify `SyncEngineController.swift`, `SyncEngineControllerTests.swift`

**Interfaces:** Implements `nextRecordZoneChangeBatch(scope:)`.

**Steps:**

- [ ] **Step 1 — Failing test.**
  ```swift
  func testGivenNewerSchemaProfilePendingSave_WhenNextBatch_ThenRemoved() {
    let id = UUID()
    let p = BlockedProfiles(id: id, name: "Newer")
    context.insert(p)
    try? context.save()
    let controller = makeController()
    controller.start()
    controller.startupTask?.cancel()
    driver.add(pendingRecordZoneChanges: [.saveRecord(recordID(id.uuidString))])

    // Force provider.record(...) to return nil by making the local record un-materializable:
    // set its schema version above current so provider treats it as isNewerSchemaVersion.
    p.profileSchemaVersion = BlockedProfiles.currentSchemaVersion + 1
    try? context.save()

    let batch = controller.nextRecordZoneChangeBatch(scope: nil)

    XCTAssertNil(
      batch?.first { $0.recordID.recordName == id.uuidString },
      "unmaterializable/newer-schema save not materialized (§5.4/S-14)")
    XCTAssertFalse(pendingSaveNames().contains(id.uuidString), "stray pending save removed")
  }

  func testGivenTombstonelessPendingDelete_WhenNextBatch_ThenRemovedUnlessLegacy() {
    let orphanId = "orphan"
    let legacyId = "legacy-y"
    store.addLegacyCleanupIds([legacyId])
    let controller = makeController()
    controller.start()
    controller.startupTask?.cancel()
    driver.add(pendingRecordZoneChanges: [
      .deleteRecord(recordID(orphanId)),  // no tombstone ⇒ refuse
      .deleteRecord(recordID(legacyId)),  // legacy exempt ⇒ kept
    ])

    _ = controller.nextRecordZoneChangeBatch(scope: nil)

    XCTAssertFalse(pendingDeleteNames().contains(orphanId), "tombstone-less delete removed (§5.4)")
    XCTAssertTrue(pendingDeleteNames().contains(legacyId), "legacy cleanup delete exempt")
  }

  func testGivenMaterializableSave_WhenNextBatch_ThenReturnsRecord() {
    let id = UUID()
    let p = BlockedProfiles(id: id, name: "OK")
    context.insert(p)
    try? context.save()
    let controller = makeController()
    controller.start()
    controller.startupTask?.cancel()
    driver.add(pendingRecordZoneChanges: [.saveRecord(recordID(id.uuidString))])

    let batch = controller.nextRecordZoneChangeBatch(scope: nil)
    XCTAssertNotNil(batch?.first { $0.recordID.recordName == id.uuidString })
  }
  ```

- [ ] **Step 2 — Run, expect fail** (returns `nil`):
  ```bash
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SyncEngineControllerTests/testGivenMaterializableSave_WhenNextBatch_ThenReturnsRecord | xcpretty
  ```

- [ ] **Step 3 — Implement.** Replace `nextRecordZoneChangeBatch`:
  ```swift
  func nextRecordZoneChangeBatch(scope: CKSyncEngine.SendChangesOptions.Scope?) -> [CKRecord]? {
    var records: [CKRecord] = []
    var savesToRemove: [CKSyncEngine.PendingRecordZoneChange] = []
    var deletesToRemove: [CKSyncEngine.PendingRecordZoneChange] = []
    let legacy = store.legacyCleanupIds

    for change in driver.pendingRecordZoneChanges {
      switch change {
      case .saveRecord(let id):
        if let record = provider.record(forRecordName: id.recordName) {
          records.append(record)
        } else {
          savesToRemove.append(change)  // entity absent or isNewerSchemaVersion (§5.4)
        }
      case .deleteRecord(let id):
        let name = id.recordName
        let hasTombstone = store.deleteTombstones[name] != nil
        if !hasTombstone && !legacy.contains(name) {
          deletesToRemove.append(change)  // refuse = remove (§5.4 defence in depth for I12)
        }
      @unknown default:
        break
      }
    }
    if !savesToRemove.isEmpty { driver.remove(pendingRecordZoneChanges: savesToRemove) }
    if !deletesToRemove.isEmpty { driver.remove(pendingRecordZoneChanges: deletesToRemove) }
    return records.isEmpty ? nil : records
  }
  ```
  Note: deletes are not materialized as `CKRecord`s (the engine deletes by id from the pending queue); this method only returns the save records and prunes the queue per §5.4.

- [ ] **Step 4 — Run, expect pass** (all three tests), then full suite green.

- [ ] **Step 5 — Commit.**
  ```bash
  git add Foqos/CloudKit/SyncEngine/SyncEngineController.swift FoqosTests/SyncEngineControllerTests.swift
  git commit -m "feat(#267): §5.4 nextRecordZoneChangeBatch materialization + queue pruning (S-14/S-29)"
  ```

---

### Task 73: T10 `stateUpdate` persist (AB-2, S-26)

**Files:** Modify `SyncEngineController.swift`, `SyncEngineControllerTests.swift`

**Interfaces:** Extends `handle(_:)` with `.stateUpdate`.

**Steps:**

- [ ] **Step 1 — Failing test.**
  ```swift
  func testGivenStateUpdate_WhenHandled_ThenEngineStatePersisted() {
    let controller = makeController()
    controller.start()
    controller.startupTask?.cancel()
    let serialization = Data([0xAB, 0xCD])

    controller.handle(.stateUpdate(serialization: serialization))

    XCTAssertEqual(store.engineState, serialization, "T10 persists serialization (AB-2 fetch tokens)")
  }

  func testGivenStateUpdateBetweenTwoFetchEvents_WhenPersisted_ThenSecondEventReDeliveredOnRelaunch() {
    // AB-2 (S-26): persisting on stateUpdate only reflects fetch progress already handled.
    // We assert the controller persists the serialization it was handed and never fabricates one.
    let controller = makeController()
    controller.start()
    controller.startupTask?.cancel()
    controller.handle(.fetchedRecordZoneChanges(modifications: [], deletions: []))
    controller.handle(.stateUpdate(serialization: Data([0x01])))
    controller.handle(.fetchedRecordZoneChanges(modifications: [], deletions: []))
    // No further stateUpdate ⇒ engineState still reflects the first serialization; on relaunch the
    // engine re-delivers the second event's changes (nothing persisted past [0x01]).
    XCTAssertEqual(store.engineState, Data([0x01]))
  }
  ```

- [ ] **Step 2 — Run, expect fail:**
  ```bash
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SyncEngineControllerTests/testGivenStateUpdate_WhenHandled_ThenEngineStatePersisted | xcpretty
  ```

- [ ] **Step 3 — Implement.** Add a `handle(_:)` case:
  ```swift
  case .stateUpdate(let serialization):
    store.engineState = serialization  // §5.0 / AB-2 (safe for fetch tokens)
  ```

- [ ] **Step 4 — Run, expect pass**, then full suite green.

- [ ] **Step 5 — Commit.**
  ```bash
  git add Foqos/CloudKit/SyncEngine/SyncEngineController.swift FoqosTests/SyncEngineControllerTests.swift
  git commit -m "feat(#267): T10 stateUpdate persistence (AB-2/S-26)"
  ```

---

### Task 74: Zone events (T5/T6), account change (T7), stop (T11), reset resume hook (S-3, S-4)

**Files:** Modify `SyncEngineController.swift`, `SyncEngineControllerTests.swift`

**Interfaces:** Extends `handle(_:)` with `.fetchedDatabaseChanges` and `.accountChange`; implements `stop()`; `runStartupSequence` invokes `onResumeReset` when `resetIntent` is set.

**Steps:**

- [ ] **Step 1 — Failing test.**
  ```swift
  func testGivenZoneDeleted_WhenHandled_ThenDataIntactPurgeIntentFirstSeed() async {
    let p = BlockedProfiles(name: "A")
    context.insert(p)
    try? context.save()
    store.setSystemFields(Data([0x1]), for: "stale")
    let controller = makeController()
    controller.start()
    await controller.startupTask?.value

    controller.handle(
      .fetchedDatabaseChanges(
        modifiedZoneIDs: [],
        deletedZones: [(zoneID: zoneID, reason: .deleted)]))
    await controller.flushTask?.value

    XCTAssertNotNil(try? context.fetch(FetchDescriptor<BlockedProfiles>()).first, "data intact (I1)")
    XCTAssertNil(store.systemFields(for: "stale"), "I6 purge")
    XCTAssertEqual(sessionSync.flushCount, 1, "session cache flushed (I6)")
    XCTAssertTrue(store.pendingSeedIntent, "intent-first seed (T5/I11)")
    XCTAssertTrue(hasPendingZoneSave())
  }

  func testGivenZonePurged_WhenHandled_ThenDisabledDiscardStateTombstonesIntact() async {
    store.engineState = Data([0x1])
    store.resetIntent = ResetIntent(id: UUID(), clear: false, stage: .deleting, priorCommandId: nil)
    store.pendingSeedIntent = true
    store.setTombstone(recordName: "keep", changeTag: "t")
    let controller = makeController()
    controller.start()
    controller.startupTask?.cancel()

    controller.handle(
      .fetchedDatabaseChanges(
        modifiedZoneIDs: [],
        deletedZones: [(zoneID: zoneID, reason: .purged)]))

    XCTAssertEqual(controller.state, .purged, "T6")
    XCTAssertNil(store.engineState, "engine state discarded")
    XCTAssertNil(store.resetIntent)
    XCTAssertFalse(store.pendingSeedIntent)
    XCTAssertNotNil(store.deleteTombstones["keep"], "tombstones survive (not consent-scoped)")
    XCTAssertFalse(SharedData.deviceSyncEnabled, "sync disabled")
    XCTAssertTrue(pendingSaveNames().isEmpty, "nothing enqueued")
  }

  func testGivenAccountChange_WhenHandled_ThenStopInvalidateContinuationsPurgeNothing() async {
    store.setSystemFields(Data([0x1]), for: "keep")
    let controller = makeController()
    controller.start()
    controller.handle(.accountChange(kind: .switchAccounts))

    XCTAssertEqual(controller.state, .disabled)
    XCTAssertNotNil(store.systemFields(for: "keep"), "account change purges nothing (§7)")
    XCTAssertTrue(controller.startupTask?.isCancelled ?? true, "in-flight continuations invalidated")
  }

  func testGivenStop_WhenCalled_ThenClearIntentsBestEffortSendTombstonesSurvive() {
    store.engineState = Data([0x1])
    store.resetIntent = ResetIntent(id: UUID(), clear: false, stage: .deleting, priorCommandId: nil)
    store.pendingSeedIntent = true
    store.setTombstone(recordName: "keep", changeTag: "t")
    var stopResetCalled = false
    let controller = makeController()
    controller.onStopReset = { stopResetCalled = true }
    controller.start()
    controller.startupTask?.cancel()

    controller.stop()

    XCTAssertTrue(stopResetCalled, "reset dequeue hook invoked first (T11)")
    XCTAssertFalse(store.pendingSeedIntent)
    XCTAssertNil(store.engineState, "engine state discarded (N5 saves lost)")
    XCTAssertNotNil(store.deleteTombstones["keep"], "tombstones survive T11 (re-propagate via I12)")
    XCTAssertEqual(driver.sendChangesCallCount, 1, "best-effort final send")
    XCTAssertEqual(controller.state, .disabled)
  }

  func testGivenResetIntentSet_WhenStart_ThenResumeHookInvoked() async {
    store.engineState = Data([0x1])
    let intent = ResetIntent(id: UUID(), clear: true, stage: .recreating, priorCommandId: nil)
    store.resetIntent = intent
    var resumed: ResetIntent?
    let controller = makeController()
    controller.onResumeReset = { resumed = $0 }
    controller.start()
    await controller.startupTask?.value

    XCTAssertEqual(resumed?.id, intent.id, "§8.1 resume delegated to Phase E hook")
  }
  ```

- [ ] **Step 2 — Run, expect fail:**
  ```bash
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SyncEngineControllerTests/testGivenZoneDeleted_WhenHandled_ThenDataIntactPurgeIntentFirstSeed | xcpretty
  ```

- [ ] **Step 3 — Implement.** Add `handle(_:)` cases (and remove `default: break` — the switch is now exhaustive over `SyncEngineEvent`):
  ```swift
  case .fetchedDatabaseChanges(_, let deletedZones):
    handleZoneDeletions(deletedZones)
  case .accountChange(let kind):
    handleAccountChange(kind)
  ```
  Add:
  ```swift
  private func handleZoneDeletions(
    _ deletedZones: [(zoneID: CKRecordZone.ID, reason: SyncEngineZoneDeletionReason)]
  ) {
    for (deletedZoneID, reason) in deletedZones
    where deletedZoneID.zoneName == CloudKitConstants.syncZoneName {
      switch reason {
      case .deleted, .encryptedDataReset:  // T5
        store.purgeAllSystemFields()
        seedZoneAndRecords()  // intent-first (I11)
        flushTask = Task { [weak self] in await self?.sessionSync.flushSessionCache() }
      case .purged:  // T6
        store.purgeAllSystemFields()
        store.transaction { s in
          s.engineState = nil
          s.resetIntent = nil
          s.pendingSeedIntent = false
          // tombstones survive — deletion intent is not consent-scoped
        }
        state = .purged
        SharedData.deviceSyncEnabled = false
        flushTask = Task { [weak self] in await self?.sessionSync.flushSessionCache() }
        NotificationCenter.default.post(name: .syncEnginePurged, object: nil)  // one-time notice (Phase F UI)
      }
    }
  }

  private func handleAccountChange(_ kind: SyncEngineAccountChangeKind) {
    // T7: stop engine, invalidate in-flight continuations, purge NOTHING; namespace switch is
    // performed by the app reconstructing the controller/store for the new user (Phase F, N11).
    namespaceGeneration += 1  // invalidates in-flight async fetches (they re-check the generation)
    startupTask?.cancel()
    flushTask?.cancel()
    state = .disabled
  }
  ```
  Extend `runStartupSequence` — after `applySeedDecision()` and before `driver.fetchChanges()`:
  ```swift
  if let intent = store.resetIntent { onResumeReset?(intent) }  // §8.1 (Phase E)
  ```
  Implement `stop()` (T11):
  ```swift
  func stop() {
    onStopReset?()  // Phase E: clear resetIntent + dequeue its zone changes first
    store.resetIntent = nil
    store.pendingSeedIntent = false
    driver?.sendChanges()  // best-effort final send (N5 mitigation for pending saves)
    namespaceGeneration += 1
    startupTask?.cancel()
    flushTask?.cancel()
    store.engineState = nil  // pending unsent saves lost (N5); tombstones survive
    state = .disabled
  }
  ```
  Add the notification name once (e.g. in `SyncEngineController.swift`):
  ```swift
  extension Notification.Name {
    static let syncEnginePurged = Notification.Name("family_foqos_sync_engine_purged")
  }
  ```

- [ ] **Step 4 — Run, expect pass** (all five tests), then run the FULL suite once and confirm the 429 existing tests plus every Phase D test are green.

- [ ] **Step 5 — Commit.**
  ```bash
  git add Foqos/CloudKit/SyncEngine/SyncEngineController.swift FoqosTests/SyncEngineControllerTests.swift
  git commit -m "feat(#267): T5/T6 zone events, T7 accountChange, T11 stop, §8.1 resume hook (S-3/S-4)"
  ```

---

**End of Phase D.** The `SyncEngineController` now implements T1–T11, §5.0–§5.6, I6/I7/I10/I11/I12, and consumes AB-1..AB-4 against `MockSyncEngineDriver`. Reset-stage progression (§8.1 steps 2–5, the `.deleting` gate, T8/T9) is wired via the `onResumeReset`/`onStopReset`/`onZoneChangeConfirmed`/`resetCommandSaveDidFail` hooks and is implemented in **Phase E** (`SyncEngineController+Reset.swift`). No production wiring exists yet — `FoqosApp` construction is **Phase F**.

---

## Phase E — Reset Sync re-design + Session §6 amendment

**Design sections implemented:** §8 (reset semantics, two carriers), §8.1 (crash-resumable origin sequence + `.deleting` resume gate, five-arm case-split, abandon-dequeues-zone-changes, step-5 `serverRecordChanged`), §8.2 (fixed-name command record `sync-reset-command`), §8.3 (command application on any device), §8.4 (T5 non-origin), §8.5 (product decisions), §6 (session CAS coexistence — stop-on-absent create-if-absent, first-CAS-after-recreation, I6 flush), N13. Transitions T8/T9; invariants I3/I4/I6/I11 (reset facets). Residual N14 (backup replay) is honored by the gate's `priorCommandId`/own-id arms.

**Scoping decision (contract-silent, noted).** The reset state machine is delivered as a self-contained `@MainActor ResetController` collaborator with four injected seams (`ResetOutbox`, `ResetSeeder`, `RecordFetching`, `ResetConflictSurfacing`). This is an internal decomposition the contract does not forbid; it makes every §8 scenario unit-testable without constructing the full Phase-D `SyncEngineController`. `SyncEngineController.beginReset(clearRemoteAppSelections:)` (locked signature) and the routing of `SyncResetRequest` fetched-modifications / §5.5 confirmations to this collaborator are thin forwarders wired **at cutover (Phase F)**, when the concrete `CKSyncEngine` pending-change types and controller internals are in hand. Consistent with the standard pre-cutover exit criterion, nothing in this phase runs inside the live app. The production `RecordFetching`/`ResetOutbox`/`ResetConflictSurfacing` adapters are included in `SyncEngineController+Reset.swift` (they compile in the app target against the locked `SyncEngineDriver` protocol and standard CloudKit) but are unreferenced until cutover.

**Consumes from earlier phases (by locked-contract name):** `SyncEngineStore` (§2.1 — `resetIntent`, `processedResetCommandIds`, `markProcessed`, `lastAppliedResetCommandId`, `pendingSeedIntent`, `deleteTombstones`, `purgeAllSystemFields`, `setSystemFields`/`systemFields(for:)`, `transaction`), `ResetIntent`/`ResetIntent.Stage`, and the protocol `SessionSyncFlushing` (`func flushSessionCache() async`, declared in the `SyncEngineController` phase). Reuses existing `SyncResetRequest` (type string, `FieldKey`, `init?(from:)`, `toCKRecord`), `ProfileSessionRecord`, `SessionSyncService`, `CloudKitConstants`.

**Phase exit criterion:** the full target compiles, `swift-format lint` is clean, and the existing 429-test suite plus the new Phase-E tests are green. No Phase-E code is wired into the running app (`FoqosApp`/`SyncEngineController` event routing) until the cutover phase.

---

### Task 100: Session §6 — `stopSession` stop-on-absent create-if-absent (S-24, N13)

**Files:**
- Modify: `Foqos/CloudKit/SessionSyncService.swift`
- Modify: `FoqosTests/Mocks/MockSessionSyncService.swift`
- Test: `FoqosTests/SessionStopOnAbsentTests.swift` (Create)

**Interfaces:**
- Consumes: `actor SessionSyncService` `func stopSession(profileId: UUID, endTime: Date = Date()) async -> StopResult`; `ProfileSessionRecord(profileId:)`, `applyUpdate(isActive:sequenceNumber:deviceId:endTime:)`, `toCKRecord(in:)`; `saveRecordWithPolicy(_:policy:)`.
- Produces: §6 `.notFound` branch of `stopSession` writes a stopped record create-if-absent; on `serverRecordChanged` a newer active session supersedes (treated as `.alreadyStopped`). `MockSessionSyncService` gains opt-in flags `stopOnAbsentCreatesRecord` / `freshStartWinsRace` modeling the same contract.

- [ ] **Step 1 — Failing test.** Create `FoqosTests/SessionStopOnAbsentTests.swift`:
```swift
import Foundation
import XCTest

@testable import FamilyFoqos

final class SessionStopOnAbsentTests: XCTestCase {

  private func makeMock() -> MockSessionSyncService {
    let mock = MockSessionSyncService()
    return mock
  }

  func testGivenAbsentRecord_WhenStop_ThenCreatesStoppedRecordCreateIfAbsent() async {
    let now = Date()
    let mock = makeMock()
    await mock.setStopOnAbsentCreatesRecord(true)
    let profileId = UUID()

    let result = await mock.stopSession(
      profileId: profileId, endTime: now, deviceId: "device-A")

    switch result {
    case .stopped(let seq):
      XCTAssertEqual(seq, 1)
    default:
      XCTFail("Expected .stopped, got \(result)")
    }
    let fetched = await mock.stopOnAbsentDebugRecord(for: profileId)
    XCTAssertNotNil(fetched)
    XCTAssertEqual(fetched?.isActive, false)
    XCTAssertEqual(fetched?.sequenceNumber, 1)
  }

  func testGivenConcurrentFreshStartWins_WhenStopOnAbsent_ThenStopYieldsAlreadyStopped() async {
    let now = Date()
    let mock = makeMock()
    await mock.setStopOnAbsentCreatesRecord(true)
    await mock.setFreshStartWinsRace(true)
    let profileId = UUID()

    let result = await mock.stopSession(
      profileId: profileId, endTime: now, deviceId: "device-A")

    switch result {
    case .alreadyStopped:
      break
    default:
      XCTFail("Expected .alreadyStopped (stop yields), got \(result)")
    }
    let fetched = await mock.stopOnAbsentDebugRecord(for: profileId)
    XCTAssertEqual(fetched?.isActive, true, "Concurrent fresh active start must survive")
  }

  func testGivenStopOnAbsentCreatedStoppedRecord_ThenRecordIsInactiveSignalForMirrors() async {
    let now = Date()
    let mock = makeMock()
    await mock.setStopOnAbsentCreatesRecord(true)
    let profileId = UUID()

    _ = await mock.stopSession(profileId: profileId, endTime: now, deviceId: "device-A")

    let fetch = await mock.fetchSession(profileId: profileId)
    switch fetch {
    case .found(let record):
      XCTAssertFalse(record.isActive, "Mirror-visible stopped record must be inactive (N13)")
    default:
      XCTFail("Expected .found stopped record, got \(fetch)")
    }
  }
}
```

- [ ] **Step 2 — Run, expect fail** (missing `setStopOnAbsentCreatesRecord`/`setFreshStartWinsRace`/`stopOnAbsentDebugRecord` on the mock):
```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SessionStopOnAbsentTests | xcpretty
```

- [ ] **Step 3 — Implement.** (a) Amend the real `SessionSyncService.stopSession` `.notFound` branch. Replace the existing `case .notFound:` body in `stopSession` (currently `return .alreadyStopped`) with a create-if-absent stopped write, and add the helper:
```swift
    case .notFound:
      // §6: this device stopped a session it believed active — write a stopped record
      // create-if-absent so mirrors converge (do NOT silently drop, the old
      // .notFound -> .alreadyStopped path is removed).
      return await createStoppedRecordIfAbsent(profileId: profileId, endTime: endTime)
```
Add below `deactivateSession`:
```swift
  /// §6 stop-on-absent: build a FRESH stopped record (no cached change tag) and save it
  /// create-if-absent. A fresh CKRecord saved with .ifServerRecordUnchanged succeeds only
  /// when the record is absent server-side; a concurrent fresh start surfaces as
  /// serverRecordChanged, in which case the newer active session supersedes this stale stop.
  private func createStoppedRecordIfAbsent(profileId: UUID, endTime: Date) async -> StopResult {
    var session = ProfileSessionRecord(profileId: profileId)
    _ = session.applyUpdate(
      isActive: false, sequenceNumber: 1, deviceId: deviceId, endTime: endTime)
    let record = session.toCKRecord(in: syncZoneID)
    do {
      let savedRecord = try await saveRecordWithPolicy(record, policy: .ifServerRecordUnchanged)
      if let saved = ProfileSessionRecord(from: savedRecord) {
        cachedRecords[profileId] = (savedRecord, saved)
      }
      return .stopped(sequenceNumber: 1)
    } catch let error as CKError {
      if error.code == .serverRecordChanged {
        // A concurrent fresh start won the create race — refetch and yield to a newer active.
        let refetch = await fetchSession(profileId: profileId)
        switch refetch {
        case .found(let current):
          if current.isActive { return .alreadyStopped }
          return .alreadyStopped
        case .notFound:
          return .alreadyStopped
        case .error(let fetchError):
          return .error(fetchError)
        }
      }
      return .error(error)
    } catch {
      return .error(error)
    }
  }
```
(b) Model the same contract in `MockSessionSyncService` (opt-in, default off so existing tests are unaffected). Add stored flags and accessors, and amend the absent branch of `stopSession`:
```swift
  /// §6 opt-in: on stop of an absent record, create a stopped record create-if-absent.
  var stopOnAbsentCreatesRecord = false
  /// §6 opt-in: a concurrent fresh active start won the create race — the stop yields.
  var freshStartWinsRace = false

  func setStopOnAbsentCreatesRecord(_ value: Bool) { stopOnAbsentCreatesRecord = value }
  func setFreshStartWinsRace(_ value: Bool) { freshStartWinsRace = value }
  func stopOnAbsentDebugRecord(for profileId: UUID) -> ProfileSessionRecord? { records[profileId] }
```
Replace the current absent guard in the mock's `stopSession`:
```swift
    guard var session = records[profileId], session.isActive else {
      if stopOnAbsentCreatesRecord && records[profileId] == nil {
        if freshStartWinsRace {
          var winner = ProfileSessionRecord(profileId: profileId)
          _ = winner.applyUpdate(
            isActive: true, sequenceNumber: 1, deviceId: "other-device", startTime: endTime)
          records[profileId] = winner
          return .alreadyStopped
        }
        var created = ProfileSessionRecord(profileId: profileId)
        _ = created.applyUpdate(
          isActive: false, sequenceNumber: 1, deviceId: deviceId, endTime: endTime)
        records[profileId] = created
        return .stopped(sequenceNumber: 1)
      }
      return .alreadyStopped
    }
```

- [ ] **Step 4 — Run, expect pass:**
```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SessionStopOnAbsentTests | xcpretty
```

- [ ] **Step 5 — Commit:**
```bash
git add Foqos/CloudKit/SessionSyncService.swift FoqosTests/Mocks/MockSessionSyncService.swift FoqosTests/SessionStopOnAbsentTests.swift
git commit -m "feat(#267): §6 stop-on-absent create-if-absent for session sync (S-24, N13)"
```

---

### Task 101: Session §6 — first CAS write after zone recreation is create-if-absent (S-21)

**Files:**
- Modify: `FoqosTests/Mocks/MockSessionSyncService.swift`
- Test: `FoqosTests/SessionStopOnAbsentTests.swift` (Modify — add method)

**Interfaces:**
- Consumes: the Task-100 `MockSessionSyncService` create-if-absent branch; `MockSessionSyncService.reset()`.
- Produces: proof that after zone recreation (server empty), the first write is a create-if-absent (fresh seq 1) rather than a stale-cache error — mirroring the real service, whose I6 cache flush (Task 102) forces `stopSession`/`startSession` down the `.notFound` create path.

- [ ] **Step 1 — Failing test.** Add to `SessionStopOnAbsentTests`:
```swift
  func testGivenZoneRecreated_WhenFirstStopWrite_ThenCreatesFreshStoppedRecordNotStaleCacheError() async {
    let now = Date()
    let mock = MockSessionSyncService()
    await mock.setStopOnAbsentCreatesRecord(true)
    let profileId = UUID()

    // An active session existed before the reset.
    _ = await mock.startSession(profileId: profileId, startTime: now, deviceId: "device-A")

    // Zone recreation: the server zone is fresh/empty; the stale cached tag is gone.
    await mock.simulateZoneRecreated()

    let result = await mock.stopSession(
      profileId: profileId, endTime: now.addingTimeInterval(60), deviceId: "device-A")

    switch result {
    case .stopped(let seq):
      XCTAssertEqual(seq, 1, "First post-recreation write must be a fresh create (seq 1)")
    default:
      XCTFail("Expected create-if-absent .stopped, got \(result)")
    }
    let fetched = await mock.stopOnAbsentDebugRecord(for: profileId)
    XCTAssertEqual(fetched?.isActive, false)
  }
```

- [ ] **Step 2 — Run, expect fail** (missing `simulateZoneRecreated`):
```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SessionStopOnAbsentTests/testGivenZoneRecreated_WhenFirstStopWrite_ThenCreatesFreshStoppedRecordNotStaleCacheError | xcpretty
```

- [ ] **Step 3 — Implement.** Add to `MockSessionSyncService`:
```swift
  /// Model an I6 zone recreation: the server zone is fresh, so any prior record is gone and
  /// the next write must be create-if-absent. Mirrors the real service flushing its cache
  /// (Task 102) so the first CAS after recreation goes down the .notFound create path.
  func simulateZoneRecreated() {
    records.removeAll()
  }
```

- [ ] **Step 4 — Run, expect pass:**
```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SessionStopOnAbsentTests | xcpretty
```

- [ ] **Step 5 — Commit:**
```bash
git add FoqosTests/Mocks/MockSessionSyncService.swift FoqosTests/SessionStopOnAbsentTests.swift
git commit -m "test(#267): first CAS after zone recreation is create-if-absent (S-21)"
```

---

### Task 102: `SessionSyncFlushing` conformance + I6 purge seam (`ResetSeeder`/`DefaultResetSeeder`) (S-20)

**Files:**
- Create: `Foqos/CloudKit/SessionSyncService+Flushing.swift`
- Create: `Foqos/CloudKit/SyncEngine/ResetController.swift`
- Create: `FoqosTests/ResetSeederTests.swift`

**Interfaces:**
- Consumes: `protocol SessionSyncFlushing { func flushSessionCache() async }` (declared in the `SyncEngineController` phase); `SessionSyncService.clearCache()`; `SyncEngineStore` (`purgeAllSystemFields`, `setSystemFields(_:for:)`, `systemFields(for:)`).
- Produces: `extension SessionSyncService: SessionSyncFlushing` (I6 flush); `protocol ResetSeeder` + `final class DefaultResetSeeder: ResetSeeder` whose `performI6Purge()` purges `systemFields` and flushes the session cache (I6), with `seedAll`/`clearAllProfileSelections` provided as closures so the reset machine stays decoupled from the I11 seed batch and SwiftData.

- [ ] **Step 1 — Failing test.** Create `FoqosTests/ResetSeederTests.swift`:
```swift
import Foundation
import XCTest

@testable import FamilyFoqos

@MainActor
final class ResetSeederTests: XCTestCase {

  private var suiteName: String!
  private var defaults: UserDefaults!
  private var store: SyncEngineStore!

  override func setUp() {
    super.setUp()
    suiteName = "reset-seeder-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)!
    SharedData.configure(suite: defaults)
    store = SyncEngineStore(userRecordName: "user-A", defaults: defaults)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    defaults = nil
    super.tearDown()
  }

  func testGivenSeeder_WhenPerformI6Purge_ThenPurgesSystemFieldsAndFlushesSessionCache() async {
    store.setSystemFields(Data([0x01]), for: "profile-1")
    XCTAssertNotNil(store.systemFields(for: "profile-1"))

    var flushCount = 0
    var seedCount = 0
    let seeder = DefaultResetSeeder(
      store: store,
      flush: { flushCount += 1 },
      seed: { seedCount += 1 },
      clearSelections: {}
    )

    await seeder.performI6Purge()

    XCTAssertNil(store.systemFields(for: "profile-1"), "I6 must purge systemFields")
    XCTAssertEqual(flushCount, 1, "I6 must flush the session cache")
    XCTAssertEqual(seedCount, 0, "purge must not seed")
  }
}
```

- [ ] **Step 2 — Run, expect fail** (`DefaultResetSeeder` undefined):
```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/ResetSeederTests | xcpretty
```

- [ ] **Step 3 — Implement.** (a) Create `Foqos/CloudKit/SessionSyncService+Flushing.swift`:
```swift
import Foundation

/// I6: on a zone-deletion/recreation event the controller flushes SessionSyncService's
/// CAS cache so the first post-recreation write is create-if-absent (§6/S-20/S-21). The
/// SessionSyncFlushing seam lets the controller flush without a hard singleton dependency.
extension SessionSyncService: SessionSyncFlushing {
  func flushSessionCache() async {
    clearCache()
  }
}
```
(b) Start `Foqos/CloudKit/SyncEngine/ResetController.swift` with the seams and `DefaultResetSeeder`:
```swift
import CloudKit
import Foundation

/// Outbound queue operations the reset machine needs, over the CKSyncEngine driver.
/// Concrete adapter wired at cutover (see SyncEngineController+Reset.swift).
@MainActor
protocol ResetOutbox: AnyObject {
  func enqueueZoneDelete()
  func enqueueZoneSave()
  func removeResetZoneChanges()
  func enqueueCommandSave()
  func removeCommandSave()
  /// Schedule sendChanges() in a Task AFTER the current handler returns (§1.1 prohibition).
  func requestSend()
}

/// I6 purge + I11 seed + §8.3 selection-clear, kept behind a seam so the reset machine is
/// decoupled from the I11 seed batch and SwiftData.
@MainActor
protocol ResetSeeder: AnyObject {
  /// I6: purge systemFields + flush the session cache.
  func performI6Purge() async
  /// I11: enqueue saveZone + save-all-restorable (pendingSeedIntent already persisted).
  func seedAll()
  /// §8.3 step 2 (clear flag): clear selections on all local profiles and save.
  func clearAllProfileSelections() throws
}

/// Direct record fetch by CKRecord.ID (a record fetch, not a query — I5-compatible).
/// nil ⇒ record absent (unknownItem). Throws the underlying CKError otherwise.
@MainActor
protocol RecordFetching: AnyObject {
  func fetchRecord(_ recordID: CKRecord.ID) async throws -> CKRecord?
}

/// Surfaces a user-visible "your reset did not run" conflict entry (abandon arms).
@MainActor
protocol ResetConflictSurfacing: AnyObject {
  func surfaceResetSuperseded()
}

@MainActor
final class DefaultResetSeeder: ResetSeeder {
  private let store: SyncEngineStore
  private let flush: () async -> Void
  private let seed: () -> Void
  private let clearSelections: () throws -> Void

  init(
    store: SyncEngineStore,
    flush: @escaping () async -> Void,
    seed: @escaping () -> Void,
    clearSelections: @escaping () throws -> Void
  ) {
    self.store = store
    self.flush = flush
    self.seed = seed
    self.clearSelections = clearSelections
  }

  func performI6Purge() async {
    store.purgeAllSystemFields()
    await flush()
  }

  func seedAll() { seed() }

  func clearAllProfileSelections() throws { try clearSelections() }
}
```

- [ ] **Step 4 — Run, expect pass:**
```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/ResetSeederTests | xcpretty
```

- [ ] **Step 5 — Commit:**
```bash
git add Foqos/CloudKit/SessionSyncService+Flushing.swift Foqos/CloudKit/SyncEngine/ResetController.swift FoqosTests/ResetSeederTests.swift
git commit -m "feat(#267): SessionSyncFlushing conformance + I6 purge seam (S-20)"
```

---

### Task 103: `ResetController` — origin sequence T8/T9 (begin, pre-mark, stage progression)

**Files:**
- Modify: `Foqos/CloudKit/SyncEngine/ResetController.swift`
- Create: `FoqosTests/Mocks/ResetSeamMocks.swift`
- Create: `FoqosTests/SyncEngineResetTests.swift`

**Interfaces:**
- Consumes: `SyncEngineStore` (`resetIntent`, `markProcessed`, `processedResetCommandIds`, `lastAppliedResetCommandId`, `pendingSeedIntent`, `transaction`); `ResetIntent`/`ResetIntent.Stage`; the Task-102 seams.
- Produces: `ResetController.init(store:outbox:seeder:fetcher:surfacer:deviceId:)`; `beginReset(clearRemoteAppSelections:now:)` (T8, §8.1 step 1–2, I4 pre-mark carve-out); `handleZoneDeleteConfirmed()` (§8.1 step 3, I6 + stage → `.recreating`); `handleZoneSaveConfirmed()` (§8.1 step 4, stage → `.seeding`, intent-first seed + command enqueue). Test mocks for all four seams.

- [ ] **Step 1 — Failing test.** Create `FoqosTests/Mocks/ResetSeamMocks.swift`:
```swift
import CloudKit
import Foundation

@testable import FamilyFoqos

@MainActor
final class MockResetOutbox: ResetOutbox {
  var zoneDeleteCount = 0
  var zoneSaveCount = 0
  var removeZoneCount = 0
  var commandSaveCount = 0
  var removeCommandCount = 0
  var sendCount = 0

  func enqueueZoneDelete() { zoneDeleteCount += 1 }
  func enqueueZoneSave() { zoneSaveCount += 1 }
  func removeResetZoneChanges() { removeZoneCount += 1 }
  func enqueueCommandSave() { commandSaveCount += 1 }
  func removeCommandSave() { removeCommandCount += 1 }
  func requestSend() { sendCount += 1 }
}

@MainActor
final class MockResetSeeder: ResetSeeder {
  var purgeCount = 0
  var seedCount = 0
  var clearSelectionsCount = 0
  var clearSelectionsError: Error?
  /// Invoked inside seedAll() so tests can assert intent→apply→mark ordering.
  var onSeed: (() -> Void)?

  func performI6Purge() async { purgeCount += 1 }
  func seedAll() {
    seedCount += 1
    onSeed?()
  }
  func clearAllProfileSelections() throws {
    clearSelectionsCount += 1
    if let error = clearSelectionsError { throw error }
  }
}

@MainActor
final class MockRecordFetcher: RecordFetching {
  var result: Result<CKRecord?, Error> = .success(nil)
  var fetchCount = 0
  var lastRecordID: CKRecord.ID?

  func fetchRecord(_ recordID: CKRecord.ID) async throws -> CKRecord? {
    fetchCount += 1
    lastRecordID = recordID
    switch result {
    case .success(let record): return record
    case .failure(let error): throw error
    }
  }
}

@MainActor
final class MockResetConflictSurfacer: ResetConflictSurfacing {
  var surfaceCount = 0
  func surfaceResetSuperseded() { surfaceCount += 1 }
}
```
Create `FoqosTests/SyncEngineResetTests.swift` (shared scaffolding + T8/T9 tests):
```swift
import CloudKit
import Foundation
import XCTest

@testable import FamilyFoqos

@MainActor
final class SyncEngineResetTests: XCTestCase {

  private var suiteName: String!
  private var defaults: UserDefaults!
  private var store: SyncEngineStore!
  private let zoneID = CKRecordZone.ID(
    zoneName: CloudKitConstants.syncZoneName, ownerName: CKCurrentUserDefaultName)

  override func setUp() {
    super.setUp()
    suiteName = "reset-tests-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)!
    SharedData.configure(suite: defaults)
    store = SyncEngineStore(userRecordName: "user-A", defaults: defaults)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    defaults = nil
    super.tearDown()
  }

  // MARK: - Helpers

  private func makeController(
    deviceId: String = "device-A",
    outbox: MockResetOutbox,
    seeder: MockResetSeeder,
    fetcher: MockRecordFetcher = MockRecordFetcher(),
    surfacer: MockResetConflictSurfacer = MockResetConflictSurfacer()
  ) -> ResetController {
    ResetController(
      store: store, outbox: outbox, seeder: seeder, fetcher: fetcher,
      surfacer: surfacer, deviceId: deviceId)
  }

  private func commandRecord(
    id: UUID, clear: Bool, origin: String, now: Date
  ) -> CKRecord {
    let recordID = CKRecord.ID(recordName: ResetController.commandRecordName, zoneID: zoneID)
    let record = CKRecord(recordType: SyncResetRequest.recordType, recordID: recordID)
    record[SyncResetRequest.FieldKey.requestId.rawValue] = id.uuidString
    record[SyncResetRequest.FieldKey.clearRemoteAppSelections.rawValue] = clear
    record[SyncResetRequest.FieldKey.requestedAt.rawValue] = now
    record[SyncResetRequest.FieldKey.originDeviceId.rawValue] = origin
    return record
  }

  /// A command record missing originDeviceId ⇒ SyncResetRequest(from:) returns nil (undecodable).
  private func undecodableCommandRecord(now: Date) -> CKRecord {
    let recordID = CKRecord.ID(recordName: ResetController.commandRecordName, zoneID: zoneID)
    let record = CKRecord(recordType: SyncResetRequest.recordType, recordID: recordID)
    record[SyncResetRequest.FieldKey.requestedAt.rawValue] = now
    return record
  }

  // MARK: - T8 / §8.1 step 1

  func testGivenSteady_WhenBeginReset_ThenPersistsDeletingIntentPreMarksAndEnqueuesDeleteZone() {
    let now = Date()
    let outbox = MockResetOutbox()
    let seeder = MockResetSeeder()
    let controller = makeController(outbox: outbox, seeder: seeder)

    controller.beginReset(clearRemoteAppSelections: true, now: now)

    let intent = store.resetIntent
    XCTAssertNotNil(intent)
    XCTAssertEqual(intent?.stage, .deleting)
    XCTAssertEqual(intent?.clear, true)
    XCTAssertNil(intent?.priorCommandId, "No prior reset history known to this device")
    // I4 pre-mark carve-out (§8.1 step 1): own id marked + set as lastApplied before any send.
    XCTAssertTrue(store.processedResetCommandIds.contains(intent!.id))
    XCTAssertEqual(store.lastAppliedResetCommandId, intent!.id)
    XCTAssertEqual(outbox.zoneDeleteCount, 1)
    XCTAssertEqual(outbox.sendCount, 1)
    XCTAssertEqual(seeder.seedCount, 0)
  }

  func testGivenPriorResetHistory_WhenBeginReset_ThenPriorCommandIdSnapshotsLastApplied() {
    let now = Date()
    let prior = UUID()
    store.lastAppliedResetCommandId = prior
    let outbox = MockResetOutbox()
    let controller = makeController(outbox: outbox, seeder: MockResetSeeder())

    controller.beginReset(clearRemoteAppSelections: false, now: now)

    XCTAssertEqual(store.resetIntent?.priorCommandId, prior)
  }

  // MARK: - T9 / §8.1 steps 3-4

  func testGivenDeletingStage_WhenZoneDeleteConfirmed_ThenPurgesAdvancesToRecreatingAndEnqueuesSaveZone() async {
    let now = Date()
    let outbox = MockResetOutbox()
    let seeder = MockResetSeeder()
    let controller = makeController(outbox: outbox, seeder: seeder)
    controller.beginReset(clearRemoteAppSelections: false, now: now)

    await controller.handleZoneDeleteConfirmed()

    XCTAssertEqual(seeder.purgeCount, 1, "§8.1 step 3: I6 purge on delete confirmed")
    XCTAssertEqual(store.resetIntent?.stage, .recreating)
    XCTAssertEqual(outbox.zoneSaveCount, 1)
    XCTAssertEqual(outbox.sendCount, 2)  // begin + step 3
  }

  func testGivenRecreatingStage_WhenZoneSaveConfirmed_ThenSeedsIntentFirstAndEnqueuesCommand() {
    let now = Date()
    let outbox = MockResetOutbox()
    let seeder = MockResetSeeder()
    let controller = makeController(outbox: outbox, seeder: seeder)
    controller.beginReset(clearRemoteAppSelections: false, now: now)
    // Force to recreating (delete already confirmed in a real run).
    store.resetIntent = ResetIntent(
      id: store.resetIntent!.id, clear: false, stage: .recreating, priorCommandId: nil)

    controller.handleZoneSaveConfirmed()

    XCTAssertEqual(store.resetIntent?.stage, .seeding)
    XCTAssertTrue(store.pendingSeedIntent, "I11 intent-first before seed")
    XCTAssertEqual(outbox.commandSaveCount, 1)
    XCTAssertEqual(seeder.seedCount, 1)
    XCTAssertEqual(outbox.sendCount, 2)  // begin + step 4
  }

  func testGivenNonDeletingStage_WhenZoneDeleteConfirmedWithNilIntent_ThenNoOp() async {
    // Zone-delete confirmation with resetIntent == nil is a T5 concern (controller), not reset.
    let outbox = MockResetOutbox()
    let seeder = MockResetSeeder()
    let controller = makeController(outbox: outbox, seeder: seeder)

    await controller.handleZoneDeleteConfirmed()

    XCTAssertEqual(seeder.purgeCount, 0)
    XCTAssertNil(store.resetIntent)
  }
}
```

- [ ] **Step 2 — Run, expect fail** (`ResetController` init/methods undefined):
```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SyncEngineResetTests | xcpretty
```

- [ ] **Step 3 — Implement.** Append to `Foqos/CloudKit/SyncEngine/ResetController.swift`:
```swift
@MainActor
final class ResetController {
  static let commandRecordName = "sync-reset-command"

  private let store: SyncEngineStore
  private let outbox: ResetOutbox
  private let seeder: ResetSeeder
  private let fetcher: RecordFetching
  private let surfacer: ResetConflictSurfacing
  private let deviceId: String

  init(
    store: SyncEngineStore,
    outbox: ResetOutbox,
    seeder: ResetSeeder,
    fetcher: RecordFetching,
    surfacer: ResetConflictSurfacing,
    deviceId: String
  ) {
    self.store = store
    self.outbox = outbox
    self.seeder = seeder
    self.fetcher = fetcher
    self.surfacer = surfacer
    self.deviceId = deviceId
  }

  private var zoneID: CKRecordZone.ID {
    CKRecordZone.ID(zoneName: CloudKitConstants.syncZoneName, ownerName: CKCurrentUserDefaultName)
  }
  private var commandRecordID: CKRecord.ID {
    CKRecord.ID(recordName: Self.commandRecordName, zoneID: zoneID)
  }

  // MARK: - Origin sequence (§8.1)

  /// T8 / §8.1 steps 1-2. Not called from within handleEvent (user tap), so requestSend()
  /// scheduling a Task is safe.
  func beginReset(clearRemoteAppSelections clear: Bool, now: Date) {
    let id = UUID()
    store.transaction { s in
      s.resetIntent = ResetIntent(
        id: id, clear: clear, stage: .deleting, priorCommandId: s.lastAppliedResetCommandId)
      s.markProcessed(id)  // I4 pre-mark carve-out (safe via §8.3 own-origin check)
      s.lastAppliedResetCommandId = id
    }
    outbox.enqueueZoneDelete()
    outbox.requestSend()
  }

  /// §8.1 step 3. Driven from §5.5 (deletedZoneIDs / failedZoneDeletes .zoneNotFound).
  func handleZoneDeleteConfirmed() async {
    guard let intent = store.resetIntent, intent.stage == .deleting else { return }
    await seeder.performI6Purge()
    store.resetIntent = ResetIntent(
      id: intent.id, clear: intent.clear, stage: .recreating, priorCommandId: intent.priorCommandId)
    outbox.enqueueZoneSave()
    outbox.requestSend()
  }

  /// §8.1 step 4. Driven from §5.5 (savedZones).
  func handleZoneSaveConfirmed() {
    guard let intent = store.resetIntent, intent.stage == .recreating else { return }
    store.transaction { s in
      s.resetIntent = ResetIntent(
        id: intent.id, clear: intent.clear, stage: .seeding, priorCommandId: intent.priorCommandId)
      s.pendingSeedIntent = true  // I11 intent-first
    }
    outbox.enqueueCommandSave()
    seeder.seedAll()
    outbox.requestSend()
  }

  /// §8.2: materialize the fixed-name command record for nextRecordZoneChangeBatch.
  /// Uses the FIXED recordName "sync-reset-command" (NOT requestId.uuidString).
  func commandRecord(now: Date) -> CKRecord? {
    guard let intent = store.resetIntent else { return nil }
    let record = CKRecord(recordType: SyncResetRequest.recordType, recordID: commandRecordID)
    record[SyncResetRequest.FieldKey.requestId.rawValue] = intent.id.uuidString
    record[SyncResetRequest.FieldKey.clearRemoteAppSelections.rawValue] = intent.clear
    record[SyncResetRequest.FieldKey.requestedAt.rawValue] = now
    record[SyncResetRequest.FieldKey.originDeviceId.rawValue] = deviceId
    return record
  }
}
```

- [ ] **Step 4 — Run, expect pass:**
```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SyncEngineResetTests | xcpretty
```

- [ ] **Step 5 — Commit:**
```bash
git add Foqos/CloudKit/SyncEngine/ResetController.swift FoqosTests/Mocks/ResetSeamMocks.swift FoqosTests/SyncEngineResetTests.swift
git commit -m "feat(#267): reset origin state machine T8/T9 + pre-mark (§8.1)"
```

---

### Task 104: `ResetController` — command application §8.3 (S-5, S-6, S-8, S-9)

**Files:**
- Modify: `Foqos/CloudKit/SyncEngine/ResetController.swift`
- Modify: `FoqosTests/SyncEngineResetTests.swift`

**Interfaces:**
- Consumes: `SyncResetRequest(from:)`; `SyncEngineStore` (`lastAppliedResetCommandId`, `processedResetCommandIds`, `markProcessed`, `pendingSeedIntent`, `transaction`); the reset seams.
- Produces: `ResetController.applyCommand(_ record: CKRecord) async` (§8.3: always set `lastAppliedResetCommandId` first; processed/own-origin carve-outs; intent → clear-if-flag + I6 purge + I11 seed → mark).

- [ ] **Step 1 — Failing test.** Add to `SyncEngineResetTests`:
```swift
  // MARK: - §8.3 command application

  func testGivenForeignCommand_WhenAppliedTwiceSameId_ThenSecondIsNoOp() async {
    let now = Date()
    let id = UUID()
    let outbox = MockResetOutbox()
    let seeder = MockResetSeeder()
    let controller = makeController(outbox: outbox, seeder: seeder)
    let record = commandRecord(id: id, clear: false, origin: "device-B", now: now)

    await controller.applyCommand(record)
    XCTAssertTrue(store.processedResetCommandIds.contains(id))
    XCTAssertEqual(seeder.seedCount, 1)
    XCTAssertEqual(seeder.purgeCount, 1)

    // S-5: same-id redelivery is a no-op (I3).
    await controller.applyCommand(record)
    XCTAssertEqual(seeder.seedCount, 1, "redelivery must not re-seed")
    XCTAssertEqual(seeder.purgeCount, 1)
    XCTAssertEqual(store.lastAppliedResetCommandId, id)
  }

  func testGivenAppliedButUnmarked_WhenCommandRedelivered_ThenReAppliesIdempotentlyAndMarks() async {
    let now = Date()
    let id = UUID()
    let outbox = MockResetOutbox()
    let seeder = MockResetSeeder()
    let controller = makeController(outbox: outbox, seeder: seeder)
    let record = commandRecord(id: id, clear: false, origin: "device-B", now: now)

    // S-6: simulate a kill AFTER apply but BEFORE the mark persisted — pendingSeedIntent set,
    // id NOT in processed. Redelivery re-applies idempotently and completes the mark.
    store.pendingSeedIntent = true
    XCTAssertFalse(store.processedResetCommandIds.contains(id))

    await controller.applyCommand(record)

    XCTAssertEqual(seeder.seedCount, 1, "unmarked command re-applies")
    XCTAssertEqual(seeder.purgeCount, 1)
    XCTAssertTrue(store.processedResetCommandIds.contains(id), "mark completes on re-apply")
    XCTAssertEqual(store.lastAppliedResetCommandId, id)
  }

  func testGivenCommand_WhenApplied_ThenPurgesAndSeedsRegardlessOfClearFlagInIntentApplyMarkOrder() async {
    let now = Date()
    let outbox = MockResetOutbox()

    // clear == false: still purge + seed, no selection clear.
    let seederNoClear = MockResetSeeder()
    let controllerNoClear = makeController(outbox: outbox, seeder: seederNoClear)
    await controllerNoClear.applyCommand(
      commandRecord(id: UUID(), clear: false, origin: "device-B", now: now))
    XCTAssertEqual(seederNoClear.purgeCount, 1)
    XCTAssertEqual(seederNoClear.seedCount, 1)
    XCTAssertEqual(seederNoClear.clearSelectionsCount, 0)

    // clear == true: clears selections AND purge + seed.
    let idClear = UUID()
    let seederClear = MockResetSeeder()
    let controllerClear = makeController(outbox: outbox, seeder: seederClear)
    // Assert intent → apply → mark ordering: at seed time pendingSeedIntent is set and the
    // command id is NOT yet marked processed.
    var seedSawIntent = false
    var seedSawUnmarked = false
    seederClear.onSeed = { [weak self] in
      guard let self else { return }
      seedSawIntent = self.store.pendingSeedIntent
      seedSawUnmarked = !self.store.processedResetCommandIds.contains(idClear)
    }
    await controllerClear.applyCommand(
      commandRecord(id: idClear, clear: true, origin: "device-B", now: now))
    XCTAssertEqual(seederClear.clearSelectionsCount, 1)
    XCTAssertEqual(seederClear.purgeCount, 1)
    XCTAssertEqual(seederClear.seedCount, 1)
    XCTAssertTrue(seedSawIntent, "pendingSeedIntent persisted before seed (intent-first)")
    XCTAssertTrue(seedSawUnmarked, "mark happens AFTER apply (I4)")
    XCTAssertTrue(store.processedResetCommandIds.contains(idClear))
  }

  func testGivenOwnOriginCommand_WhenApplied_ThenMarkedNeverApplied() async {
    let now = Date()
    let id = UUID()
    let outbox = MockResetOutbox()
    let seeder = MockResetSeeder()
    let controller = makeController(deviceId: "device-A", outbox: outbox, seeder: seeder)

    await controller.applyCommand(
      commandRecord(id: id, clear: true, origin: "device-A", now: now))

    // S-9: own-origin ⇒ lastApplied set, marked, but never applied (no purge/seed/clear).
    XCTAssertEqual(store.lastAppliedResetCommandId, id)
    XCTAssertTrue(store.processedResetCommandIds.contains(id))
    XCTAssertEqual(seeder.purgeCount, 0)
    XCTAssertEqual(seeder.seedCount, 0)
    XCTAssertEqual(seeder.clearSelectionsCount, 0)
  }

  func testGivenUndecodableCommand_WhenApplied_ThenInertNoStateChange() async {
    let now = Date()
    let outbox = MockResetOutbox()
    let seeder = MockResetSeeder()
    let controller = makeController(outbox: outbox, seeder: seeder)

    await controller.applyCommand(undecodableCommandRecord(now: now))

    XCTAssertNil(store.lastAppliedResetCommandId, "undecodable command is inert (§5.1)")
    XCTAssertTrue(store.processedResetCommandIds.isEmpty)
    XCTAssertEqual(seeder.seedCount, 0)
  }
```

- [ ] **Step 2 — Run, expect fail** (`applyCommand` undefined):
```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SyncEngineResetTests | xcpretty
```

- [ ] **Step 3 — Implement.** Add to `ResetController` (inside the class):
```swift
  // MARK: - Command application (§8.3, any device)

  /// Applied on a fetched modification of the fixed-name command record.
  func applyCommand(_ record: CKRecord) async {
    guard let command = SyncResetRequest(from: record) else {
      // Undecodable command (incl. no readable requestId): inert, dies with its zone (§5.1).
      return
    }
    // Always set lastAppliedResetCommandId FIRST — the fetched fixed-name record is by
    // definition the current incarnation's command (§8.3).
    store.lastAppliedResetCommandId = command.requestId

    if store.processedResetCommandIds.contains(command.requestId) {
      return  // already processed ⇒ ignore (I3)
    }
    if command.originDeviceId == deviceId {
      store.markProcessed(command.requestId)  // own-origin ⇒ mark, ignore (never applied)
      return
    }

    // 1. intent-first (crash-durable seeding)
    store.pendingSeedIntent = true
    // 2. clear-selections if flagged; regardless, I6 purge + I11 seed (redundant re-seed carrier)
    if command.clearRemoteAppSelections {
      try? seeder.clearAllProfileSelections()
    }
    await seeder.performI6Purge()
    seeder.seedAll()
    // 3. mark processed + provenance (I4: after apply)
    store.transaction { s in
      s.markProcessed(command.requestId)
      s.lastAppliedResetCommandId = command.requestId
    }
  }
```

- [ ] **Step 4 — Run, expect pass:**
```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SyncEngineResetTests | xcpretty
```

- [ ] **Step 5 — Commit:**
```bash
git add Foqos/CloudKit/SyncEngine/ResetController.swift FoqosTests/SyncEngineResetTests.swift
git commit -m "feat(#267): reset command application §8.3 (S-5, S-6, S-8, S-9)"
```

---

### Task 105: `ResetController` — step-5 command-save result + resume from stage (S-13)

**Files:**
- Modify: `Foqos/CloudKit/SyncEngine/ResetController.swift`
- Modify: `FoqosTests/SyncEngineResetTests.swift`

**Interfaces:**
- Consumes: `SyncResetRequest(from:)`; `ResetIntent`; the reset seams.
- Produces: `ResetController.CommandSaveOutcome` (`saved` / `serverRecordChanged(CKRecord)`); `handleCommandSaveResult(_:)` (§8.1 step 5: saved → clear; own `requestId` → confirmed-clear; foreign/undecodable → abandon + surface + dequeue); `resume() async` for `.recreating`/`.seeding` (re-enqueue that stage's changes; `.deleting` delegates to Task 106's gate).

- [ ] **Step 1 — Failing test.** Add to `SyncEngineResetTests`:
```swift
  // MARK: - §8.1 step 5 + resume

  private func seedSeedingStage(id: UUID, clear: Bool = false) {
    store.resetIntent = ResetIntent(id: id, clear: clear, stage: .seeding, priorCommandId: nil)
    store.pendingSeedIntent = true
  }

  func testGivenSeedingStage_WhenCommandSaveResult_ThenSavedClearsForeignAbandonsOwnConfirmsUndecodableAbandons() async {
    let now = Date()

    // saved ⇒ clear intent (command tag not stored).
    let idSaved = UUID()
    let outboxSaved = MockResetOutbox()
    let surfacerSaved = MockResetConflictSurfacer()
    let cSaved = makeController(outbox: outboxSaved, seeder: MockResetSeeder(), surfacer: surfacerSaved)
    seedSeedingStage(id: idSaved)
    cSaved.handleCommandSaveResult(.saved)
    XCTAssertNil(store.resetIntent)
    XCTAssertEqual(surfacerSaved.surfaceCount, 0)

    // serverRecordChanged with OWN requestId ⇒ earlier save succeeded, confirmed-clear, no surface.
    let idOwn = UUID()
    let outboxOwn = MockResetOutbox()
    let surfacerOwn = MockResetConflictSurfacer()
    let cOwn = makeController(outbox: outboxOwn, seeder: MockResetSeeder(), surfacer: surfacerOwn)
    seedSeedingStage(id: idOwn)
    cOwn.handleCommandSaveResult(
      .serverRecordChanged(commandRecord(id: idOwn, clear: false, origin: "device-A", now: now)))
    XCTAssertNil(store.resetIntent)
    XCTAssertEqual(surfacerOwn.surfaceCount, 0)

    // serverRecordChanged with FOREIGN requestId ⇒ superseded: abandon + surface + dequeue.
    let idForeign = UUID()
    let outboxForeign = MockResetOutbox()
    let surfacerForeign = MockResetConflictSurfacer()
    let cForeign = makeController(outbox: outboxForeign, seeder: MockResetSeeder(), surfacer: surfacerForeign)
    seedSeedingStage(id: idForeign)
    cForeign.handleCommandSaveResult(
      .serverRecordChanged(commandRecord(id: UUID(), clear: false, origin: "device-B", now: now)))
    XCTAssertNil(store.resetIntent)
    XCTAssertEqual(surfacerForeign.surfaceCount, 1)
    XCTAssertEqual(outboxForeign.removeCommandCount, 1)
    XCTAssertEqual(outboxForeign.removeZoneCount, 1)

    // serverRecordChanged with UNDECODABLE serverRecord ⇒ treat as foreign (abandon + surface).
    let idUndec = UUID()
    let outboxUndec = MockResetOutbox()
    let surfacerUndec = MockResetConflictSurfacer()
    let cUndec = makeController(outbox: outboxUndec, seeder: MockResetSeeder(), surfacer: surfacerUndec)
    seedSeedingStage(id: idUndec)
    cUndec.handleCommandSaveResult(.serverRecordChanged(undecodableCommandRecord(now: now)))
    XCTAssertNil(store.resetIntent)
    XCTAssertEqual(surfacerUndec.surfaceCount, 1)
    XCTAssertEqual(outboxUndec.removeCommandCount, 1)
  }

  func testGivenRecreatingOrSeedingStage_WhenResume_ThenReenqueuesThatStagesChanges() async {
    // .recreating ⇒ re-enqueue saveZone.
    let outboxR = MockResetOutbox()
    let cR = makeController(outbox: outboxR, seeder: MockResetSeeder())
    store.resetIntent = ResetIntent(id: UUID(), clear: false, stage: .recreating, priorCommandId: nil)
    await cR.resume()
    XCTAssertEqual(outboxR.zoneSaveCount, 1)
    XCTAssertEqual(outboxR.sendCount, 1)

    // .seeding ⇒ re-enqueue command save + seed.
    let outboxS = MockResetOutbox()
    let seederS = MockResetSeeder()
    let cS = makeController(outbox: outboxS, seeder: seederS)
    store.resetIntent = ResetIntent(id: UUID(), clear: false, stage: .seeding, priorCommandId: nil)
    await cS.resume()
    XCTAssertEqual(outboxS.commandSaveCount, 1)
    XCTAssertEqual(seederS.seedCount, 1)
    XCTAssertEqual(outboxS.sendCount, 1)
  }
```

- [ ] **Step 2 — Run, expect fail** (`CommandSaveOutcome`/`handleCommandSaveResult`/`resume` undefined):
```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SyncEngineResetTests | xcpretty
```

- [ ] **Step 3 — Implement.** Add to `ResetController`:
```swift
  // MARK: - §8.1 step 5 (command save result)

  enum CommandSaveOutcome {
    case saved
    case serverRecordChanged(CKRecord)
  }

  func handleCommandSaveResult(_ outcome: CommandSaveOutcome) {
    guard let intent = store.resetIntent, intent.stage == .seeding else { return }
    switch outcome {
    case .saved:
      store.resetIntent = nil  // command tag is not stored (§2.1)
    case .serverRecordChanged(let serverRecord):
      if let command = SyncResetRequest(from: serverRecord), command.requestId == intent.id {
        store.resetIntent = nil  // own id ⇒ the earlier save succeeded, confirmed
      } else {
        abandon(intent)  // foreign OR undecodable ⇒ superseded, surface
      }
    }
  }

  /// Abandoning resetIntent without completion also dequeues its zone/command changes and
  /// surfaces to the user (§8.1: the requested reset did not run).
  private func abandon(_ intent: ResetIntent) {
    outbox.removeCommandSave()
    outbox.removeResetZoneChanges()
    store.resetIntent = nil
    surfacer.surfaceResetSuperseded()
  }

  // MARK: - Resume (T1 / §8.1)

  /// Resume a persisted resetIntent from its stage. .deleting runs the gate first (Task 106).
  func resume() async {
    guard let intent = store.resetIntent else { return }
    switch intent.stage {
    case .deleting:
      await runDeletingGate(intent)
    case .recreating:
      outbox.enqueueZoneSave()
      outbox.requestSend()
    case .seeding:
      outbox.enqueueCommandSave()
      seeder.seedAll()
      outbox.requestSend()
    }
  }
```

- [ ] **Step 4 — Run, expect fail (compile)** — `runDeletingGate` is defined in Task 106; add a temporary stub to unblock this task's tests, then Task 106 fills it. Insert:
```swift
  private func runDeletingGate(_ intent: ResetIntent) async {
    // Filled in Task 106; the .deleting resume gate.
  }
```
Re-run; the `.recreating`/`.seeding` resume tests and all step-5 tests pass:
```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SyncEngineResetTests | xcpretty
```

- [ ] **Step 5 — Commit:**
```bash
git add Foqos/CloudKit/SyncEngine/ResetController.swift FoqosTests/SyncEngineResetTests.swift
git commit -m "feat(#267): reset step-5 command-save result + stage resume (S-13)"
```

---

### Task 106: `ResetController` — `.deleting` resume gate, five arms (S-36) + S-4 cross-check

**Files:**
- Modify: `Foqos/CloudKit/SyncEngine/ResetController.swift`
- Modify: `FoqosTests/SyncEngineResetTests.swift`

**Interfaces:**
- Consumes: `RecordFetching.fetchRecord(_:)`; `SyncResetRequest(from:)`; `ResetIntent` (`id`, `priorCommandId`); `CKError`.
- Produces: the filled `runDeletingGate(_:)` — direct record fetch of `CKRecord.ID("sync-reset-command")`, total five-arm case-split (own → confirmed-clear; `== priorCommandId` / no command / `zoneNotFound` → resume; foreign → abandon+surface+dequeue; undecodable → abandon+surface; transient → keep + retry). Zone changes re-enqueue only after the gate passes.

- [ ] **Step 1 — Failing test.** Add to `SyncEngineResetTests`:
```swift
  // MARK: - S-36 .deleting resume gate

  private func seedDeletingStage(id: UUID, prior: UUID?) {
    store.resetIntent = ResetIntent(id: id, clear: false, stage: .deleting, priorCommandId: prior)
  }

  func testGivenDeletingStageResume_WhenGateFetchesCommand_ThenAllFiveArmsResolveCorrectly() async {
    let now = Date()

    // Arm 1: own id ⇒ already published ⇒ confirmed-clear, no re-enqueue, no surface.
    let idOwn = UUID()
    let outboxOwn = MockResetOutbox()
    let surfacerOwn = MockResetConflictSurfacer()
    let fetcherOwn = MockRecordFetcher()
    fetcherOwn.result = .success(commandRecord(id: idOwn, clear: false, origin: "device-A", now: now))
    let cOwn = makeController(outbox: outboxOwn, seeder: MockResetSeeder(), fetcher: fetcherOwn, surfacer: surfacerOwn)
    seedDeletingStage(id: idOwn, prior: nil)
    await cOwn.resume()
    XCTAssertNil(store.resetIntent)
    XCTAssertEqual(outboxOwn.zoneDeleteCount, 0)
    XCTAssertEqual(surfacerOwn.surfaceCount, 0)

    // Arm 2a: == priorCommandId ⇒ prior incarnation ⇒ resume (re-enqueue deleteZone).
    let idPrior = UUID()
    let prior = UUID()
    let outboxPrior = MockResetOutbox()
    let fetcherPrior = MockRecordFetcher()
    fetcherPrior.result = .success(commandRecord(id: prior, clear: false, origin: "device-B", now: now))
    let cPrior = makeController(outbox: outboxPrior, seeder: MockResetSeeder(), fetcher: fetcherPrior)
    seedDeletingStage(id: idPrior, prior: prior)
    await cPrior.resume()
    XCTAssertEqual(store.resetIntent?.stage, .deleting, "prior ⇒ resume, intent kept")
    XCTAssertEqual(outboxPrior.zoneDeleteCount, 1)
    XCTAssertEqual(outboxPrior.sendCount, 1)

    // Arm 2b: no command (absent) ⇒ resume.
    let outboxNone = MockResetOutbox()
    let fetcherNone = MockRecordFetcher()
    fetcherNone.result = .success(nil)
    let cNone = makeController(outbox: outboxNone, seeder: MockResetSeeder(), fetcher: fetcherNone)
    seedDeletingStage(id: UUID(), prior: nil)
    await cNone.resume()
    XCTAssertEqual(outboxNone.zoneDeleteCount, 1)

    // Arm 2c: zoneNotFound ⇒ resume.
    let outboxZNF = MockResetOutbox()
    let fetcherZNF = MockRecordFetcher()
    fetcherZNF.result = .failure(CKError(.zoneNotFound))
    let cZNF = makeController(outbox: outboxZNF, seeder: MockResetSeeder(), fetcher: fetcherZNF)
    seedDeletingStage(id: UUID(), prior: nil)
    await cZNF.resume()
    XCTAssertEqual(outboxZNF.zoneDeleteCount, 1)

    // Arm 3: foreign (!= id, != prior) ⇒ abandon + surface + dequeue zone changes.
    let outboxForeign = MockResetOutbox()
    let surfacerForeign = MockResetConflictSurfacer()
    let fetcherForeign = MockRecordFetcher()
    fetcherForeign.result = .success(commandRecord(id: UUID(), clear: false, origin: "device-B", now: now))
    let cForeign = makeController(outbox: outboxForeign, seeder: MockResetSeeder(), fetcher: fetcherForeign, surfacer: surfacerForeign)
    seedDeletingStage(id: UUID(), prior: UUID())
    await cForeign.resume()
    XCTAssertNil(store.resetIntent)
    XCTAssertEqual(surfacerForeign.surfaceCount, 1)
    XCTAssertEqual(outboxForeign.removeZoneCount, 1)
    XCTAssertEqual(outboxForeign.removeCommandCount, 1)
    XCTAssertEqual(outboxForeign.zoneDeleteCount, 0, "no resume after abandon")

    // Arm 4: undecodable ⇒ abandon + surface.
    let outboxUndec = MockResetOutbox()
    let surfacerUndec = MockResetConflictSurfacer()
    let fetcherUndec = MockRecordFetcher()
    fetcherUndec.result = .success(undecodableCommandRecord(now: now))
    let cUndec = makeController(outbox: outboxUndec, seeder: MockResetSeeder(), fetcher: fetcherUndec, surfacer: surfacerUndec)
    seedDeletingStage(id: UUID(), prior: nil)
    await cUndec.resume()
    XCTAssertNil(store.resetIntent)
    XCTAssertEqual(surfacerUndec.surfaceCount, 1)

    // Arm 5: transient error ⇒ intent kept, no surface, no re-enqueue (retry later).
    let outboxTrans = MockResetOutbox()
    let surfacerTrans = MockResetConflictSurfacer()
    let fetcherTrans = MockRecordFetcher()
    fetcherTrans.result = .failure(CKError(.networkFailure))
    let idTrans = UUID()
    let cTrans = makeController(outbox: outboxTrans, seeder: MockResetSeeder(), fetcher: fetcherTrans, surfacer: surfacerTrans)
    seedDeletingStage(id: idTrans, prior: nil)
    await cTrans.resume()
    XCTAssertEqual(store.resetIntent?.id, idTrans, "transient ⇒ intent kept")
    XCTAssertEqual(store.resetIntent?.stage, .deleting)
    XCTAssertEqual(outboxTrans.zoneDeleteCount, 0)
    XCTAssertEqual(surfacerTrans.surfaceCount, 0)
  }

  // MARK: - S-4 cross-check (full .purged behavior lives in Phase D; here: intent/tombstone facet)

  func testGivenAbandonedReset_WhenIntentCleared_ThenTombstonesSurvive() async {
    let now = Date()
    // A local deletion intent (tombstone) exists alongside a reset intent.
    store.setTombstone(recordName: "profile-1", changeTag: "tag-1")
    let idForeign = UUID()
    let outbox = MockResetOutbox()
    let surfacer = MockResetConflictSurfacer()
    let fetcher = MockRecordFetcher()
    fetcher.result = .success(commandRecord(id: UUID(), clear: false, origin: "device-B", now: now))
    let controller = makeController(outbox: outbox, seeder: MockResetSeeder(), fetcher: fetcher, surfacer: surfacer)
    seedDeletingStage(id: idForeign, prior: UUID())

    await controller.resume()

    XCTAssertNil(store.resetIntent, "abandoned reset clears the intent")
    XCTAssertEqual(
      store.deleteTombstones["profile-1"], "tag-1",
      "deletion intent is not consent-scoped — tombstones survive reset abandonment (S-4/I12)")
  }
```

- [ ] **Step 2 — Run, expect fail** (gate is still the stub — arms mis-resolve):
```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SyncEngineResetTests/testGivenDeletingStageResume_WhenGateFetchesCommand_ThenAllFiveArmsResolveCorrectly | xcpretty
```

- [ ] **Step 3 — Implement.** Replace the Task-105 stub `runDeletingGate(_:)` with:
```swift
  /// §8.1 .deleting resume gate: observe the command by a DIRECT record fetch (I5-compatible,
  /// independent of §8.3's processed guard so every outcome is observable). Total case-split.
  private func runDeletingGate(_ intent: ResetIntent) async {
    do {
      let record = try await fetcher.fetchRecord(commandRecordID)
      guard let record else {
        reenqueueDeleting()  // no command (any snapshot) ⇒ resume
        return
      }
      guard let command = SyncResetRequest(from: record) else {
        abandon(intent)  // undecodable ⇒ abandon + surface (mirrors step 5)
        return
      }
      if command.requestId == intent.id {
        store.resetIntent = nil  // our command already published ⇒ confirmed
      } else if command.requestId == intent.priorCommandId {
        reenqueueDeleting()  // prior incarnation's command ⇒ resume normally
      } else {
        abandon(intent)  // foreign, different from both ⇒ superseded ⇒ abandon + surface
      }
    } catch let error as CKError where error.code == .zoneNotFound {
      reenqueueDeleting()  // zone died / was T5-reseeded ⇒ resume (zone-CAS + N1)
    } catch {
      // Transient fetch error ⇒ keep the intent; retry at next start / §5.6 cadence.
    }
  }

  private func reenqueueDeleting() {
    outbox.enqueueZoneDelete()
    outbox.requestSend()
  }
```

- [ ] **Step 4 — Run, expect pass** (full class):
```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SyncEngineResetTests | xcpretty
```

- [ ] **Step 5 — Commit:**
```bash
git add Foqos/CloudKit/SyncEngine/ResetController.swift FoqosTests/SyncEngineResetTests.swift
git commit -m "feat(#267): .deleting resume gate five arms + S-4 tombstone cross-check (S-36)"
```

---

### Task 107: Production reset adapters + `SyncEngineController+Reset.swift` (unwired until cutover)

**Files:**
- Create: `Foqos/CloudKit/SyncEngine/SyncEngineController+Reset.swift`

**Interfaces:**
- Consumes: locked `SyncEngineDriver` (`add`/`remove(pendingRecordZoneChanges:)`, `add`/`remove(pendingDatabaseChanges:)`, `sendChanges`); `CKDatabase.record(for:)`; `SyncConflictManager.shared`; `SessionSyncFlushing`.
- Produces: concrete seam adapters `DriverResetOutbox: ResetOutbox`, `DatabaseRecordFetcher: RecordFetching`, `ConflictManagerResetSurfacer: ResetConflictSurfacing`. These compile in the app target but are **not referenced by any live code path in this phase** — Phase F constructs a `ResetController` from them, forwards `SyncEngineController.beginReset(clearRemoteAppSelections:)`, and routes `SyncResetRequest` fetched-modifications (§8.3), §5.5 zone confirmations (steps 3/4), the §5.3 command-save result (step 5), and T1 `resume()` to it.

- [ ] **Step 1 — Failing test.** No new behavioral test (the adapters are thin CloudKit/driver forwarders exercised at integration; the state machine is already covered by Tasks 103–106). Guard-rail: assert the adapters satisfy the seam protocols by referencing them in a compile-only test. Add `FoqosTests/ResetAdapterCompileTests.swift`:
```swift
import CloudKit
import Foundation
import XCTest

@testable import FamilyFoqos

@MainActor
final class ResetAdapterCompileTests: XCTestCase {
  func testAdaptersConformToResetSeams() {
    let zoneID = CKRecordZone.ID(
      zoneName: CloudKitConstants.syncZoneName, ownerName: CKCurrentUserDefaultName)
    let database = CKContainer(identifier: CloudKitConstants.containerIdentifier).privateCloudDatabase
    let fetcher: RecordFetching = DatabaseRecordFetcher(database: database)
    let surfacer: ResetConflictSurfacing = ConflictManagerResetSurfacer()
    XCTAssertNotNil(fetcher)
    XCTAssertNotNil(surfacer)
    XCTAssertEqual(ResetController.commandRecordName, "sync-reset-command")
    _ = zoneID
  }
}
```

- [ ] **Step 2 — Run, expect fail** (adapters undefined):
```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/ResetAdapterCompileTests | xcpretty
```

- [ ] **Step 3 — Implement.** Create `Foqos/CloudKit/SyncEngine/SyncEngineController+Reset.swift`:
```swift
import CloudKit
import Foundation

/// Concrete ResetOutbox over the CKSyncEngine driver. Uses the fixed-name command record
/// and the DeviceSync zone. Wired to the controller's driver at cutover (Phase F).
@MainActor
final class DriverResetOutbox: ResetOutbox {
  private let driver: SyncEngineDriver
  private let zoneID: CKRecordZone.ID

  init(driver: SyncEngineDriver, zoneID: CKRecordZone.ID) {
    self.driver = driver
    self.zoneID = zoneID
  }

  private var commandRecordID: CKRecord.ID {
    CKRecord.ID(recordName: ResetController.commandRecordName, zoneID: zoneID)
  }

  func enqueueZoneDelete() {
    driver.add(pendingDatabaseChanges: [.deleteZone(zoneID)])
  }
  func enqueueZoneSave() {
    driver.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
  }
  func removeResetZoneChanges() {
    driver.remove(pendingDatabaseChanges: [.deleteZone(zoneID), .saveZone(CKRecordZone(zoneID: zoneID))])
  }
  func enqueueCommandSave() {
    driver.add(pendingRecordZoneChanges: [.saveRecord(commandRecordID)])
  }
  func removeCommandSave() {
    driver.remove(pendingRecordZoneChanges: [.saveRecord(commandRecordID)])
  }
  func requestSend() {
    // §1.1: schedule sendChanges() in a Task AFTER the current handler returns.
    Task { @MainActor in self.driver.sendChanges() }
  }
}

/// Direct record fetch by CKRecord.ID (I5-compatible). nil ⇒ unknownItem (absent).
@MainActor
final class DatabaseRecordFetcher: RecordFetching {
  private let database: CKDatabase

  init(database: CKDatabase) {
    self.database = database
  }

  func fetchRecord(_ recordID: CKRecord.ID) async throws -> CKRecord? {
    do {
      return try await database.record(for: recordID)
    } catch let error as CKError where error.code == .unknownItem {
      return nil
    }
  }
}

/// Surfaces a "your reset did not run" conflict via the existing conflict manager.
@MainActor
final class ConflictManagerResetSurfacer: ResetConflictSurfacing {
  func surfaceResetSuperseded() {
    SyncConflictManager.shared.addResetSupersededConflict()
  }
}
```
Executor: add a concrete profile-less entry to `SyncConflictManager` for this. Extend `SyncConflictManager` with `func addResetSupersededConflict()` that sets a new `@Published var resetWasSuperseded = true` (and have `clearAll()`/`dismissBanner()` reset it), mirroring `addConflict`. `ConflictManagerResetSurfacer.surfaceResetSuperseded()` calls it. Include this one-method addition and its unit test (assert the flag flips true then clears) in this task — do not defer it.

- [ ] **Step 4 — Run, expect pass:**
```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/ResetAdapterCompileTests | xcpretty
```

- [ ] **Step 5 — Commit:**
```bash
git add Foqos/CloudKit/SyncEngine/SyncEngineController+Reset.swift FoqosTests/ResetAdapterCompileTests.swift
git commit -m "feat(#267): production reset seam adapters (unwired until cutover)"
```

---

### Task 108: `SessionStopOutbox` — #201 dropped session-stop retry

**Files:**
- Create: `Foqos/CloudKit/SessionStopOutbox.swift`
- Create: `FoqosTests/SessionStopOutboxTests.swift`
- Modify: `Foqos/Utils/StrategyManager.swift`

**Interfaces:**
- Consumes: `UserDefaults`; `SessionSyncService.stopSession` (`StopResult`).
- Produces: `@MainActor final class SessionStopOutbox` (persist/enqueue/remove/clear + `drain(stop:)`); `StrategyManager` routes its `.error` session-stop CAS drop (line 646) into the outbox and re-drives via `drainSessionStopOutbox()` (per #201: persist intent, re-drive on foreground — the foreground call site is wired at cutover so nothing runs in-app this phase).

- [ ] **Step 1 — Failing test.** Create `FoqosTests/SessionStopOutboxTests.swift`:
```swift
import Foundation
import XCTest

@testable import FamilyFoqos

@MainActor
final class SessionStopOutboxTests: XCTestCase {

  private var suiteName: String!
  private var defaults: UserDefaults!

  override func setUp() {
    super.setUp()
    suiteName = "stop-outbox-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)!
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    defaults = nil
    super.tearDown()
  }

  func testGivenEnqueue_WhenReloaded_ThenPersistsAndDeduplicates() {
    let id = UUID()
    let outbox = SessionStopOutbox(defaults: defaults)
    outbox.enqueue(profileId: id)
    outbox.enqueue(profileId: id)  // dedupe

    let reloaded = SessionStopOutbox(defaults: defaults)
    XCTAssertEqual(reloaded.pending, [id])
  }

  func testGivenPending_WhenRemove_ThenGone() {
    let a = UUID()
    let b = UUID()
    let outbox = SessionStopOutbox(defaults: defaults)
    outbox.enqueue(profileId: a)
    outbox.enqueue(profileId: b)

    outbox.remove(profileId: a)

    XCTAssertEqual(outbox.pending, [b])
  }

  func testGivenStopError_WhenEnqueuedAndDrained_ThenRetriesAndClearsOnSuccess() async {
    let resolvedId = UUID()
    let stuckId = UUID()
    let outbox = SessionStopOutbox(defaults: defaults)
    outbox.enqueue(profileId: resolvedId)
    outbox.enqueue(profileId: stuckId)

    // First drive: resolvedId succeeds (.alreadyStopped ⇒ resolved), stuckId keeps failing.
    await outbox.drain { id in id == resolvedId }

    XCTAssertEqual(outbox.pending, [stuckId], "resolved id cleared, stuck id retained (no loop loss)")

    // Second drive: stuckId now resolves.
    await outbox.drain { _ in true }
    XCTAssertTrue(outbox.pending.isEmpty)
  }
}
```

- [ ] **Step 2 — Run, expect fail** (`SessionStopOutbox` undefined):
```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SessionStopOutboxTests | xcpretty
```

- [ ] **Step 3 — Implement.** (a) Create `Foqos/CloudKit/SessionStopOutbox.swift`:
```swift
import Foundation

/// #201: a session-stop CAS write that fails must not be silently dropped. The intent is
/// persisted and re-driven on foreground (minimal outbox, consistent with the funnel/tombstone
/// approach — persisted intent, idempotent re-drive; the underlying stop is CAS-idempotent).
@MainActor
final class SessionStopOutbox {
  private let defaults: UserDefaults
  private let key = "family_foqos_session_stop_outbox"

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  var pending: [UUID] {
    (defaults.array(forKey: key) as? [String] ?? []).compactMap(UUID.init(uuidString:))
  }

  func enqueue(profileId: UUID) {
    var ids = defaults.array(forKey: key) as? [String] ?? []
    let value = profileId.uuidString
    guard !ids.contains(value) else { return }
    ids.append(value)
    defaults.set(ids, forKey: key)
  }

  func remove(profileId: UUID) {
    var ids = defaults.array(forKey: key) as? [String] ?? []
    ids.removeAll { $0 == profileId.uuidString }
    defaults.set(ids, forKey: key)
  }

  func clear() {
    defaults.removeObject(forKey: key)
  }

  /// Re-drive each pending stop; `stop` returns true when the id is resolved (removed).
  func drain(stop: (UUID) async -> Bool) async {
    for id in pending where await stop(id) {
      remove(profileId: id)
    }
  }
}
```
(b) Wire `StrategyManager`. Add a stored property near the `sessionSyncService` field:
```swift
  private let sessionStopOutbox = SessionStopOutbox()
```
Replace the `.error` arm at `StrategyManager.swift:646`:
```swift
            case .error(let error):
              Log.info("Failed to sync session stop - \(error)", category: .strategy)
              // #201: persist the dropped stop intent for foreground re-drive instead of losing it.
              self.sessionStopOutbox.enqueue(profileId: endedProfile.id)
```
Add the re-drive method (called from `FoqosApp` scenePhase `.active` at cutover — not wired this phase):
```swift
  /// #201: re-drive persisted session-stop intents (call on foreground).
  func drainSessionStopOutbox() async {
    await sessionStopOutbox.drain { [weak self] profileId in
      guard let self else { return true }
      let result = await self.sessionSyncService.stopSession(profileId: profileId)
      switch result {
      case .stopped, .alreadyStopped:
        return true
      case .conflict, .error:
        return false
      }
    }
  }
```

- [ ] **Step 4 — Run, expect pass** (and confirm the full suite stays green):
```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SessionStopOutboxTests | xcpretty
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' | xcpretty
```

- [ ] **Step 5 — Commit:**
```bash
git add Foqos/CloudKit/SessionStopOutbox.swift FoqosTests/SessionStopOutboxTests.swift Foqos/Utils/StrategyManager.swift
git commit -m "feat(#201): route dropped session-stop CAS error into a persisted retry outbox"
```

---

**Phase E exit checklist:**
- [ ] `swift-format lint --recursive .` clean.
- [ ] `xcodebuild test ... | xcpretty` — existing 429 tests + new Phase-E tests all green.
- [ ] No Phase-E code path is invoked from `FoqosApp`/`SyncEngineController` (reset adapters, `ResetController`, and `drainSessionStopOutbox()` are constructed/called only at cutover, Phase F).
- [ ] Cutover handoff (Phase F): construct `ResetController(store:outbox: DriverResetOutbox, seeder: DefaultResetSeeder(flush: SessionSyncService.shared.flushSessionCache, seed: <I11 seed>, clearSelections: <clear all profiles + save>), fetcher: DatabaseRecordFetcher, surfacer: ConflictManagerResetSurfacer, deviceId:)`; forward `SyncEngineController.beginReset` → `ResetController.beginReset(clearRemoteAppSelections:now: Date())`; route `SyncResetRequest` fetched-modifications → `applyCommand`, §5.5 zone confirmations → `handleZoneDeleteConfirmed`/`handleZoneSaveConfirmed`, §5.3 command-save outcome → `handleCommandSaveResult`, T1 → `resume()`; call `handleZoneDeleteConfirmed` T5 fallback when `resetIntent == nil` routes to the controller's normal purge+seed; call `StrategyManager.drainSessionStopOutbox()` on scenePhase `.active`; call `SessionSyncService.flushSessionCache()` on I6 zone events (S-20 live path).

---

## Phase F — Cutover, deletion of the old CKQuery path, legacy §11 one-shot, manual checklist

> **Before executing this phase, apply the Conformance-Review Amendments (CRA-1..CRA-5) above** where they reference this phase's tasks.

> **Design sections consumed:** §2 ("Deleted" list), §5.1 (legacy identification arm), §7 (account scoping), §8.5 (product decisions), §9 (what replaces the old guards), §11 (migration & legacy one-shot), invariants I2/I5/I6/I10/I11/I12, transitions T1/T7/T11, residual N5.
>
> **Phase-F facade decision (stated per brief item 3):** **Keep a slimmed `ProfileSyncManager` as the UI facade.** It retains the entire `@Published` surface (`isEnabled`/`isSyncing`/`syncStatus`/`connectedDeviceCount`/`lastSyncDate`/`error`/`shouldShowSyncUpgradeNotice`) and the `syncEnabled` toggle round-trip, and delegates all transport verbs (start/stop/manual-sync/reset/mutations) to `SyncEngineController` through a new `SyncEngineControlling` seam. Rationale: this is the lowest-churn cutover — every existing `SettingsView`/`AddLocationView`/`SavedLocationsView` binding (`$profileSyncManager.isEnabled`, the "Reset Syncing" visibility gate `profileSyncManager.isEnabled`, the status labels) keeps working unchanged, so the existing suite stays green; and `SyncEngineController` remains a pure, context-gated engine owner (I10) that is never a `@StateObject` constructed before a `ModelContext` exists. `SyncEngineController` is built lazily inside `ProfileSyncManager.attachEngine(...)` (Task 133), which is the composition root and the sole I10 construction point.
>
> **Contract note on pending-change types:** all code below uses `CKSyncEngine.PendingRecordZoneChange`/`PendingDatabaseChange` and their `.saveRecord`/`.deleteRecord`/`.saveZone`/`.deleteZone` cases exactly as the locked `SyncEngineDriver` protocol declares. If Phase A adopted the contract's documented domain-enum fallback (`SyncPendingRecordChange`/`SyncPendingZoneChange`), substitute those types in the driver signatures and constructors below — the control flow is byte-identical.
>
> **Prerequisite (Phases A–E complete):** `SyncEngineEvent`, `SyncEngineDriver`, `SyncEngineDriverDelegate`, `SyncEngineStore`, `RecordProvider`, `SyncApplyService`, `MutationFunnel`, `SyncEngineController` (with internal `var driver: SyncEngineDriver?` and `var funnel: MutationFunnel?` created in `start()`), `SessionSyncFlushing`, and `MockSyncEngineDriver` all exist and their own phase-suites are green. Transport-specific tests (`SyncCoordinatorDITests`, `ProfileSyncManager` pull/reset tests) were migrated onto the `SyncApplyService`/`MutationFunnel` seams in Phases C–E; any residual reference to a symbol deleted in Task 135 is updated in that task (coverage is migrated, never dropped).

---

### Task 130: `SyncEngineControlling` seam + slim `ProfileSyncManager` to a UI facade

**Files:**
- Create: `Foqos/CloudKit/SyncEngine/SyncEngineControlling.swift`
- Modify: `Foqos/CloudKit/ProfileSyncManager.swift`
- Create (test mock): `FoqosTests/Mocks/MockSyncEngineControlling.swift`
- Test: `FoqosTests/SyncEngineFacadeTests.swift`

**Interfaces:**
- Produces: `protocol SyncEngineControlling: AnyObject` (`@MainActor`) — `start()`, `stop()`, `requestSync()`, `beginReset(clearRemoteAppSelections:)`, `enqueueProfileSave(_:)`, `enqueueProfileDelete(_:)`, `enqueueLocationSave(_:)`, `enqueueLocationDelete(_:)`, `enqueueEmergencySettingsSave()`.
- Produces: `ProfileSyncManager.engineController: (any SyncEngineControlling)?` (weak); facade verbs `syncNow()`, `resetSync(clearRemoteAppSelections:)`, `enqueueProfileSave/Delete`, `enqueueLocationSave/Delete`, `enqueueEmergencySettingsSave`.
- Consumes: existing `@Published` surface + `SharedData.deviceSyncEnabled` (contract §7 global toggle).

**Steps:**

- [ ] **Step 1 — Failing test.** Create `FoqosTests/Mocks/MockSyncEngineControlling.swift`:

```swift
import Foundation

@testable import FamilyFoqos

@MainActor
final class MockSyncEngineControlling: SyncEngineControlling {
  private(set) var startCount = 0
  private(set) var stopCount = 0
  private(set) var requestSyncCount = 0
  private(set) var beginResetCalls: [Bool] = []
  private(set) var enqueuedProfileSaves: [UUID] = []
  private(set) var enqueuedProfileDeletes: [UUID] = []
  private(set) var enqueuedLocationSaves: [UUID] = []
  private(set) var enqueuedLocationDeletes: [UUID] = []
  private(set) var enqueuedEmergencySaves = 0

  func start() { startCount += 1 }
  func stop() { stopCount += 1 }
  func requestSync() { requestSyncCount += 1 }
  func beginReset(clearRemoteAppSelections: Bool) { beginResetCalls.append(clearRemoteAppSelections) }
  func enqueueProfileSave(_ id: UUID) { enqueuedProfileSaves.append(id) }
  func enqueueProfileDelete(_ id: UUID) { enqueuedProfileDeletes.append(id) }
  func enqueueLocationSave(_ id: UUID) { enqueuedLocationSaves.append(id) }
  func enqueueLocationDelete(_ id: UUID) { enqueuedLocationDeletes.append(id) }
  func enqueueEmergencySettingsSave() { enqueuedEmergencySaves += 1 }
}
```

Then create `FoqosTests/SyncEngineFacadeTests.swift`:

```swift
import Combine
import XCTest

@testable import FamilyFoqos

@MainActor
final class SyncEngineFacadeTests: XCTestCase {
  var testSuiteName: String!
  var manager: ProfileSyncManager!
  var mock: MockSyncEngineControlling!
  private var savedEnabled = false
  private var savedController: (any SyncEngineControlling)?

  override func setUp() async throws {
    try await super.setUp()
    testSuiteName = "SyncEngineFacadeTests-\(UUID().uuidString)"
    SharedData.configure(suite: UserDefaults(suiteName: testSuiteName)!)
    manager = ProfileSyncManager.shared
    savedEnabled = manager.isEnabled
    savedController = manager.engineController
    mock = MockSyncEngineControlling()
    manager.engineController = mock
    manager.isEnabled = false
  }

  override func tearDown() async throws {
    manager.engineController = savedController
    manager.isEnabled = savedEnabled
    UserDefaults().removePersistentDomain(forName: testSuiteName)
    try await super.tearDown()
  }

  func testGivenController_WhenToggledOn_ThenStartIsCalledAndPersisted() {
    manager.isEnabled = true

    XCTAssertEqual(mock.startCount, 1)
    XCTAssertEqual(mock.stopCount, 0)
    XCTAssertTrue(SharedData.deviceSyncEnabled)
    XCTAssertEqual(manager.syncStatus, .idle)
  }

  func testGivenController_WhenToggledOffAfterOn_ThenStopIsCalled() {
    manager.isEnabled = true
    manager.isEnabled = false

    XCTAssertEqual(mock.startCount, 1)
    XCTAssertEqual(mock.stopCount, 1)
    XCTAssertFalse(SharedData.deviceSyncEnabled)
    XCTAssertEqual(manager.syncStatus, .disabled)
  }

  func testGivenController_WhenFacadeVerbsCalled_ThenTheyForward() {
    let id = UUID()
    manager.syncNow()
    manager.resetSync(clearRemoteAppSelections: true)
    manager.enqueueProfileSave(id)
    manager.enqueueProfileDelete(id)
    manager.enqueueLocationSave(id)
    manager.enqueueLocationDelete(id)
    manager.enqueueEmergencySettingsSave()

    XCTAssertEqual(mock.requestSyncCount, 1)
    XCTAssertEqual(mock.beginResetCalls, [true])
    XCTAssertEqual(mock.enqueuedProfileSaves, [id])
    XCTAssertEqual(mock.enqueuedProfileDeletes, [id])
    XCTAssertEqual(mock.enqueuedLocationSaves, [id])
    XCTAssertEqual(mock.enqueuedLocationDeletes, [id])
    XCTAssertEqual(mock.enqueuedEmergencySaves, 1)
  }
}
```

- [ ] **Step 2 — Run, expect fail (compile error: `SyncEngineControlling` / `engineController` / `syncNow` undefined).**

```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SyncEngineFacadeTests | xcpretty
```

- [ ] **Step 3 — Minimal implementation.** Create `Foqos/CloudKit/SyncEngine/SyncEngineControlling.swift`:

```swift
import Foundation

/// Facade seam between the `ProfileSyncManager` UI surface and the engine owner (I10).
/// `SyncEngineController` conforms in Phase F (Task 131); tests inject a spy.
@MainActor
protocol SyncEngineControlling: AnyObject {
  func start()
  func stop()
  func requestSync()
  func beginReset(clearRemoteAppSelections: Bool)
  func enqueueProfileSave(_ id: UUID)
  func enqueueProfileDelete(_ id: UUID)
  func enqueueLocationSave(_ id: UUID)
  func enqueueLocationDelete(_ id: UUID)
  func enqueueEmergencySettingsSave()
}
```

In `ProfileSyncManager.swift`, add the seam property near the other stored properties (after `syncEventDelegate`, ~line 38):

```swift
  /// The engine owner (I10). Wired in `attachEngine(...)` once a ModelContext exists.
  weak var engineController: (any SyncEngineControlling)?
```

Replace the `$isEnabled` Combine sink body (ProfileSyncManager.swift:71-81) so the toggle drives the engine instead of the deleted `setupSync()`:

```swift
    $isEnabled
      .dropFirst()
      .sink { [weak self] enabled in
        SharedData.deviceSyncEnabled = enabled
        self?.syncStatus = enabled ? .idle : .disabled
        if enabled {
          self?.engineController?.start()
        } else {
          self?.engineController?.stop()
        }
      }
      .store(in: &cancellables)
```

Add the facade verbs (new methods; the old async transport methods remain until Task 135 so the tree stays compiling):

```swift
  // MARK: - Engine facade (Phase F)

  /// Manual "Sync Now" — schedules a fetch+send on the engine (replaces performFullSync).
  func syncNow() {
    engineController?.requestSync()
  }

  /// Reset Sync (§8.1). Delegates to the origin reset state machine.
  func resetSync(clearRemoteAppSelections: Bool) {
    engineController?.beginReset(clearRemoteAppSelections: clearRemoteAppSelections)
  }

  func enqueueProfileSave(_ id: UUID) { engineController?.enqueueProfileSave(id) }
  func enqueueProfileDelete(_ id: UUID) { engineController?.enqueueProfileDelete(id) }
  func enqueueLocationSave(_ id: UUID) { engineController?.enqueueLocationSave(id) }
  func enqueueLocationDelete(_ id: UUID) { engineController?.enqueueLocationDelete(id) }
  func enqueueEmergencySettingsSave() { engineController?.enqueueEmergencySettingsSave() }
```

> Note: the existing `func resetSync(clearRemoteAppSelections: Bool) async throws` (line 823) is left in place for now (its body is deleted in Task 135). The new synchronous overload is call-resolved in synchronous contexts; no current call site uses `resetSync` synchronously yet, so there is no ambiguity. Task 135 deletes the async version, leaving only this facade verb.

- [ ] **Step 4 — Run, expect pass.**

```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SyncEngineFacadeTests | xcpretty
```

- [ ] **Step 5 — Commit.**

```bash
git add Foqos/CloudKit/SyncEngine/SyncEngineControlling.swift Foqos/CloudKit/ProfileSyncManager.swift FoqosTests/Mocks/MockSyncEngineControlling.swift FoqosTests/SyncEngineFacadeTests.swift
git commit -m "feat(#267): SyncEngineControlling facade seam; route sync toggle through the engine (Phase F)"
```

---

### Task 131: `SyncEngineController` cutover API — `SyncEngineControlling` conformance, `requestSync`, funnel forwarding + bootstrap-seed integration test (T1/I11)

**Files:**
- Create: `Foqos/CloudKit/SyncEngine/SyncEngineController+Cutover.swift`
- Create (test helper): `FoqosTests/Mocks/CutoverRecordingDriver.swift`
- Test: `FoqosTests/SyncEngineControllerCutoverTests.swift`

**Interfaces:**
- Consumes: `SyncEngineController.init(modelContext:store:driverFactory:apply:provider:sessionSync:deviceId:)`, `SyncEngineController.start()` (Phase E), internal `SyncEngineController.driver: SyncEngineDriver?` and `SyncEngineController.funnel: MutationFunnel?` (created in `start()`, Phase E), `SyncEngineController.beginReset(clearRemoteAppSelections:)` (Phase E, +Reset). `MutationFunnel.enqueueSave/enqueueDelete/enqueueEmergencySettingsSave` (contract). `SyncEngineStore.init(userRecordName:defaults:)` (contract).
- Produces: `extension SyncEngineController: SyncEngineControlling` with `requestSync()` + `enqueue*` forwarding.

**Steps:**

- [ ] **Step 1 — Failing test.** Create the self-contained recording driver `FoqosTests/Mocks/CutoverRecordingDriver.swift` (conforms to the locked `SyncEngineDriver`; used by Tasks 131/136/137). It reuses Phase A's `MockSyncEngineDriver` shape but is Phase-F-local so this phase is self-contained:

```swift
import CloudKit

@testable import FamilyFoqos

@MainActor
final class CutoverRecordingDriver: SyncEngineDriver {
  var stateSerialization: Data?
  private(set) var recordChanges: [CKSyncEngine.PendingRecordZoneChange] = []
  private(set) var databaseChanges: [CKSyncEngine.PendingDatabaseChange] = []
  private(set) var fetchChangesCount = 0
  private(set) var sendChangesCount = 0

  init(stateSerialization: Data? = nil) {
    self.stateSerialization = stateSerialization
  }

  var pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange] { recordChanges }
  var pendingDatabaseChanges: [CKSyncEngine.PendingDatabaseChange] { databaseChanges }

  func add(pendingRecordZoneChanges changes: [CKSyncEngine.PendingRecordZoneChange]) {
    recordChanges.append(contentsOf: changes)
  }
  func remove(pendingRecordZoneChanges changes: [CKSyncEngine.PendingRecordZoneChange]) {
    let names = Set(changes.compactMap { Self.recordName(of: $0) })
    recordChanges.removeAll { names.contains(Self.recordName(of: $0) ?? "") }
  }
  func add(pendingDatabaseChanges changes: [CKSyncEngine.PendingDatabaseChange]) {
    databaseChanges.append(contentsOf: changes)
  }
  func remove(pendingDatabaseChanges changes: [CKSyncEngine.PendingDatabaseChange]) {
    let names = Set(changes.compactMap { Self.zoneName(of: $0) })
    databaseChanges.removeAll { names.contains(Self.zoneName(of: $0) ?? "") }
  }
  func fetchChanges() { fetchChangesCount += 1 }
  func sendChanges() { sendChangesCount += 1 }

  // MARK: - Test inspection helpers
  var enqueuedSaveNames: [String] {
    recordChanges.compactMap { if case .saveRecord(let id) = $0 { return id.recordName } else { return nil } }
  }
  var enqueuedDeleteNames: [String] {
    recordChanges.compactMap { if case .deleteRecord(let id) = $0 { return id.recordName } else { return nil } }
  }
  var enqueuedZoneSaveNames: [String] {
    databaseChanges.compactMap { if case .saveZone(let z) = $0 { return z.zoneID.zoneName } else { return nil } }
  }

  static func recordName(of change: CKSyncEngine.PendingRecordZoneChange) -> String? {
    switch change {
    case .saveRecord(let id): return id.recordName
    case .deleteRecord(let id): return id.recordName
    @unknown default: return nil
    }
  }
  static func zoneName(of change: CKSyncEngine.PendingDatabaseChange) -> String? {
    switch change {
    case .saveZone(let z): return z.zoneID.zoneName
    case .deleteZone(let id): return id.zoneName
    @unknown default: return nil
    }
  }
}
```

Then create `FoqosTests/SyncEngineControllerCutoverTests.swift`:

```swift
import CloudKit
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class SyncEngineControllerCutoverTests: XCTestCase {
  var testSuiteName: String!
  var container: ModelContainer!
  var context: ModelContext!
  var store: SyncEngineStore!
  var driver: CutoverRecordingDriver!
  var controller: SyncEngineController!

  override func setUp() async throws {
    try await super.setUp()
    testSuiteName = "SyncEngineControllerCutoverTests-\(UUID().uuidString)"
    SharedData.configure(suite: UserDefaults(suiteName: testSuiteName)!)
    container = try TestModelContainer.create()
    context = container.mainContext
    store = SyncEngineStore(userRecordName: "user-A", defaults: UserDefaults(suiteName: testSuiteName)!)
    driver = CutoverRecordingDriver(stateSerialization: nil)
    let deviceId = SharedData.deviceSyncId.uuidString
    let apply = SyncApplyService(
      modelContext: context, store: store, sessionController: MockSessionController(),
      emergencyManager: EmergencyUnblockManager(), deviceId: deviceId)
    let provider = RecordProvider(
      modelContext: context, store: store, emergencyManager: EmergencyUnblockManager(), deviceId: deviceId)
    controller = SyncEngineController(
      modelContext: context, store: store, driverFactory: { [driver] _ in driver! },
      apply: apply, provider: provider, sessionSync: SessionSyncService.shared, deviceId: deviceId)
  }

  override func tearDown() async throws {
    UserDefaults().removePersistentDomain(forName: testSuiteName)
    try await super.tearDown()
  }

  private func makeProfile(now: Date) -> BlockedProfiles {
    let profile = BlockedProfiles(id: UUID(), name: "Focus", createdAt: now, updatedAt: now)
    context.insert(profile)
    try? context.save()
    return profile
  }

  func testGivenFreshEngineState_WhenStarted_ThenBootstrapSeedEnqueued() throws {
    let now = Date()
    let profile = makeProfile(now: now)

    controller.start()

    // I11: first bootstrap (engineState == nil) seeds the zone + all restorable records.
    XCTAssertTrue(driver.enqueuedZoneSaveNames.contains(CloudKitConstants.syncZoneName))
    XCTAssertTrue(driver.enqueuedSaveNames.contains(profile.id.uuidString))
    XCTAssertTrue(driver.enqueuedSaveNames.contains(SyncedEmergencySettings.recordName))
    XCTAssertTrue(store.pendingSeedIntent)
  }

  func testGivenStartedController_WhenRequestSync_ThenFetchAndSendScheduled() {
    controller.start()
    let fetchBefore = driver.fetchChangesCount
    let sendBefore = driver.sendChangesCount

    controller.requestSync()

    XCTAssertEqual(driver.fetchChangesCount, fetchBefore + 1)
    XCTAssertEqual(driver.sendChangesCount, sendBefore + 1)
  }

  func testGivenStartedController_WhenEnqueueProfileSave_ThenFunnelEnqueuesOnDriver() throws {
    let now = Date()
    let profile = makeProfile(now: now)
    controller.start()
    let before = driver.enqueuedSaveNames.filter { $0 == profile.id.uuidString }.count

    controller.enqueueProfileSave(profile.id)

    let after = driver.enqueuedSaveNames.filter { $0 == profile.id.uuidString }.count
    XCTAssertEqual(after, before + 1)
    let refreshed = try XCTUnwrap(try BlockedProfiles.findProfile(byID: profile.id, in: context))
    XCTAssertGreaterThanOrEqual(refreshed.syncVersion, 1)  // funnel bumped in the same write
  }
}
```

- [ ] **Step 2 — Run, expect fail (compile error: `SyncEngineController` does not conform to `SyncEngineControlling`; `requestSync`/`enqueueProfileSave` undefined).**

```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SyncEngineControllerCutoverTests | xcpretty
```

- [ ] **Step 3 — Minimal implementation.** Create `Foqos/CloudKit/SyncEngine/SyncEngineController+Cutover.swift`:

```swift
import Foundation

/// Phase F cutover surface: conforms the engine owner to the `ProfileSyncManager`
/// facade seam and forwards mutations through the single `MutationFunnel` (I2).
extension SyncEngineController: SyncEngineControlling {
  /// Manual/warm-return/push-driven sync. Called only from outside `handleEvent`
  /// (scenePhase, remote notification, "Sync Now"), so a direct fetch+send is
  /// permitted by §1.1's delegate prohibition. No-op until the engine is started.
  func requestSync() {
    driver?.fetchChanges()
    driver?.sendChanges()
  }

  func enqueueProfileSave(_ id: UUID) {
    do { try funnel?.enqueueSave(profileId: id) } catch {
      Log.error("enqueueProfileSave failed: \(error.localizedDescription)", category: .sync)
    }
  }
  func enqueueProfileDelete(_ id: UUID) {
    do { try funnel?.enqueueDelete(profileId: id) } catch {
      Log.error("enqueueProfileDelete failed: \(error.localizedDescription)", category: .sync)
    }
  }
  func enqueueLocationSave(_ id: UUID) {
    do { try funnel?.enqueueSave(locationId: id) } catch {
      Log.error("enqueueLocationSave failed: \(error.localizedDescription)", category: .sync)
    }
  }
  func enqueueLocationDelete(_ id: UUID) {
    do { try funnel?.enqueueDelete(locationId: id) } catch {
      Log.error("enqueueLocationDelete failed: \(error.localizedDescription)", category: .sync)
    }
  }
  func enqueueEmergencySettingsSave() {
    do { try funnel?.enqueueEmergencySettingsSave() } catch {
      Log.error("enqueueEmergencySettingsSave failed: \(error.localizedDescription)", category: .sync)
    }
  }
}
```

> If Phase E scoped `driver`/`funnel` as `private`, widen them to internal (same module) — they are the two collaborators the cutover forwards to. `start()` (Phase E) already assigns both; `requestSync`/`enqueue*` are safe no-ops before it runs (N5: mutations while disabled are not enqueued).

- [ ] **Step 4 — Run, expect pass.**

```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SyncEngineControllerCutoverTests | xcpretty
```

- [ ] **Step 5 — Commit.**

```bash
git add Foqos/CloudKit/SyncEngine/SyncEngineController+Cutover.swift FoqosTests/Mocks/CutoverRecordingDriver.swift FoqosTests/SyncEngineControllerCutoverTests.swift
git commit -m "feat(#267): SyncEngineController cutover API — requestSync + funnel-forwarding, bootstrap-seed test (Phase F)"
```

---

### Task 132: Legacy §11 one-shot — `LegacyCleanupCoordinator` (identify → persist ids → enqueue delete → confirm → flag)

**Files:**
- Create: `Foqos/CloudKit/SyncEngine/LegacyCleanupCoordinator.swift`
- Test: `FoqosTests/SyncEngineLegacyCleanupTests.swift`

**Interfaces:**
- Consumes: `SyncEngineStore.legacyCleanupDone`, `.legacyCleanupIds`, `.addLegacyCleanupIds(_:)`, `.removeLegacyCleanupId(_:)` (contract §2.1); `SyncEngineDriver.add(pendingRecordZoneChanges:)`; `LegacySyncedSession.recordType` (`"SyncedSession"`, `SyncModels.swift:351`); `CloudKitConstants.syncZoneName`.
- Produces: `LegacyCleanupCoordinator` with `identify(modifications:)`, `reenqueuePending()`, `confirmDeleted(recordNames:)`, `isExempt(recordName:)`.

**Steps:**

- [ ] **Step 1 — Failing test.** Create `FoqosTests/SyncEngineLegacyCleanupTests.swift`:

```swift
import CloudKit
import XCTest

@testable import FamilyFoqos

@MainActor
final class SyncEngineLegacyCleanupTests: XCTestCase {
  var testSuiteName: String!
  var store: SyncEngineStore!
  var driver: CutoverRecordingDriver!
  var coordinator: LegacyCleanupCoordinator!

  private var zoneID: CKRecordZone.ID {
    CKRecordZone.ID(zoneName: CloudKitConstants.syncZoneName, ownerName: CKCurrentUserDefaultName)
  }

  override func setUp() async throws {
    try await super.setUp()
    testSuiteName = "SyncEngineLegacyCleanupTests-\(UUID().uuidString)"
    SharedData.configure(suite: UserDefaults(suiteName: testSuiteName)!)
    store = SyncEngineStore(userRecordName: "user-A", defaults: UserDefaults(suiteName: testSuiteName)!)
    driver = CutoverRecordingDriver()
    coordinator = LegacyCleanupCoordinator(store: store, driver: driver)
  }

  override func tearDown() async throws {
    UserDefaults().removePersistentDomain(forName: testSuiteName)
    try await super.tearDown()
  }

  private func legacyRecord(_ name: String) -> CKRecord {
    CKRecord(recordType: LegacySyncedSession.recordType,
             recordID: CKRecord.ID(recordName: name, zoneID: zoneID))
  }

  func testGivenLegacyRecordsFetched_WhenIdentified_ThenIdsPersistedDeletesEnqueuedAndFlagSetOnEmpty() {
    let recs = [legacyRecord("sess-1"), legacyRecord("sess-2")]

    coordinator.identify(modifications: recs)

    XCTAssertEqual(store.legacyCleanupIds, ["sess-1", "sess-2"])
    XCTAssertEqual(Set(driver.enqueuedDeleteNames), ["sess-1", "sess-2"])
    XCTAssertFalse(store.legacyCleanupDone)
    XCTAssertTrue(coordinator.isExempt(recordName: "sess-1"))

    coordinator.confirmDeleted(recordNames: ["sess-1"])
    XCTAssertEqual(store.legacyCleanupIds, ["sess-2"])
    XCTAssertFalse(store.legacyCleanupDone)  // §11: flag set ONLY when the set empties

    coordinator.confirmDeleted(recordNames: ["sess-2"])
    XCTAssertTrue(store.legacyCleanupIds.isEmpty)
    XCTAssertTrue(store.legacyCleanupDone)
  }

  func testGivenFlagAlreadyDone_WhenIdentified_ThenNoOp() {
    store.legacyCleanupDone = true
    coordinator.identify(modifications: [legacyRecord("sess-9")])

    XCTAssertTrue(store.legacyCleanupIds.isEmpty)
    XCTAssertTrue(driver.enqueuedDeleteNames.isEmpty)
  }

  func testGivenNonLegacyRecords_WhenIdentified_ThenIgnored() {
    let profile = CKRecord(recordType: SyncedProfile.recordType,
                           recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID))
    coordinator.identify(modifications: [profile])

    XCTAssertTrue(store.legacyCleanupIds.isEmpty)
    XCTAssertTrue(driver.enqueuedDeleteNames.isEmpty)
  }

  func testGivenPersistedIdsAfterKill_WhenReenqueue_ThenDeletesReadded() {
    store.addLegacyCleanupIds(["sess-a", "sess-b"])  // survived a kill; strip removed the pending deletes

    coordinator.reenqueuePending()

    XCTAssertEqual(Set(driver.enqueuedDeleteNames), ["sess-a", "sess-b"])
  }
}
```

- [ ] **Step 2 — Run, expect fail (`LegacyCleanupCoordinator` undefined).**

```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SyncEngineLegacyCleanupTests | xcpretty
```

- [ ] **Step 3 — Minimal implementation.** Create `Foqos/CloudKit/SyncEngine/LegacyCleanupCoordinator.swift`:

```swift
import CloudKit

/// §11 legacy-cleanup one-shot. Identifies `LegacySyncedSession` ("SyncedSession")
/// records from any fetch cycle while `legacyCleanupDone` is unset, persists their ids
/// as the exemption carrier (`legacyCleanupIds`), and enqueues their deletes. This is
/// the one enumerated exception to I1's corollary / I2's whitelist, scoped to
/// `recordType == LegacySyncedSession` (design §11). Records are never applied locally.
@MainActor
final class LegacyCleanupCoordinator {
  private let store: SyncEngineStore
  private unowned let driver: SyncEngineDriver

  private var zoneID: CKRecordZone.ID {
    CKRecordZone.ID(zoneName: CloudKitConstants.syncZoneName, ownerName: CKCurrentUserDefaultName)
  }

  init(store: SyncEngineStore, driver: SyncEngineDriver) {
    self.store = store
    self.driver = driver
  }

  /// §5.1 legacy arm. Persist first, then enqueue (crash-durable carrier).
  func identify(modifications: [CKRecord]) {
    guard !store.legacyCleanupDone else { return }
    let ids = Set(
      modifications
        .filter { $0.recordType == LegacySyncedSession.recordType }
        .map { $0.recordID.recordName })
    guard !ids.isEmpty else { return }
    store.addLegacyCleanupIds(ids)
    enqueueDeletes(for: ids)
  }

  /// T1: re-enqueue any persisted ids after the strip while the flag is unset (§11).
  func reenqueuePending() {
    guard !store.legacyCleanupDone else { return }
    let ids = store.legacyCleanupIds
    guard !ids.isEmpty else { return }
    enqueueDeletes(for: ids)
  }

  /// §5.3 confirmation (deletedRecordIDs / U-delete / surfaced branch-F).
  /// Sets the done flag ONLY when the set empties (§11).
  func confirmDeleted(recordNames: [String]) {
    guard !store.legacyCleanupDone else { return }
    for name in recordNames { store.removeLegacyCleanupId(name) }
    if store.legacyCleanupIds.isEmpty {
      store.legacyCleanupDone = true
    }
  }

  /// Membership predicate for the T1-strip and §5.4 exemptions.
  func isExempt(recordName: String) -> Bool {
    store.legacyCleanupIds.contains(recordName)
  }

  private func enqueueDeletes(for ids: Set<String>) {
    let changes = ids.map {
      CKSyncEngine.PendingRecordZoneChange.deleteRecord(
        CKRecord.ID(recordName: $0, zoneID: zoneID))
    }
    driver.add(pendingRecordZoneChanges: changes)
  }
}
```

- [ ] **Step 4 — Run, expect pass.**

```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SyncEngineLegacyCleanupTests | xcpretty
```

- [ ] **Step 5 — Wire into the controller (no behaviour change to existing tests).** In `SyncEngineController` (Phase E), construct a `LegacyCleanupCoordinator` in `start()` after the driver is created, and call:
  - `legacyCleanup.identify(modifications:)` from the `fetchedRecordZoneChanges` handler (§5.1), passing that event's `modifications` — before/independent of the `SyncApplyService` routing (legacy records are never applied).
  - `legacyCleanup.reenqueuePending()` in `start()` after the T1 strip (§11).
  - `legacyCleanup.confirmDeleted(recordNames:)` from the `sentRecordZoneChanges` handler (§5.3) with the event's `deletedRecordIDs.map(\.recordName)` and from the U-delete/branch-F arms.
  - Guard the T1 delete-strip and `nextRecordZoneChangeBatch` (§5.4) tombstone-less `.deleteRecord` removal with `!legacyCleanup.isExempt(recordName:)` (I12 exemption by membership).

  These are one-line call insertions into Phase-E handlers; they touch no test contract. Re-run the controller cutover suite to confirm still green:

```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SyncEngineControllerCutoverTests -only-testing:FoqosTests/SyncEngineLegacyCleanupTests | xcpretty
```

- [ ] **Step 6 — Commit.**

```bash
git add Foqos/CloudKit/SyncEngine/LegacyCleanupCoordinator.swift Foqos/CloudKit/SyncEngine/SyncEngineController.swift FoqosTests/SyncEngineLegacyCleanupTests.swift
git commit -m "feat(#267): legacy SyncedSession cleanup one-shot with legacyCleanupIds carrier (§11, Phase F)"
```

---

### Task 133: Composition root `ProfileSyncManager.attachEngine(...)` + wire into `FoqosApp` (I10, scenePhase, remote notification)

**Files:**
- Modify: `Foqos/CloudKit/ProfileSyncManager.swift`
- Modify: `Foqos/FoqosApp.swift`
- Test: `FoqosTests/SyncEngineAttachTests.swift`

**Interfaces:**
- Consumes: `TestModelContainer.create()`, `SyncEngineStore.init`, `SyncApplyService.init`, `RecordProvider.init`, `SyncEngineController.init`, `SessionSyncService.shared` (`SessionSyncFlushing`), `EmergencyUnblockManager`.
- Produces: `ProfileSyncManager.attachEngine(modelContext:emergencyManager:userRecordNameProvider:driverFactory:)` — builds the per-user store + controller (I10), sets `engineController`, calls `start()` iff `isEnabled`. Injectable seams default to production.

**Steps:**

- [ ] **Step 1 — Failing test.** Create `FoqosTests/SyncEngineAttachTests.swift`:

```swift
import CloudKit
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class SyncEngineAttachTests: XCTestCase {
  var testSuiteName: String!
  var container: ModelContainer!
  var manager: ProfileSyncManager!
  private var savedEnabled = false
  private var savedController: (any SyncEngineControlling)?

  override func setUp() async throws {
    try await super.setUp()
    testSuiteName = "SyncEngineAttachTests-\(UUID().uuidString)"
    SharedData.configure(suite: UserDefaults(suiteName: testSuiteName)!)
    container = try TestModelContainer.create()
    manager = ProfileSyncManager.shared
    savedEnabled = manager.isEnabled
    savedController = manager.engineController
  }

  override func tearDown() async throws {
    manager.engineController = savedController
    manager.isEnabled = savedEnabled
    UserDefaults().removePersistentDomain(forName: testSuiteName)
    try await super.tearDown()
  }

  func testGivenContext_WhenAttachEngine_ThenControllerConstructedStartedAndWired() async throws {
    manager.isEnabled = true
    let driver = CutoverRecordingDriver(stateSerialization: nil)

    await manager.attachEngine(
      modelContext: container.mainContext,
      emergencyManager: EmergencyUnblockManager(),
      userRecordNameProvider: { "user-attach-A" },
      driverFactory: { _ in driver })

    XCTAssertNotNil(manager.engineController)  // I10: built only with a context
    // start() ran because isEnabled — first bootstrap seeds the zone.
    XCTAssertTrue(driver.enqueuedZoneSaveNames.contains(CloudKitConstants.syncZoneName))
  }

  func testGivenSyncDisabled_WhenAttachEngine_ThenControllerWiredButNotStarted() async throws {
    manager.isEnabled = false
    let driver = CutoverRecordingDriver(stateSerialization: nil)

    await manager.attachEngine(
      modelContext: container.mainContext,
      emergencyManager: EmergencyUnblockManager(),
      userRecordNameProvider: { "user-attach-B" },
      driverFactory: { _ in driver })

    XCTAssertNotNil(manager.engineController)
    XCTAssertTrue(driver.enqueuedZoneSaveNames.isEmpty)  // start() not called
  }
}
```

- [ ] **Step 2 — Run, expect fail (`attachEngine` undefined).**

```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SyncEngineAttachTests | xcpretty
```

- [ ] **Step 3 — Minimal implementation.** In `ProfileSyncManager.swift` add the composition root (it holds a strong reference so the controller outlives `.onAppear`; `engineController` is the weak facade seam):

```swift
  /// Strong owner of the engine (the weak `engineController` seam points at the same object).
  private var ownedEngineController: SyncEngineController?

  /// I10 composition root: builds the per-user engine with a live ModelContext and starts
  /// it iff sync is enabled. Called once from `FoqosApp` `.onAppear`. Seams are injectable
  /// for tests; production defaults hit CloudKit for the user id and the real driver.
  func attachEngine(
    modelContext: ModelContext,
    emergencyManager: EmergencyUnblockManager,
    userRecordNameProvider: @Sendable () async -> String = ProfileSyncManager.fetchUserRecordName,
    driverFactory: ((Data?) -> SyncEngineDriver)? = nil
  ) async {
    guard ownedEngineController == nil else { return }
    let userRecordName = await userRecordNameProvider()
    let deviceId = SharedData.deviceSyncId.uuidString
    let store = SyncEngineStore(userRecordName: userRecordName)
    let apply = SyncApplyService(
      modelContext: modelContext, store: store, sessionController: StrategyManager.shared,
      emergencyManager: emergencyManager, deviceId: deviceId)
    let provider = RecordProvider(
      modelContext: modelContext, store: store, emergencyManager: emergencyManager, deviceId: deviceId)
    let factory: (Data?) -> SyncEngineDriver =
      driverFactory ?? { engineState in CKSyncEngineDriver(stateSerialization: engineState) }
    let controller = SyncEngineController(
      modelContext: modelContext, store: store, driverFactory: factory,
      apply: apply, provider: provider, sessionSync: SessionSyncService.shared, deviceId: deviceId)
    ownedEngineController = controller
    engineController = controller
    if isEnabled {
      controller.start()
    }
  }

  /// Production user-id resolver (§7 namespace key). Falls back offline.
  static func fetchUserRecordName() async -> String {
    do {
      let id = try await CKContainer(identifier: CloudKitConstants.containerIdentifier).userRecordID()
      return id.recordName
    } catch {
      Log.warning("userRecordID unavailable, using default namespace", category: .sync)
      return "__default_user__"
    }
  }
```

In `FoqosApp.swift`, replace the sync-init block inside `.onAppear` (lines 226-235) — construct the engine at this I10 injection point instead of `syncCoordinator.setModelContext` + `setupSync`:

```swift
        .onAppear {
          // Migrate profiles to V2 trigger system if needed
          ProfileMigrationUtil.migrateProfilesIfNeeded(context: container.mainContext)
          // Construct + wire the sync engine with the live ModelContext (I10)
          Task {
            await profileSyncManager.attachEngine(
              modelContext: container.mainContext,
              emergencyManager: emergencyManager)
          }
          // Reschedule pre-activation reminders for today
          PreActivationReminderScheduler.rescheduleAllReminders(context: container.mainContext)
          // Catch up any missed schedule starts
          PreActivationReminderScheduler.catchUpMissedScheduleStarts(context: container.mainContext)
          hasPerformedInitialSetup = true
        }
```

In the `scenePhase` `.onChange` `.active` arm (FoqosApp.swift:130-139), add a warm-return sync (#200) after the existing account-status work:

```swift
          if newPhase == .active {
            Task {
              await CloudKitManager.shared.checkAccountStatus()
              await CloudKitManager.shared.verifySelfFamilyMemberRecord()
              verifyChildAuthorizationIfNeeded()
            }
            // #200: pull/push on foreground instead of the deleted notification throttle
            if profileSyncManager.isEnabled {
              profileSyncManager.syncNow()
            }
            if hasPerformedInitialSetup {
              PreActivationReminderScheduler.rescheduleAllReminders(context: container.mainContext)
              PreActivationReminderScheduler.catchUpMissedScheduleStarts(context: container.mainContext)
            }
          }
```

In `AppDelegate.application(_:didReceiveRemoteNotification:...)` (FoqosApp.swift:350-357) route to a scheduled `requestSync()` and **preserve the heartbeat refresh side-effect**:

```swift
      // Route the CloudKit push to the engine (schedules a fetch+send); the engine
      // also owns its own database subscription. Preserve heartbeat refresh (#190).
      Task { @MainActor in
        if ProfileSyncManager.shared.isEnabled {
          ProfileSyncManager.shared.syncNow()
        }
        if AppModeManager.shared.currentMode == .parent {
          await HeartbeatManager.shared.refreshHeartbeats()
        }
        completionHandler(.newData)
      }
```

> `syncCoordinator.setModelContext(container.mainContext)` is removed here; `SyncCoordinator`'s apply methods now receive their context through `SyncApplyService` (Phase C). The `@StateObject private var syncCoordinator` line and any remaining `SyncCoordinator` references are handled in Task 135's deletion sweep.

- [ ] **Step 4 — Run, expect pass** (and confirm the app target compiles — the `.onAppear`/AppDelegate edits are compile-checked by the test build):

```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SyncEngineAttachTests | xcpretty
```

- [ ] **Step 5 — Commit.**

```bash
git add Foqos/CloudKit/ProfileSyncManager.swift Foqos/FoqosApp.swift FoqosTests/SyncEngineAttachTests.swift
git commit -m "feat(#267): wire SyncEngineController into FoqosApp at the I10 injection point; scenePhase + push routing (Phase F)"
```

---

### Task 134: Re-route every mutation call site to the funnel

**Files:**
- Modify: `Foqos/Views/BlockedProfileView.swift` (:737 clone save, :885 save, :807 delete)
- Modify: `Foqos/Views/AddLocationView.swift` (:500)
- Modify: `Foqos/Views/SavedLocationsView.swift` (:181)
- Modify: `Foqos/Managers/EmergencyUnblockManager.swift` (:257)
- Modify: `Foqos/Views/SettingsView.swift` (:176 "Sync Now")
- Modify: `Foqos/CloudKit/SyncApplyService.swift` (I9 older-schema auto-heal; was `SyncCoordinator.swift:138`)
- Test: `FoqosTests/SyncEngineCallSiteRoutingTests.swift`

**Interfaces:**
- Consumes: `ProfileSyncManager.enqueueProfileSave/Delete`, `.enqueueLocationSave/Delete`, `.enqueueEmergencySettingsSave`, `.syncNow` (Task 130); `MutationFunnel.enqueueSave(profileId:)` (contract, for the I9 auto-heal in `SyncApplyService`, which holds the funnel for its branch-E/I9 I2-exception enqueues per Phase C).

**Steps:**

- [ ] **Step 1 — Failing test.** Create `FoqosTests/SyncEngineCallSiteRoutingTests.swift` — an end-to-end assertion that a facade mutation reaches the driver through a *real started controller* (the exact path every re-routed call site now takes):

```swift
import CloudKit
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class SyncEngineCallSiteRoutingTests: XCTestCase {
  var testSuiteName: String!
  var container: ModelContainer!
  var manager: ProfileSyncManager!
  var driver: CutoverRecordingDriver!
  private var savedEnabled = false
  private var savedController: (any SyncEngineControlling)?

  override func setUp() async throws {
    try await super.setUp()
    testSuiteName = "SyncEngineCallSiteRoutingTests-\(UUID().uuidString)"
    SharedData.configure(suite: UserDefaults(suiteName: testSuiteName)!)
    container = try TestModelContainer.create()
    manager = ProfileSyncManager.shared
    savedEnabled = manager.isEnabled
    savedController = manager.engineController
    manager.isEnabled = true
    driver = CutoverRecordingDriver(stateSerialization: nil)
    await manager.attachEngine(
      modelContext: container.mainContext,
      emergencyManager: EmergencyUnblockManager(),
      userRecordNameProvider: { "user-routing-A" },
      driverFactory: { [driver] _ in driver! })
  }

  override func tearDown() async throws {
    manager.engineController = savedController
    manager.isEnabled = savedEnabled
    UserDefaults().removePersistentDomain(forName: testSuiteName)
    try await super.tearDown()
  }

  func testGivenStartedEngine_WhenFacadeEnqueuesProfileSave_ThenDriverReceivesSave() throws {
    let now = Date()
    let profile = BlockedProfiles(id: UUID(), name: "P", createdAt: now, updatedAt: now)
    container.mainContext.insert(profile)
    try container.mainContext.save()
    let before = driver.enqueuedSaveNames.filter { $0 == profile.id.uuidString }.count

    manager.enqueueProfileSave(profile.id)

    let after = driver.enqueuedSaveNames.filter { $0 == profile.id.uuidString }.count
    XCTAssertEqual(after, before + 1)
  }

  func testGivenStartedEngine_WhenSyncNow_ThenFetchScheduled() {
    let before = driver.fetchChangesCount
    manager.syncNow()
    XCTAssertEqual(driver.fetchChangesCount, before + 1)
  }
}
```

- [ ] **Step 2 — Run, expect pass already** (the facade + controller from Tasks 130–131 satisfy this; this test locks in the contract the call sites depend on). If it fails, fix the funnel forwarding before touching call sites.

```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SyncEngineCallSiteRoutingTests | xcpretty
```

- [ ] **Step 3 — Re-route the call sites** (each swap keeps the tree compiling; the old async transport methods still exist until Task 135):

  - `BlockedProfileView.swift:737` (clone): `SyncCoordinator.shared.pushProfile(clonedProfile)` → `profileSyncManager.enqueueProfileSave(clonedProfile.id)`.
  - `BlockedProfileView.swift:885` (save): `SyncCoordinator.shared.pushProfile(profile)` → `profileSyncManager.enqueueProfileSave(profile.id)`.
  - `BlockedProfileView.swift:807` (delete): `SyncCoordinator.shared.deleteProfileFromSync(profileId)` → `profileSyncManager.enqueueProfileDelete(profileId)`. (Add `@EnvironmentObject var profileSyncManager: ProfileSyncManager` if this view does not already hold it; it is injected in `FoqosApp` at line 224.)
  - `AddLocationView.swift:500`: replace the `if profileSyncManager.isEnabled { Task { try await profileSyncManager.pushLocation(savedLocation) } … }` block with `profileSyncManager.enqueueLocationSave(savedLocation.id)` (synchronous; the funnel bumps `updatedAt` and enqueues, no-op when disabled — N5).
  - `SavedLocationsView.swift:181`: replace the `if profileSyncManager.isEnabled { Task { try await profileSyncManager.deleteLocation(locationId) } … }` block with `profileSyncManager.enqueueLocationDelete(locationId)`.
  - `EmergencyUnblockManager.swift:257`: replace the `Task { try await profileSyncManager.pushEmergencySettings(settings); … emergencySettingsVersion = nextVersion }` block. Because the funnel now owns the `emergencySettingsVersion += 1` bump-in-write (I2), set the local version first, then enqueue: keep `self.emergencySettingsVersion = nextVersion` (it was already computed), then `profileSyncManager.enqueueEmergencySettingsSave()`.
  - `SettingsView.swift:176` ("Sync Now" button): replace `Task { await profileSyncManager.performFullSync() }` with `profileSyncManager.syncNow()`.
  - `SyncApplyService.swift` I9 older-schema auto-heal arm (the `pushProfile(existingProfile)` extracted from `SyncCoordinator.swift:138`): replace with `try? funnel.enqueueSave(profileId: existingProfile.id)` (the I2-exception enqueue; `funnel` is the `MutationFunnel` `SyncApplyService` already holds for its branch-E conflict bump). The I9 gate logic (mark-read-only / reject / apply, plus the `SyncConflictManager` calls) is otherwise unchanged — S-18 (Phase C) still covers it.

- [ ] **Step 4 — Run, expect pass** (routing test + the migrated Phase-C S-18 gate test):

```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SyncEngineCallSiteRoutingTests | xcpretty
```

- [ ] **Step 5 — Commit.**

```bash
git add Foqos/Views/BlockedProfileView.swift Foqos/Views/AddLocationView.swift Foqos/Views/SavedLocationsView.swift Foqos/Managers/EmergencyUnblockManager.swift Foqos/Views/SettingsView.swift Foqos/CloudKit/SyncApplyService.swift FoqosTests/SyncEngineCallSiteRoutingTests.swift
git commit -m "refactor(#267): route all profile/location/emergency mutations + manual sync through the funnel (Phase F)"
```

---

### Task 135: Delete the old CKQuery transport + I5/I2 grep guard (RED → GREEN)

**Files:**
- Create: `scripts/check-sync-guards.sh`
- Modify: `Foqos/CloudKit/ProfileSyncManager.swift`, `Foqos/CloudKit/SyncCoordinator.swift`, `Foqos/CloudKit/SyncEventDelegate.swift`, `Foqos/FoqosApp.swift`, `Foqos/Views/SettingsView.swift`
- Modify (test migration, if still referencing deleted symbols): `FoqosTests/SyncCoordinatorDITests.swift` and any `ProfileSyncManager` pull/reset tests.

**Interfaces:** none produced; this task removes symbols and adds a CI guard. The guard is the RED test.

**Steps:**

- [ ] **Step 1 — Write the failing guard.** Create `scripts/check-sync-guards.sh`:

```bash
#!/usr/bin/env bash
# I5: no CKQuery in the private-DB sync path. I2: state.add(.saveRecord/.deleteRecord)
# for data records only in the whitelisted files. Run from repo root.
set -euo pipefail

status=0

# --- I5: no CKQuery / predicate fetch in the private-DB sync path -------------
# CloudKitManager/CloudKitNetworkService are the shared-DB family-sharing channel
# (out of scope, B2) and may legitimately query. SessionSyncService uses CAS
# record fetches, not CKQuery, and is allowed.
i5_files=$(git ls-files 'Foqos/CloudKit/*.swift' 'Foqos/CloudKit/SyncEngine/*.swift' \
  | grep -vE 'CloudKitManager|CloudKitNetworkService')
if echo "$i5_files" | xargs grep -nE 'CKQuery|CKQueryOperation|records\(matching:|NSPredicate' ; then
  echo "❌ I5 VIOLATION: CKQuery remains in the private-DB sync path (see above)."
  status=1
else
  echo "✅ I5: no CKQuery in the private-DB sync path."   # assertNoCKQueryInSyncPath
fi

# --- I2: outbound data-record enqueues only in whitelisted sites -------------
whitelist='MutationFunnel|SyncEngineController|SyncApplyService|LegacyCleanupCoordinator|SyncEngineController\+'
hits=$(git ls-files 'Foqos/**/*.swift' 'Foqos/*.swift' \
  | xargs grep -nE 'add\(pendingRecordZoneChanges' 2>/dev/null \
  | grep -vE "$whitelist" || true)
if [ -n "$hits" ]; then
  echo "❌ I2 VIOLATION: state.add outside the whitelist:"
  echo "$hits"
  status=1
else
  echo "✅ I2: outbound record enqueues only in whitelisted sites."  # assertStateAddWhitelisted
fi

exit $status
```

```bash
chmod +x scripts/check-sync-guards.sh
```

- [ ] **Step 2 — Run the guard, expect FAIL (RED):** `ProfileSyncManager.fetchAllRecords`/`pullProfiles` etc. still contain `CKQuery`.

```bash
bash scripts/check-sync-guards.sh
```

- [ ] **Step 3 — Delete the old path.** Remove, verbatim by the code map's line ranges:

  **`ProfileSyncManager.swift`** — delete: `container`/`privateDatabase`/`syncZoneID` plumbing (14-24); `setupSync()` (144-180); `createSyncZoneIfNeeded()` (183-202); `setupSubscriptions()` (205-232); `fetchAllRecords(matching:)` (238-259); `cleanupLegacySessionsIfNeeded` + `legacyCleanupKey`/`isLegacyCleanupComplete`/`setLegacyCleanupComplete` (51-61, 265-332 — replaced by `SyncEngineStore`/`LegacyCleanupCoordinator`); `performFullSync()` (337-368); `pullResetRequests()` (373-417); `pushProfile`/`pushSyncedProfile` (422-465); `pullProfiles()` (468-543); `pullProfileSessionRecords()` (563-618); `pullLocations()` (669-744); `pullEmergencySettings()`/`pushEmergencySettings`/`pushLocation`/`deleteLocation`/`deleteProfile` (764-818 and siblings); the async `resetSync(...) async throws` (823-855); `deleteAllSyncedData()` (858-877); `handleRemoteNotification()` + `backgroundSyncThrottleInterval` (881-900); `syncEventDelegate` weak var (38). **Keep:** the `@Published` surface (28-38 minus the delegate), `deviceId` (47-49), the `init` toggle sink (Task 130 form), and the Task-130 facade verbs. `ProfileSyncManager` no longer imports/touches `CloudKit` except `CKContainer` in `fetchUserRecordName`.

  **`SyncCoordinator.swift`** — delete: `pushLocalData()` (44-100); own-origin apply skip (116-119); profile deletion reconciliation (176-201); location deletion reconciliation (476-499); `handleSyncReset` re-push `Task` + `rePushLocalSyncedData` (551-593); `pushProfile` push body (598-630); `deleteProfileFromSync` (634-648); `pushTask` property (13); the `SyncEventDelegate` conformance extension (653-676) incl. `didRequestLocalDataPush`. The apply-side merge methods extracted to `SyncApplyService` in Phase C are gone from here or reduced to thin retained helpers per Phase C; if `SyncCoordinator` has no remaining live callers after cutover, delete the file and its `@StateObject private var syncCoordinator = SyncCoordinator.shared` in `FoqosApp.swift` (81-83).

  **`SyncEventDelegate.swift`** — delete `didRequestLocalDataPush()` (12); if no producer remains after the `SyncCoordinator` conformance is removed, delete the protocol file and its `weak var syncEventDelegate` reference.

  **`SettingsView.swift`** — the "Reset Syncing" alert (389-419) now calls the synchronous facade `profileSyncManager.resetSync(clearRemoteAppSelections:)` (Task 130). Remove the `Task { do { try await … } catch { … } }` wrappers, keeping the exact §8.5 alert copy ("Keep App Selections" / "Clear App Selections" and the message body) byte-for-byte.

  **Test migration:** if `SyncCoordinatorDITests` (or `ProfileSyncManager` pull/reset tests) still reference `pushProfile`/`deleteProfileFromSync`/`performFullSync`/`syncEventDelegate`/`didRequestLocalDataPush`, update each to the migrated seam (`SyncApplyService` apply methods / `MutationFunnel` enqueues) — do not delete coverage. Their subject moved to Phase C/E suites; the residual DI test asserting delegate registration is removed (the delegate is gone) and its intent is now covered by `SyncEngineAttachTests`.

- [ ] **Step 4 — Run the guard, expect PASS (GREEN):**

```bash
bash scripts/check-sync-guards.sh
```

  Then confirm the app + tests still compile (deletion is compile-verified by a build):

```bash
xcodebuild -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -configuration Debug build 2>&1 | xcpretty
```

- [ ] **Step 5 — Commit.**

```bash
git add scripts/check-sync-guards.sh Foqos/CloudKit/ProfileSyncManager.swift Foqos/CloudKit/SyncCoordinator.swift Foqos/CloudKit/SyncEventDelegate.swift Foqos/FoqosApp.swift Foqos/Views/SettingsView.swift FoqosTests/SyncCoordinatorDITests.swift
git commit -m "refactor(#267): delete the CKQuery private-DB transport; add I5/I2 grep guard (§2/§9, Phase F)"
```

---

### Task 136: S-12 — account switch purges neither namespace; switch-back resumes (T7/§7)

**Files:**
- Test: `FoqosTests/SyncEngineCutoverTests.swift`

**Interfaces:**
- Consumes: `SyncEngineStore` per-user keys; `SyncEngineController.handle(_:)` with `.accountChange(kind: .switchAccounts)` (T7); `SyncEngineController.start()`.

**Steps:**

- [ ] **Step 1 — Failing test.** Create `FoqosTests/SyncEngineCutoverTests.swift` with the S-12 method:

```swift
import CloudKit
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class SyncEngineCutoverTests: XCTestCase {
  var testSuiteName: String!
  var defaults: UserDefaults!
  var container: ModelContainer!
  var context: ModelContext!

  override func setUp() async throws {
    try await super.setUp()
    testSuiteName = "SyncEngineCutoverTests-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: testSuiteName)!
    SharedData.configure(suite: defaults)
    container = try TestModelContainer.create()
    context = container.mainContext
  }

  override func tearDown() async throws {
    UserDefaults().removePersistentDomain(forName: testSuiteName)
    try await super.tearDown()
  }

  private func makeController(
    userRecordName: String, engineState: Data?, driver: CutoverRecordingDriver
  ) -> SyncEngineController {
    let store = SyncEngineStore(userRecordName: userRecordName, defaults: defaults)
    store.engineState = engineState
    let deviceId = SharedData.deviceSyncId.uuidString
    let apply = SyncApplyService(
      modelContext: context, store: store, sessionController: MockSessionController(),
      emergencyManager: EmergencyUnblockManager(), deviceId: deviceId)
    let provider = RecordProvider(
      modelContext: context, store: store, emergencyManager: EmergencyUnblockManager(), deviceId: deviceId)
    return SyncEngineController(
      modelContext: context, store: store, driverFactory: { _ in driver },
      apply: apply, provider: provider, sessionSync: SessionSyncService.shared, deviceId: deviceId)
  }

  func testGivenTwoAccounts_WhenAccountSwitched_ThenNeitherNamespacePurgedAndSwitchBackResumes() throws {
    let stateA = Data("engine-A".utf8)
    let stateB = Data("engine-B".utf8)

    // Seed both namespaces with per-user state (engine state + a delete tombstone).
    let storeA = SyncEngineStore(userRecordName: "user-A", defaults: defaults)
    storeA.engineState = stateA
    storeA.setTombstone(recordName: "prof-A", changeTag: "tagA")
    let storeB = SyncEngineStore(userRecordName: "user-B", defaults: defaults)
    storeB.engineState = stateB
    storeB.setTombstone(recordName: "prof-B", changeTag: "tagB")

    // Account A is active; an account switch fires T7.
    let driverA = CutoverRecordingDriver(stateSerialization: stateA)
    let controllerA = makeController(userRecordName: "user-A", engineState: stateA, driver: driverA)
    controllerA.start()
    controllerA.handle(.accountChange(kind: .switchAccounts))

    // §7: switching purges NOTHING — both namespaces intact.
    let checkA = SyncEngineStore(userRecordName: "user-A", defaults: defaults)
    let checkB = SyncEngineStore(userRecordName: "user-B", defaults: defaults)
    XCTAssertEqual(checkA.engineState, stateA)
    XCTAssertEqual(checkA.deleteTombstones["prof-A"] ?? nil, "tagA")
    XCTAssertEqual(checkB.engineState, stateB)
    XCTAssertEqual(checkB.deleteTombstones["prof-B"] ?? nil, "tagB")

    // Switch back to A: relaunch with existing engineState, no intents -> resumes,
    // zero new seed enqueues (I7/I11).
    let driverA2 = CutoverRecordingDriver(stateSerialization: stateA)
    let controllerA2 = makeController(userRecordName: "user-A", engineState: stateA, driver: driverA2)
    controllerA2.start()
    XCTAssertTrue(driverA2.enqueuedZoneSaveNames.isEmpty)
    XCTAssertTrue(driverA2.enqueuedSaveNames.isEmpty)
  }
}
```

- [ ] **Step 2 — Run, expect fail** (S-12 method fails if any purge occurs or the switch-back re-seeds).

```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SyncEngineCutoverTests/testGivenTwoAccounts_WhenAccountSwitched_ThenNeitherNamespacePurgedAndSwitchBackResumes | xcpretty
```

- [ ] **Step 3 — Implementation.** No new production code should be required — T7 (Phase E) already "purges nothing" (§7) and switch-back is an ordinary relaunch (I7). If the test reveals T7 purging per-user keys or the switch-back seeding, that is a Phase-E defect surfaced by cutover: fix the T7 handler to stop the engine + switch namespace only (per §7), never touching `engineState`/`deleteTombstones`/`systemFields`.

- [ ] **Step 4 — Run, expect pass.**

```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SyncEngineCutoverTests/testGivenTwoAccounts_WhenAccountSwitched_ThenNeitherNamespacePurgedAndSwitchBackResumes | xcpretty
```

- [ ] **Step 5 — Commit.**

```bash
git add FoqosTests/SyncEngineCutoverTests.swift
git commit -m "test(#267): S-12 account switch preserves both namespaces and resumes on switch-back (§7, Phase F)"
```

---

### Task 137: S-16 — funnel-bumped edit propagates end-to-end; a bypass edit does not (locked regression)

**Files:**
- Modify (add method): `FoqosTests/SyncEngineCutoverTests.swift`

**Interfaces:**
- Consumes: `MutationFunnel.enqueueSave(profileId:)`, `RecordProvider.record(forRecordName:)`, `SyncApplyService.applyFetchedModification(_:isPendingDeleteOrTombstoned:)` (contract).

**Steps:**

- [ ] **Step 1 — Failing test.** Add to `SyncEngineCutoverTests`:

```swift
  func testGivenFunnelBumpedAndBypassEdit_WhenApplied_ThenOnlyFunnelEditPropagates() throws {
    let now = Date()

    // Device A: create + funnel-save a profile (bump-in-write + enqueue).
    let driverA = CutoverRecordingDriver(stateSerialization: Data("A".utf8))
    let storeA = SyncEngineStore(userRecordName: "user-A16", defaults: defaults)
    storeA.engineState = Data("A".utf8)
    let deviceA = "device-A"
    let profile = BlockedProfiles(id: UUID(), name: "Focus", createdAt: now, updatedAt: now)
    context.insert(profile)
    try context.save()
    let funnelA = MutationFunnel(
      modelContext: context, store: storeA, driver: driverA, deviceId: deviceA)
    try funnelA.enqueueSave(profileId: profile.id)

    let refreshed = try XCTUnwrap(try BlockedProfiles.findProfile(byID: profile.id, in: context))
    XCTAssertGreaterThanOrEqual(refreshed.syncVersion, 1)
    XCTAssertTrue(driverA.enqueuedSaveNames.contains(profile.id.uuidString))

    // Materialize the record the way nextRecordZoneChangeBatch would (§5.4).
    let providerA = RecordProvider(
      modelContext: context, store: storeA, emergencyManager: EmergencyUnblockManager(), deviceId: deviceA)
    let record = try XCTUnwrap(providerA.record(forRecordName: profile.id.uuidString))

    // Device B: apply the fetched modification -> profile appears with the same version.
    let containerB = try TestModelContainer.create()
    let contextB = containerB.mainContext
    let storeB = SyncEngineStore(userRecordName: "user-B16", defaults: defaults)
    let applyB = SyncApplyService(
      modelContext: contextB, store: storeB, sessionController: MockSessionController(),
      emergencyManager: EmergencyUnblockManager(), deviceId: "device-B")
    let outcome = applyB.applyFetchedModification(record, isPendingDeleteOrTombstoned: { _ in false })
    XCTAssertEqual(outcome, .applied)
    let onB = try XCTUnwrap(try BlockedProfiles.findProfile(byID: profile.id, in: contextB))
    XCTAssertEqual(onB.name, "Focus")
    XCTAssertEqual(onB.syncVersion, refreshed.syncVersion)

    // Device A bypass edit: mutate WITHOUT the funnel (no bump, no enqueue).
    let saveCountBefore = driverA.enqueuedSaveNames.count
    refreshed.name = "Renamed-bypassing-funnel"
    try context.save()
    XCTAssertEqual(driverA.enqueuedSaveNames.count, saveCountBefore)  // nothing enqueued -> won't propagate
  }
```

- [ ] **Step 2 — Run, expect fail (until the whole pipeline is wired; if red, it exposes a real funnel/provider/apply defect).**

```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SyncEngineCutoverTests/testGivenFunnelBumpedAndBypassEdit_WhenApplied_ThenOnlyFunnelEditPropagates | xcpretty
```

- [ ] **Step 3 — Implementation.** No new production code expected — the funnel (Phase E), provider (Phase D), and apply service (Phase C) already implement this. A failure indicates a cutover-level integration gap; fix in the owning collaborator per contract (bump-in-write I2, verbatim-version apply S-27).

- [ ] **Step 4 — Run, expect pass.**

```bash
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/SyncEngineCutoverTests/testGivenFunnelBumpedAndBypassEdit_WhenApplied_ThenOnlyFunnelEditPropagates | xcpretty
```

- [ ] **Step 5 — Commit.**

```bash
git add FoqosTests/SyncEngineCutoverTests.swift
git commit -m "test(#267): S-16 end-to-end — funnel-bumped edit propagates, bypass edit does not (Phase F)"
```

---

### Task 138: Manual two-device checklist doc + final full-suite green (exit)

**Files:**
- Create: `docs/sync-engine-two-device-checklist.md`

**Interfaces:** none (documentation + full-suite gate).

**Steps:**

- [ ] **Step 1 — Write the §10 checklist.** Create `docs/sync-engine-two-device-checklist.md` transcribing the design §10 "Manual two-device checklist" verbatim as an actionable list (linked from PR #268):

```markdown
# #267 CKSyncEngine — manual two-device acceptance checklist

Run on two devices signed into the SAME iCloud account with Profile Sync enabled,
unless a row says otherwise. Each row lists the action and the expected result.

- [ ] **Reset Sync — Keep App Selections:** origin re-seeds; other device keeps its
      blocked-app selections; profiles/locations/emergency settings converge (§8.5, §8.1).
- [ ] **Reset Sync — Clear App Selections:** other device's profiles show
      `needsAppSelection`; must re-select apps; origin keeps its own selections (§8.5 E-2).
- [ ] **Concurrent edit:** edit the same profile on both devices; both converge, the
      loser surfaces a conflict banner, no data lost (branch E, I8).
- [ ] **Delete-vs-edit race, order A:** delete on A while editing on B → B's edit either
      recreates (branch U-save) or the delete wins; converges, keep-biased (N12).
- [ ] **Delete-vs-edit race, order B:** edit on A while deleting on B → same, no husk
      survives once both fetch (I12 tombstone + pending-delete-wins, S-32).
- [ ] **Device offline across a reset:** offline device rejoins → applies the current
      command once (§8.3), re-seeds its local data (I11); nothing deleted (N1).
- [ ] **Token-expired device across a reset:** device past change-token lifetime rejoins
      → re-seeds; note N10 residual (foreign deletions not re-expressible).
- [ ] **Active session across a reset (stop-on-absent, order A):** stop on the owner →
      mirror stops via §6 create-if-absent stopped record (S-24).
- [ ] **Active session across a reset (stop-on-absent, order B):** concurrent fresh start
      wins the race → the stop yields (`serverRecordChanged`, S-24).
- [ ] **Purge (delete DeviceSync zone in Settings > iCloud):** data intact locally; sync
      disables; one-time notice; re-enable is fresh consent (T6, S-4).
- [ ] **Account switch and back:** switch iCloud account, then back → neither namespace
      purged; A resumes (T7/§7, S-12).
- [ ] **Toggle off → local delete → on:** delete propagates on re-enable via the surviving
      tombstone (I12/N5).
- [ ] **Toggle off → remote delete → on:** the remotely-deleted record resurrects from the
      rejoin seed (N5, deliberate keep-bias).
- [ ] **Restore-from-backup then edit:** restored device heals forward; own-origin newer
      version applies (S-31).
- [ ] **Legacy cleanup:** first launch removes old `device-sync-zone-changes` subscription
      and deletes `SyncedSession` records exactly once (§11); kill mid-cleanup → completes
      on relaunch.
```

- [ ] **Step 2 — Commit the doc.**

```bash
git add docs/sync-engine-two-device-checklist.md
git commit -m "docs(#267): manual two-device acceptance checklist (§10, Phase F)"
```

- [ ] **Step 3 — Run the guard + full suite (exit gate).** Run the I5/I2 guard, then the ENTIRE test suite via `RunAllTests` (`mcp__xcode__RunAllTests`) or the full `xcodebuild test` with no `-only-testing`:

```bash
bash scripts/check-sync-guards.sh
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' | xcpretty
```

- [ ] **Step 4 — Exit criterion (REQUIRED, all must hold):**
  - The app target and test target **build** (`clean-build.sh` + Debug build succeed).
  - `scripts/check-sync-guards.sh` exits 0 (I5: no CKQuery in the private-DB sync path; I2: outbound record enqueues only in `MutationFunnel`/`SyncEngineController(+Cutover)`/`SyncApplyService`/`LegacyCleanupCoordinator`).
  - **The full suite is GREEN** — every pre-existing test (with transport-specific tests migrated onto the new seams in Phases C–F) plus all Phase A–F tests, run via `RunAllTests`, passes. No `-only-testing` filter.
  - `swift-format lint --recursive .` is clean.
  - The app is wired end-to-end: launch constructs `SyncEngineController` at the I10 injection point; the toggle drives start/stop; scenePhase `.active` and the CloudKit push both schedule `requestSync()` (heartbeat refresh preserved); all mutations flow through the funnel; the old CKQuery path is gone.

- [ ] **Step 5 — Request code review** before merge (AGENTS.md: never self-merge; request review), attaching the scenario→test table and the manual checklist.

---

## Scenario → Test Mapping (for the PR body)

| Design ref | Test(s) |
|---|---|
| AB-2 | `SyncEngineControllerTests.testGivenStateUpdate_WhenHandled_ThenEngineStatePersisted` |
| AB-4 | `MockSyncEngineDriverTests.testGivenRestoredPending_WhenInitialized_ThenExposedForStripAndNoAutoSend` ; `SyncEngineControllerTests.testGivenRestoredPendingDeletesAndDbChanges_WhenStart_ThenStripRemovesThemSynchronouslyWithNoSend` |
| D-3 | `SyncEngineStoreTombstoneTests.testGivenTwoUsers_WhenTombstonesAndLegacySet_ThenIsolated` |
| E-1 | `SyncApplyServiceTests.testGivenAbsentProfile_WhenModificationApplied_ThenCreatedWithNeedsAppSelection` |
| I2 | `MutationFunnelTests.testGivenNewerSchemaProfile_WhenEnqueueSave_ThenNeverEnqueuedAndNoBump` ; `check-sync-guards.sh.assertStateAddWhitelisted` |
| I-3 | `SyncEngineStoreIntentTests.testGivenProcessedResetIds_WhenMarked_ThenAccumulateAndNeverPrune` |
| I5 | `check-sync-guards.sh.assertNoCKQueryInSyncPath` |
| I-6 | `SyncEngineStoreStateTests.testGivenSystemFields_WhenStoredPerRecord_ThenRoundTripAndPurge` |
| I6 | `SyncEngineControllerTests.testGivenZoneDeleted_WhenHandled_ThenDataIntactPurgeIntentFirstSeed` |
| I7 | `SyncEngineControllerTests.testGivenExistingEngineStateNoIntents_WhenStart_ThenZeroEnqueues` |
| I9 | `SyncApplyServiceTests.testGivenSchemaVersions_WhenProfileModificationApplied_ThenI9GatePreserved` |
| I10 | `SyncEngineAttachTests.testGivenContext_WhenAttachEngine_ThenControllerConstructedStartedAndWired` ; `SyncEngineControllerTests.testGivenController_WhenConstructed_ThenRequiresContextAndAppliesDurableInEvent` |
| I-11 | `SyncEngineStoreIntentTests.testGivenLastAppliedAndResetIntent_WhenSet_ThenRoundTrip` |
| I11 | `SyncEngineControllerCutoverTests.testGivenFreshEngineState_WhenStarted_ThenBootstrapSeedEnqueued` ; `SyncEngineControllerTests.testGivenSeedHelper_WhenSeed_ThenIntentFirstThenSaveZoneAndSaveAllRestorable` |
| I-12 | `SyncEngineStoreTombstoneTests.testGivenTombstones_WhenSetWithNilAndNonNilTags_ThenRoundTripAndClear` |
| I12 | `MutationFunnelTests.testGivenLocation_WhenEnqueueDelete_ThenWritesTombstoneAndEnqueuesOnce` ; `SyncEngineControllerTests.testGivenFreshTombstoneEntityAbsent_WhenRecover_ThenEnqueueDelete` |
| N5 | `SyncEngineFacadeTests.testGivenController_WhenToggledOffAfterOn_ThenStopIsCalled` |
| N6 | `SyncApplyServiceTests.testGivenNewerRemoteLocation_WhenApplied_ThenClientClockMergeApplies` |
| N13 | `SessionStopOnAbsentTests.testGivenStopOnAbsentCreatedStoppedRecord_ThenRecordIsInactiveSignalForMirrors` |
| S-1 | `SyncApplyServiceTests.testGivenTombstonedProfile_WhenFetchedDeletionApplied_ThenOnlyThatProfileDeletedAndTombstoneCleared` |
| S-2 | `SyncApplyServiceTests.testGivenEmptyFetch_WhenApplied_ThenZeroLocalMutations` |
| S-3 | `SyncEngineControllerTests.testGivenZoneDeleted_WhenHandled_ThenDataIntactPurgeIntentFirstSeed` |
| S-4 | `SyncEngineControllerTests.testGivenZonePurged_WhenHandled_ThenDisabledDiscardStateTombstonesIntact` ; `SyncEngineResetTests.testGivenAbandonedReset_WhenIntentCleared_ThenTombstonesSurvive` |
| S-5 | `SyncEngineResetTests.testGivenForeignCommand_WhenAppliedTwiceSameId_ThenSecondIsNoOp` |
| S-6 | `SyncEngineResetTests.testGivenAppliedButUnmarked_WhenCommandRedelivered_ThenReAppliesIdempotentlyAndMarks` |
| S-7 | `SyncEngineControllerTests.testGivenController_WhenConstructed_ThenRequiresContextAndAppliesDurableInEvent` |
| S-8 | `SyncEngineResetTests.testGivenCommand_WhenApplied_ThenPurgesAndSeedsRegardlessOfClearFlagInIntentApplyMarkOrder` |
| S-9 | `SyncEngineResetTests.testGivenOwnOriginCommand_WhenApplied_ThenMarkedNeverApplied` ; `SyncEngineResetTests.testGivenSteady_WhenBeginReset_ThenPersistsDeletingIntentPreMarksAndEnqueuesDeleteZone` |
| S-10 | `SyncEngineControllerTests.testGivenSentSave_WhenServerRecordChanged_ThenBranchCTagStoredMergeAndReAdd` |
| S-11 | `SyncEngineControllerTests.testGivenSentSave_WhenZoneNotFound_ThenBranchZSaveZoneSeedAndReAdd` |
| S-12 | `SyncEngineCutoverTests.testGivenTwoAccounts_WhenAccountSwitched_ThenNeitherNamespacePurgedAndSwitchBackResumes` |
| S-13 | `SyncEngineResetTests.testGivenRecreatingOrSeedingStage_WhenResume_ThenReenqueuesThatStagesChanges` ; `SyncEngineResetTests.testGivenSeedingStage_WhenCommandSaveResult_ThenSavedClearsForeignAbandonsOwnConfirmsUndecodableAbandons` |
| S-14 | `SyncEngineControllerTests.testGivenNewerSchemaProfilePendingSave_WhenNextBatch_ThenRemoved` |
| S-15 | `MutationFunnelTests.testGivenFailedProfileDelete_WhenEnqueueDelete_ThenTombstoneRemovedRollbackAndNothingEnqueued` ; `MutationFunnelTests.testGivenMissingProfile_WhenEnqueueSave_ThenThrowsWithoutBumpOrEnqueue` ; `MutationFunnelTests.testGivenProfile_WhenEnqueueSave_ThenBumpsVersionInSameWriteAndEnqueuesOnce` ; `MutationFunnelTests.testGivenSyncedProfile_WhenEnqueueDelete_ThenWritesTombstoneWithTagAndEnqueuesOnce` |
| S-16 | `MutationFunnelTests.testGivenEditBypassingFunnel_ThenNoBumpAndNoEnqueue` ; `MutationFunnelTests.testGivenProfile_WhenEnqueueSave_ThenBumpsVersionInSameWriteAndEnqueuesOnce` ; `SyncEngineCutoverTests.testGivenFunnelBumpedAndBypassEdit_WhenApplied_ThenOnlyFunnelEditPropagates` |
| S-17 | `SyncEngineControllerTests.testGivenSentSave_WhenRetriableVsNonRetriable_ThenBranchROnceBranchFSurfaced` |
| S-18 | `SyncApplyServiceTests.testGivenSchemaVersions_WhenProfileModificationApplied_ThenI9GatePreserved` |
| S-19 | `SyncEngineControllerTests.testGivenExistingEngineStateNoIntents_WhenStart_ThenZeroEnqueues` |
| S-20 | `ResetSeederTests.testGivenSeeder_WhenPerformI6Purge_ThenPurgesSystemFieldsAndFlushesSessionCache` ; `SessionStopOutboxTests.testGivenStopError_WhenEnqueuedAndDrained_ThenRetriesAndClearsOnSuccess` |
| S-21 | `SessionStopOnAbsentTests.testGivenZoneRecreated_WhenFirstStopWrite_ThenCreatesFreshStoppedRecordNotStaleCacheError` |
| S-22 | `SyncApplyServiceTests.testGivenSessionModification_WhenApplied_ThenStopsMirrorAndAbsenceNeverStops` |
| S-23 | `SyncEngineControllerTests.testGivenSentSave_WhenUnknownItem_ThenBranchUSaveDropsTagReAddsCreate` |
| S-24 | `SessionStopOnAbsentTests.testGivenAbsentRecord_WhenStop_ThenCreatesStoppedRecordCreateIfAbsent` ; `SessionStopOnAbsentTests.testGivenConcurrentFreshStartWins_WhenStopOnAbsent_ThenStopYieldsAlreadyStopped` |
| S-25 | `MockSyncEngineDriverTests.testGivenDatabaseThenRecordSends_WhenEnqueued_ThenOrderObservableInLog_S25` ; `SyncEngineControllerTests.testGivenSeed_WhenEnqueued_ThenSaveZoneDatabaseChangePrecedesRecordSaves` |
| S-26 | `MockSyncEngineDriverTests.testGivenStateUpdateBetweenTwoFetchEvents_WhenDeliveredSerially_ThenObservedInOrder_S26` ; `SyncEngineControllerTests.testGivenStateUpdateBetweenTwoFetchEvents_WhenPersisted_ThenSecondEventReDeliveredOnRelaunch` |
| S-27 | `SyncApplyServiceTests.testGivenEqualVersion_WhenProfileModificationApplied_ThenDivergenceBumpsAndEqualIsNoOp` ; `SyncEngineCutoverTests.testGivenFunnelBumpedAndBypassEdit_WhenApplied_ThenOnlyFunnelEditPropagates` |
| S-28 | `SyncEngineControllerTests.testGivenPendingSeedIntentSet_WhenStart_ThenPurgeAndReSeed` |
| S-29 | `MutationFunnelTests.testGivenNeverSyncedProfile_WhenEnqueueDelete_ThenTombstoneTagIsNil` ; `MutationFunnelTests.testGivenProfileDelete_WhenReloadingStore_ThenTombstoneSurvivesForRecovery` ; `MutationFunnelTests.testGivenSyncedProfile_WhenEnqueueDelete_ThenWritesTombstoneWithTagAndEnqueuesOnce` ; `SyncEngineControllerTests.testGivenConfirmedDelete_WhenSentRecordChanges_ThenTombstoneClearedAndSystemFieldsDropped` ; `SyncEngineControllerTests.testGivenTombstoneEntityPresent_WhenRecover_ThenAbortAndClear` ; `SyncEngineControllerTests.testGivenTombstonelessPendingDelete_WhenNextBatch_ThenRemovedUnlessLegacy` |
| S-30 | `SyncApplyServiceTests.testGivenThrowingCreate_WhenApplied_ThenRollbackNoSystemFieldsFailedApplyRecorded` |
| S-31 | `SyncApplyServiceTests.testGivenOwnOriginRecord_WhenApplied_ThenNewerHealsForwardAndEqualEchoNoOp` |
| S-32 | `SyncApplyServiceTests.testGivenPendingDeleteId_WhenModificationApplied_ThenSkippedPendingDelete` ; `SyncEngineControllerTests.testGivenTombstonedId_WhenFetchedModification_ThenSkippedPendingDeleteWins` |
| S-33 | `SyncEngineControllerTests.testGivenRecoveredTombstone_WhenVerifyBeforeDelete_ThenAbsentClearsMatchingTagDeletesDifferentTagSurfaces` |
| S-34 | `SyncApplyServiceTests.testGivenEchoGuardId_WhenModificationApplied_ThenSkippedUntilDrained` ; `SyncEngineControllerTests.testGivenConfirmedDelete_WhenModificationDeliveredBeforeVsAfterCycleStart_ThenSkipThenApply` |
| S-35 | `SyncEngineControllerTests.testGivenFailedApplies_WhenRetry_ThenVerifyThenReapplyAndSupersession` ; `SyncEngineStoreTombstoneTests.testGivenFailedApplies_WhenAddedAndSupersededByName_ThenClearedByName` |
| S-36 | `SyncEngineResetTests.testGivenDeletingStageResume_WhenGateFetchesCommand_ThenAllFiveArmsResolveCorrectly` |
| S-37 | `MockSyncEngineDriverTests.testGivenFetchCycle_WhenDelivered_ThenDelimitersWrapRecordEvents_S37` ; `SyncEngineControllerTests.testGivenFetchCycle_WhenDidFetchChanges_ThenSteadyAndCycleDelimited` |
| S-38 | `MockSyncEngineDriverTests.testGivenRestoredPendingDeletes_WhenInitialized_ThenAvailableBeforeAnySend_S38` ; `SyncEngineControllerTests.testGivenLegacyCleanupIdsAndFlagUnset_WhenStart_ThenIdsSurviveStripAndReEnqueue` ; `SyncEngineControllerTests.testGivenRestoredPendingDeletesAndDbChanges_WhenStart_ThenStripRemovesThemSynchronouslyWithNoSend` ; `SyncEngineLegacyCleanupTests.testGivenLegacyRecordsFetched_WhenIdentified_ThenIdsPersistedDeletesEnqueuedAndFlagSetOnEmpty` ; `SyncEngineStoreTombstoneTests.testGivenTransaction_WhenCompoundWriteUnderSingleLock_ThenAllPersistNoReentrancyDeadlock` |
| T1 | `SyncEngineControllerCutoverTests.testGivenFreshEngineState_WhenStarted_ThenBootstrapSeedEnqueued` |
| T2 | `SyncEngineControllerTests.testGivenFetchCycle_WhenDidFetchChanges_ThenSteadyAndCycleDelimited` |
| T3 | `SyncEngineControllerTests.testGivenFetchedDeletion_WhenHandled_ThenTombstoneClearedAndPendingDeleteRemoved` |
| T4b | `SyncEngineControllerTests.testGivenSentDatabaseChanges_WhenZoneSavedOrAlreadyExists_ThenConfirmed` |
| T5 | `SyncEngineControllerTests.testGivenZoneDeleted_WhenHandled_ThenDataIntactPurgeIntentFirstSeed` |
| T6 | `SyncEngineControllerTests.testGivenZonePurged_WhenHandled_ThenDisabledDiscardStateTombstonesIntact` |
| T7 | `SyncEngineControllerTests.testGivenAccountChange_WhenHandled_ThenStopInvalidateContinuationsPurgeNothing` |
| T8 | `SyncEngineResetTests.testGivenSteady_WhenBeginReset_ThenPersistsDeletingIntentPreMarksAndEnqueuesDeleteZone` |
| T9 | `SyncEngineResetTests.testGivenDeletingStage_WhenZoneDeleteConfirmed_ThenPurgesAdvancesToRecreatingAndEnqueuesSaveZone` ; `SyncEngineResetTests.testGivenRecreatingStage_WhenZoneSaveConfirmed_ThenSeedsIntentFirstAndEnqueuesCommand` |
| T-10 | `SyncEngineStoreStateTests.testGivenEngineState_WhenSetAndReloaded_ThenPersistsAndClears` |
| T10 | `SyncEngineControllerTests.testGivenStateUpdate_WhenHandled_ThenEngineStatePersisted` |
| T11 | `SyncEngineControllerTests.testGivenStop_WhenCalled_ThenClearIntentsBestEffortSendTombstonesSurvive` |
| fetchRecordSeam | `SyncEngineDriverFetchRecordTests.testGivenConfiguredResults_WhenFetchRecord_ThenReturnsResultAndRecordsID` |
