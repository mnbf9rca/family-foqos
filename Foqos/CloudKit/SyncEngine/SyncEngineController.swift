import CloudKit
import Foundation
import SwiftData

enum SyncEngineState: Equatable {
  case disabled, bootstrapping, steady, purged
}

/// Seam over session-cache flushing (§ session sync) so `SyncEngineController` never
/// depends on the concrete session sync service in tests. Production adapter TBD (later
/// phase); `MockSessionSyncFlushing` is the test double.
@MainActor
protocol SessionSyncFlushing: AnyObject {
  func flushSessionCache() async
}

/// The @MainActor sole owner of the CKSyncEngine driver (via the `SyncEngineDriver` seam).
/// Context-gated (I10): the controller requires a `ModelContext` at construction and can
/// never observe an event without one — no engine exists before `start()` creates the
/// driver, and the driver itself is only created once the context-bearing collaborators
/// (`apply`, `provider`) already exist (S-7).
@MainActor
final class SyncEngineController: SyncEngineDriverDelegate {
  private let modelContext: ModelContext
  let store: SyncEngineStore
  private let driverFactory: (Data?) -> SyncEngineDriver
  let apply: SyncApplyService
  private let provider: RecordProvider
  private let sessionSync: SessionSyncFlushing
  private let deviceId: String
  private let scheduleProfileDeleteCommit: (@escaping @MainActor () -> Void) -> Void

  private let zoneID = CKRecordZone.ID(
    zoneName: CloudKitConstants.syncZoneName, ownerName: CKCurrentUserDefaultName)

  private(set) var state: SyncEngineState = .disabled
  // Widened to internal (Phase F, Task 131): `+Cutover`'s `requestSync`/`enqueue*` are the
  // only other-file collaborators that read/forward through these.
  var driver: SyncEngineDriver!
  // The single I2 mutation-forwarding seam, created alongside `driver` in `start()`.
  var funnel: MutationFunnel?
  // Phase F composition root (CRA-4, Task 134b): both constructed in `start()` alongside
  // `driver`, over the production `+Reset.swift` seam adapters.
  var reset: ResetController?
  var legacyCleanup: LegacyCleanupCoordinator?

  // Async work spawned outside handlers (T7/T11 invalidate these).
  private(set) var startupTask: Task<Void, Never>?
  private(set) var flushTask: Task<Void, Never>?
  private(set) var fetchCycleSweepTask: Task<Void, Never>?
  private var namespaceGeneration = 0

  // Phase E reset hooks (wired by SyncEngineController+Reset.swift).
  var onResumeReset: ((ResetIntent) -> Void)?
  var onStopReset: (() -> Void)?
  var resetCommandSaveDidFail: ((CKRecord, CKError) -> Void)?
  // T4 §5.3 command-save success hook (CRA-3), wired to ResetController in Phase F.
  var resetCommandSaveDidSucceed: ((CKRecord) -> Void)?
  // Phase F reset hook: fetched SyncResetRequest records are routed here (§8.3),
  // never through the generic modification apply path (CRA-2).
  var onFetchedResetCommand: ((CKRecord) -> Void)?
  // T4b §5.5 zone-change confirmation hook (CRA-3-style), wired to ResetController in
  // Phase E to advance resetIntent stages.
  var onZoneChangeConfirmed: (([CKRecordZone.ID], [CKRecordZone.ID]) -> Void)?

  // Echo guard cycle bookkeeping (§5.1 / AB-3).
  private var currentCycle = 0
  private var confirmDeleteCycle: [String: Int] = [:]

  // I11 observable-clear (Fix 5): names outstanding from the most recent seed batch
  // (restorable record names + `seedZoneMarkerName` for the saveZone leg). Cleared one at
  // a time as each is observed sent/terminally-resolved; `pendingSeedIntent` is cleared
  // once this set empties.
  private var pendingSeedNames: Set<String> = []
  private static let seedZoneMarkerName = "__i11_seed_zone__"

  init(
    modelContext: ModelContext,
    store: SyncEngineStore,
    driverFactory: @escaping (Data?) -> SyncEngineDriver,
    apply: SyncApplyService,
    provider: RecordProvider,
    sessionSync: SessionSyncFlushing,
    deviceId: String,
    scheduleProfileDeleteCommit: @escaping (@escaping @MainActor () -> Void) -> Void =
      BlockedProfiles.scheduleProfileDeleteCommit
  ) {
    self.modelContext = modelContext
    self.store = store
    self.driverFactory = driverFactory
    self.apply = apply
    self.provider = provider
    self.sessionSync = sessionSync
    self.deviceId = deviceId
    self.scheduleProfileDeleteCommit = scheduleProfileDeleteCommit
    self.apply.profileDeleteCommitObserver = { [weak self] recordName in
      guard let self else { return }
      let recordID = CKRecord.ID(recordName: recordName, zoneID: self.zoneID)
      self.applyDeletionSideEffects(recordID: recordID)
      self.store.removeFailedApply(recordName: recordName)
    }
  }

  func start() {
    guard state == .disabled || state == .purged else { return }
    driver = driverFactory(store.engineState)
    // #286 self-heal: a serialization that carries a pending zone-deletion (or was captured
    // mid-reset) is reset poison. Discard it and rebuild a fresh engine; resetIntent /
    // pendingSeedIntent / tombstones live in `store` (not the serialization) and drive a
    // clean re-seed. Lost fetch tokens (=> full re-fetch) are the accepted cost of recovering
    // an otherwise-bricked install.
    if store.engineState != nil && restoredStateIsPoisoned() {
      Log.warning(
        "[#286] restored engine state carries a pending zone-deletion; discarding "
          + "serialization and re-bootstrapping", category: .sync)
      store.engineState = nil
      driver = driverFactory(nil)
    }
    funnel = MutationFunnel(
      modelContext: modelContext, store: store, driver: driver, deviceId: deviceId,
      scheduleProfileDeleteCommit: scheduleProfileDeleteCommit)
    reset = ResetController(
      store: store,
      outbox: DriverResetOutbox(driver: driver, zoneID: zoneID),
      seeder: DefaultResetSeeder(
        store: store,
        flush: { [weak self] in await self?.sessionSync.flushSessionCache() },
        seed: { [weak self] in self?.seedZoneAndRecords() },
        clearSelections: { [weak self] in try self?.clearAllLocalProfileSelections() }),
      fetcher: DriverRecordFetcher(driver: driver),
      surfacer: ConflictManagerResetSurfacer(),
      deviceId: deviceId)
    legacyCleanup = LegacyCleanupCoordinator(store: store, driver: driver)
    wireResetHooks()
    performStrip()
    state = .bootstrapping
    let generation = namespaceGeneration
    startupTask = Task { [weak self] in await self?.runStartupSequence(generation: generation) }
  }

  /// Phase F composition (CRA-4): connects the controller's reset hooks to the
  /// `ResetController` constructed above. `onFetchedResetCommand`/`onZoneChangeConfirmed`/
  /// `resetCommandSaveDidSucceed`/`resetCommandSaveDidFail`/`onResumeReset` are all fired
  /// from inside `handle(_:)` (delegate context, §1.1) — hooks that call into async
  /// `ResetController` methods are scheduled via `Task`; the synchronous ones
  /// (`handleZoneSaveConfirmed`, `handleCommandSaveResult`) run inline.
  private func wireResetHooks() {
    onFetchedResetCommand = { [weak self] record in
      Task { await self?.reset?.applyCommand(record) }
    }
    onZoneChangeConfirmed = { [weak self] saved, deleted in
      if !deleted.isEmpty {
        Task { await self?.reset?.handleZoneDeleteConfirmed() }
      }
      if !saved.isEmpty { self?.reset?.handleZoneSaveConfirmed() }
    }
    resetCommandSaveDidSucceed = { [weak self] _ in self?.reset?.handleCommandSaveResult(.saved) }
    // Fix 2 (§8.1 step 5): forward the SERVER record, not the device's own failed record —
    // the local record always carries the device's own requestId (fixed name), so
    // forwarding it made `handleCommandSaveResult` always take the "own ⇒ confirmed"
    // branch and never the foreign ⇒ abandon+surface branch. Gate on the error code
    // (mirrors the generic branch-C path): only `.serverRecordChanged` with a server
    // record is a real outcome to route; any other (transient/other) code keeps the
    // intent as-is — it must NOT be cleared or abandoned here.
    resetCommandSaveDidFail = { [weak self] _, error in
      guard let self, let reset = self.reset else { return }
      if error.code == .serverRecordChanged, let server = error.serverRecord {
        reset.handleCommandSaveResult(.serverRecordChanged(server))
      }
      // else transient/other: keep the intent — do NOT clear or abandon.
    }
    onResumeReset = { [weak self] _ in Task { await self?.reset?.resume() } }
    // T11 (Fix 7): dequeue a live resetIntent's pending zone/command changes BEFORE
    // stop()'s best-effort final sendChanges() — user-initiated disable, never surfaced
    // as a superseded-reset conflict (see ResetController.abandonForStop).
    onStopReset = { [weak self] in self?.reset?.abandonForStop() }
  }

  /// §8.3 step 2 (clear flag) seam for `DefaultResetSeeder.clearSelections`: clears every
  /// local profile's app selection and marks it as needing re-selection, then saves.
  private func clearAllLocalProfileSelections() throws {
    let profiles = try modelContext.fetch(FetchDescriptor<BlockedProfiles>())
    for profile in profiles {
      profile.selectedActivity = .init()
      profile.needsAppSelection = true
    }
    try modelContext.save()
  }

  /// T11: best-effort graceful shutdown. The reset-dequeue hook runs FIRST so it can
  /// discard the resetIntent's own pending zone changes before they are lost anyway;
  /// `pendingSeedIntent` is cleared so a purged/stopped engine does not resume mid-seed.
  /// The final `sendChanges()` is best-effort (N5 mitigation) — nothing awaits it.
  /// Tombstones survive (I12 re-propagates them on the next start). `engineState` is
  /// discarded: any save the engine had not yet flushed to disk is lost (N5), which is
  /// the accepted cost of a synchronous, non-blocking `stop()`.
  func stop() {
    onStopReset?()  // Phase E: clear resetIntent + dequeue its zone changes first
    store.resetIntent = nil
    store.pendingSeedIntent = false
    driver?.sendChanges()  // best-effort final send (N5)
    namespaceGeneration += 1
    startupTask?.cancel()
    flushTask?.cancel()
    fetchCycleSweepTask?.cancel()
    store.engineState = nil  // pending unsent saves lost (N5); tombstones survive
    state = .disabled
  }

  // MARK: - T1 strip (AB-4, S-38, I12)

  /// Removes restored pending state that would otherwise replay stale intent: every
  /// restored pending `.deleteRecord` except `legacyCleanupIds` members (those are
  /// re-enqueued later by §11), and ALL restored pending database changes — a restored
  /// `deleteZone` with no live intent would otherwise replay a zone reset. Record deletes
  /// are re-enqueued only later via I12 recovery; zone changes only via resetIntent resume
  /// / I11 seeding. Runs in the same synchronous main-actor region as driver init (B-7):
  /// no `await` before this returns, so no engine event can interleave.
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

  /// #286: a restored serialization is unsafe to keep if it carries a pending `.deleteZone`
  /// for the sync zone, or if a `resetIntent` is in progress (the reset state machine, not
  /// the restored queue/tokens, is the source of truth for zone changes — defense in depth).
  private func restoredStateIsPoisoned() -> Bool {
    if store.resetIntent != nil { return true }
    return driver.pendingDatabaseChanges.contains {
      if case .deleteZone(let id) = $0 { return id == zoneID }
      return false
    }
  }

  // MARK: - SyncEngineDriverDelegate

  func handle(_ event: SyncEngineEvent) {
    switch event {
    case .willFetchChanges:
      handleWillFetchChanges()
    case .didFetchChanges:
      handleDidFetchChanges()
    case .fetchedRecordZoneChanges(let modifications, let deletions):
      handleFetchedRecordZoneChanges(modifications: modifications, deletions: deletions)
    case .sentRecordZoneChanges(
      let savedRecords, let failedRecordSaves, let deletedRecordIDs, let failedRecordDeletes):
      handleSentRecordZoneChanges(
        savedRecords: savedRecords, failedRecordSaves: failedRecordSaves,
        deletedRecordIDs: deletedRecordIDs, failedRecordDeletes: failedRecordDeletes)
    case .sentDatabaseChanges(
      let savedZones, let failedZoneSaves, let deletedZoneIDs, let failedZoneDeletes):
      handleSentDatabaseChanges(
        savedZones: savedZones, failedZoneSaves: failedZoneSaves,
        deletedZoneIDs: deletedZoneIDs, failedZoneDeletes: failedZoneDeletes)
    case .stateUpdate(let serialization):
      handleStateUpdate(serialization: serialization)
    case .fetchedDatabaseChanges(_, let deletedZones):
      handleZoneDeletions(deletedZones)
    case .accountChange(let kind):
      handleAccountChange(kind)
    }
  }

  // MARK: - T5/T6 zone deletions (§8.4, S-3, S-4)

  /// Routes a DeviceSync-zone deletion by reason. `.deleted`/`.encryptedDataReset` (T5)
  /// KEEP all local data (I1): only the change-tag cache and session cache are purged
  /// (I6), then an intent-first re-seed is enqueued (I11) — nothing is deleted. `.purged`
  /// (T6) means the account itself lost the zone permanently: local data is still kept,
  /// but the engine's own persisted state is discarded and syncing is disabled pending a
  /// one-time user notice; tombstones survive because a delete intent is not
  /// consent-scoped (a re-enabled engine must still honor deletes the user already made).
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

  // MARK: - T7 accountChange (§7)

  /// Stops the engine and invalidates in-flight async continuations by bumping the
  /// namespace generation (I12/§5.6 checks re-verify it before acting) — an account
  /// change purges NOTHING (§7): the namespace switch to the new user's own store is
  /// performed by the app reconstructing the controller/store (Phase F, N11).
  private func handleAccountChange(_ kind: SyncEngineAccountChangeKind) {
    namespaceGeneration += 1  // invalidates in-flight async fetches (they re-check the generation)
    startupTask?.cancel()
    flushTask?.cancel()
    state = .disabled
  }

  // MARK: - T10 stateUpdate persistence (§5.0, AB-2, S-26)

  /// Persists the engine's serialization verbatim (AB-2: safe for fetch tokens). Seed/
  /// tombstone intents never key off this event — they use their own observable signals
  /// (I11 `pendingSeedIntent`, I12 `deleteTombstones`) — so a `stateUpdate` delivered
  /// mid-cycle (e.g. between two fetch events) only ever reflects fetch progress already
  /// handled; it never fabricates or advances intent state (S-26).
  private func handleStateUpdate(serialization: Data) {
    store.engineState = serialization
  }

  // MARK: - T3 fetchedRecordZoneChanges routing (§5.1/§5.2, S-1, S-32)

  /// Routes each fetched modification/deletion (§5.1/§5.2). A fetched `SyncResetRequest` is
  /// diverted to `onFetchedResetCommand` (CRA-2/§8.3) — it is a control command, never a
  /// generic apply. After the modifications loop, CRA-1 drains any reenqueues the apply
  /// produced (I9 older-schema auto-heal / §5.1 equal-version divergence) so they actually
  /// reach the driver as `.saveRecord` pending changes.
  private func handleFetchedRecordZoneChanges(
    modifications: [CKRecord],
    deletions: [(recordID: CKRecord.ID, recordType: CKRecord.RecordType)]
  ) {
    let legacyRecords = modifications.filter { $0.recordType == LegacySyncedSession.recordType }
    if !legacyRecords.isEmpty {
      legacyCleanup?.identify(modifications: legacyRecords)  // §11 — never applied
    }
    for record in modifications {
      if record.recordType == SyncResetRequest.recordType {
        onFetchedResetCommand?(record)  // §8.3 — never applied via applyFetchedModification
        continue
      }
      if record.recordType == LegacySyncedSession.recordType {
        continue  // §11 — routed to legacyCleanup above, never applied
      }
      let outcome = apply.applyFetchedModification(
        record, isPendingDeleteOrTombstoned: blockedPredicate())
      if outcome == .applied {
        store.removeFailedApply(recordName: record.recordID.recordName)  // supersession (§5.6)
      }
    }
    for recordID in apply.drainReenqueues() {  // CRA-1
      driver.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
    }
    for (recordID, recordType) in deletions {
      let outcome = apply.applyFetchedDeletion(recordID: recordID, recordType: recordType)
      guard !(recordType == SyncedProfile.recordType && outcome == .deleted) else { continue }
      applyDeletionSideEffects(recordID: recordID)
      store.removeFailedApply(recordName: recordID.recordName)  // supersession
    }
  }

  // MARK: - T4 sentRecordZoneChanges routing (§5.3, S-10, S-11, S-17, S-23, S-29)

  private static let scopedTypes: Set<String> = [
    SyncedProfile.recordType, SyncedLocation.recordType, SyncedEmergencySettings.recordType,
  ]

  /// Routes each confirmed save/delete and each failed save/delete (§5.3). Confirmed saves
  /// of scoped types store the server-assigned system fields (change tag); the
  /// `SyncResetRequest` command is never a scoped type and stores none — it only fires
  /// `resetCommandSaveDidSucceed` (CRA-3, Phase E/F). Confirmed deletes clear the I12
  /// tombstone, drop cached system fields, and populate the §5.1 echo guard so a fetched
  /// modification racing the same recordName is skipped until a LATER cycle's
  /// `willFetchChanges` drains it (AB-3) — `confirmDeleteCycle[name] = currentCycle` is the
  /// writer half of that drain (Task 68 defined the reader).
  private func handleSentRecordZoneChanges(
    savedRecords: [CKRecord],
    failedRecordSaves: [(record: CKRecord, error: CKError)],
    deletedRecordIDs: [CKRecord.ID],
    failedRecordDeletes: [(recordID: CKRecord.ID, error: CKError)]
  ) {
    var savedCommandRecords: [CKRecord] = []
    store.transaction { s in
      for record in savedRecords {
        let name = record.recordID.recordName
        if record.recordType == SyncResetRequest.recordType {
          savedCommandRecords.append(record)  // CRA-3: command record, no systemFields
          continue
        }
        if Self.scopedTypes.contains(record.recordType) {
          s.setSystemFields(CKRecordSystemFieldsCodec.encode(record), for: name)
        }
        self.clearLegacyId(name, in: s)
        self.resolveSeedName(name)  // I11 observable-clear (Fix 5): save confirmed sent
      }
      for id in deletedRecordIDs {
        let name = id.recordName
        s.setSystemFields(nil, for: name)
        s.clearTombstone(recordName: name)  // I12 confirmed
        self.clearLegacyId(name, in: s)
      }
    }
    // Fired outside `store.transaction` (non-reentrant `SharedData.withLock`): a hook
    // consumer that touches `SharedData` must never be invoked while the lock is held.
    for record in savedCommandRecords {
      resetCommandSaveDidSucceed?(record)  // CRA-3
    }
    for id in deletedRecordIDs {
      apply.recentlyConfirmedDeletes.insert(id.recordName)  // echo guard (§5.1)
      confirmDeleteCycle[id.recordName] = currentCycle  // AB-3 drain writer (Task 68 reader)
    }
    for (record, error) in failedRecordSaves { handleFailedSave(record: record, error: error) }
    for (id, error) in failedRecordDeletes { handleFailedDelete(recordID: id, error: error) }
  }

  // MARK: - T4b sentDatabaseChanges routing (§5.5)

  /// Routes each confirmed zone save/delete and each failed zone save/delete (§5.5).
  /// `savedZones` / `deletedZoneIDs` / a delete failing with `.zoneNotFound` (already gone)
  /// are all "confirmed" from the resetIntent's perspective — Phase E's `ResetController`
  /// advances its stage via `onZoneChangeConfirmed`; nothing is persisted here. A save
  /// failing with `.serverRecordChanged` (zone already exists) is likewise confirmed. Any
  /// other retriable failure is re-added and left to the engine's own backoff; a
  /// non-retriable save failure is logged and resetIntent is left as-is (nothing to
  /// recover to).
  private func handleSentDatabaseChanges(
    savedZones: [CKRecordZone.ID],
    failedZoneSaves: [(zone: CKRecordZone, error: CKError)],
    deletedZoneIDs: [CKRecordZone.ID],
    failedZoneDeletes: [(zoneID: CKRecordZone.ID, error: CKError)]
  ) {
    onZoneChangeConfirmed?(savedZones, deletedZoneIDs)
    if savedZones.contains(zoneID) {
      resolveSeedName(Self.seedZoneMarkerName)  // I11 observable-clear (Fix 5): saveZone confirmed
    }
    for (zone, error) in failedZoneSaves {
      if error.code == .serverRecordChanged {
        onZoneChangeConfirmed?([zone.zoneID], [])  // zone-already-exists ⇒ confirmed
        if zone.zoneID == zoneID {
          resolveSeedName(Self.seedZoneMarkerName)  // I11 observable-clear (Fix 5)
        }
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

  private func clearLegacyId(_ name: String, in s: SyncEngineStore) {
    guard s.legacyCleanupIds.contains(name) else { return }
    s.removeLegacyCleanupId(name)
    if s.legacyCleanupIds.isEmpty { s.legacyCleanupDone = true }
  }

  /// §5.3 failed-save branches: C (`.serverRecordChanged`), Z (`.zoneNotFound`), U-save
  /// (`.unknownItem`), R (retriable, re-add once), F (non-retriable, surfaced + dropped).
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
        store.setSystemFields(
          CKRecordSystemFieldsCodec.encode(server), for: name)  // store server tag first
      }
      _ = apply.applyFetchedModification(server, isPendingDeleteOrTombstoned: blockedPredicate())
      // CRA-1: drain any re-enqueues the apply produced (§5.1 equal-version divergence).
      for recordID in apply.drainReenqueues() {
        driver.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
      }
      // branch 0 / server-newer: apply merged, no re-add. branch E (equal+differing): apply
      // bumped+enqueued+surfaced inside §5.1, drained above. local strictly newer: re-add
      // here.
      if localIsStrictlyNewer(record.recordType, name: name, server: server) {
        driver.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
      }
    case .zoneNotFound:
      seedZoneAndRecords()  // branch Z: saveZone + intent-first seed
      driver.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
    case .unknownItem:
      store.setSystemFields(nil, for: name)  // branch U-save
      driver.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
      resolveSeedName(name)  // I11 observable-clear (Fix 5): this attempt is resolved
    default:
      if isRetriable(error) {
        driver.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])  // branch R, once
      } else {
        surfaceConflict(forRecordName: name, record: record)  // branch F
        // engine already dropped the change; nothing to re-add.
        resolveSeedName(name)  // I11 observable-clear (Fix 5): terminal, dropped
      }
    }
  }

  /// §5.3 failed-delete branches: U-delete (`.unknownItem`, done), Z (recreate + re-add),
  /// R (retriable), F (surfaced, tombstone cleared so it does not loop forever).
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

  /// Compares the local entity's version/timestamp against the server record's, per
  /// recordType (§5.3 branch C local-wins re-add).
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
      let serverUpdated =
        server[SyncedLocation.FieldKey.lastModified.rawValue] as? Date ?? .distantPast
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

  // MARK: - AB-3 fetch-cycle delimiters (T2, S-34, S-37)

  /// Cycle start (AB-3). Bumps the cycle counter, then drains the confirmed-delete echo
  /// guard (§5.1) for every name confirmed in a PRIOR cycle: a cycle beginning after the
  /// confirmation reads post-delete server state, so a modification it delivers is a
  /// genuine recreation and must apply. Draining at cycle COMPLETION instead would swallow
  /// those recreations (round-5) — the drain must happen at the START of the first cycle
  /// after confirmation, not before.
  private func handleWillFetchChanges() {
    currentCycle += 1
    let drained = confirmDeleteCycle.filter { $0.value < currentCycle }.map { $0.key }
    for name in drained {
      apply.recentlyConfirmedDeletes.remove(name)
      confirmDeleteCycle.removeValue(forKey: name)
    }
  }

  /// Cycle end (T2/AB-3). First `didFetchChanges` while bootstrapping ⇒ steady. Then runs
  /// the §5.6 failed-apply sweep for this completed cycle (S-37) — spawned as a detached
  /// unit of async work rather than run inline, since `didFetchChanges` itself must return
  /// synchronously (never awaits from inside a fetch event, B-7).
  private func handleDidFetchChanges() {
    if state == .bootstrapping { state = .steady }  // T2
    let generation = namespaceGeneration
    fetchCycleSweepTask = Task { [weak self] in
      await self?.retryFailedApplies(generation: generation)
    }
  }

  // MARK: - §5.4 nextRecordZoneChangeBatch materialization (S-14, S-29)

  /// Materializes pending `.saveRecord` changes into `CKRecord`s via `provider` and prunes
  /// the driver's pending queue of anything that must never be sent (§5.4). A save whose
  /// `provider.record(forRecordName:)` returns nil (entity absent, or an
  /// `isNewerSchemaVersion` profile) is removed from the pending queue rather than
  /// retained-and-skipped — a stray pending save for a gone/unmaterializable entity would
  /// otherwise be retried forever. A pending `.deleteRecord` with no live tombstone (and not
  /// a `legacyCleanupIds` member) is refused the same way: removed, never sent — this is
  /// defence-in-depth for I12's source-of-truth rule (a delete intent must be backed by a
  /// tombstone). Legacy-cleanup deletes are exempt (kept, re-enqueued by §11 machinery).
  /// Deletes are never materialized as `CKRecord`s here; only saves are returned — the
  /// production adapter drives the delete-by-id path separately. A pending save whose
  /// recordName is `ResetController.commandRecordName` is the fixed-name §8.2 command
  /// record: it is materialized via `reset?.commandRecord(now:)`, NEVER via `provider`
  /// (the provider only knows data entities and always returns nil for it, which used to
  /// silently strip the command from the batch — Fix 1). A nil `commandRecord(now:)`
  /// result (no live `resetIntent`) falls through to the same remove-from-queue path as
  /// any other unmaterializable save.
  func nextRecordZoneChangeBatch(scope: CKSyncEngine.SendChangesOptions.Scope?) -> [CKRecord]? {
    var records: [CKRecord] = []
    var savesToRemove: [CKSyncEngine.PendingRecordZoneChange] = []
    var deletesToRemove: [CKSyncEngine.PendingRecordZoneChange] = []
    let legacy = store.legacyCleanupIds

    for change in driver.pendingRecordZoneChanges {
      switch change {
      case .saveRecord(let id):
        if id.recordName == ResetController.commandRecordName {
          if let command = reset?.commandRecord(now: Date()) {
            records.append(command)
          } else {
            savesToRemove.append(change)  // no live resetIntent to materialize
          }
        } else if let record = provider.record(forRecordName: id.recordName) {
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
    if !savesToRemove.isEmpty {
      driver.remove(pendingRecordZoneChanges: savesToRemove)
      for change in savesToRemove {
        if case .saveRecord(let id) = change {
          resolveSeedName(id.recordName)  // I11 observable-clear (Fix 5, §5.4-removal)
        }
      }
    }
    if !deletesToRemove.isEmpty { driver.remove(pendingRecordZoneChanges: deletesToRemove) }
    return records.isEmpty ? nil : records
  }

  // MARK: - Startup

  private func runStartupSequence(generation: Int) async {
    guard generation == namespaceGeneration else { return }
    await recoverDeleteIntents(generation: generation)
    guard generation == namespaceGeneration else { return }
    await retryFailedApplies(generation: generation)
    guard generation == namespaceGeneration else { return }
    reEnqueueLegacyCleanup()
    await applySeedDecision()
    guard generation == namespaceGeneration else { return }
    if let intent = store.resetIntent { onResumeReset?(intent) }  // §8.1 (Phase E)
    driver.fetchChanges()
  }

  // MARK: - §5.6 failed-apply retry (S-35)

  /// Verify-then-reapply for every persisted `failedApplies` entry (§5.6), run at
  /// controller start (and later after each fetch cycle). `.delete` entries are
  /// re-verified against the server rather than blindly retried: if the record is now
  /// present it was RE-CREATED since the failed delete (branch U-save) — the entry is
  /// dropped and NO delete is applied (round-5 rule). `.upsert` entries re-fetch and
  /// re-run the §5.1 apply; a retry skipped by pending-delete-wins/echo-guard KEEPS its
  /// entry for the next cycle. Any successful apply for a recordName supersedes — clears
  /// the entry regardless of which op originally failed (already handled inside
  /// `SyncApplyService`, which clears by name on every successful path).
  private func retryFailedApplies(generation: Int) async {
    for entry in store.failedApplies {
      guard generation == namespaceGeneration else { return }
      let id = recordID(entry.recordName)
      let result = await driver.fetchRecord(id)
      guard generation == namespaceGeneration else { return }
      switch entry.op {
      case .upsert:
        switch result {
        case .found(let record, _):
          let outcome = apply.applyFetchedModification(
            record, isPendingDeleteOrTombstoned: blockedPredicate())
          // CRA-1: drain any re-enqueues the apply produced (I9 auto-heal / §5.1
          // equal-version divergence) so they actually reach CloudKit.
          for recordID in apply.drainReenqueues() {
            driver.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
          }
          if outcome == .applied {
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
          let outcome = apply.applyFetchedDeletion(recordID: id, recordType: entry.recordType)
          if !(entry.recordType == SyncedProfile.recordType && outcome == .deleted) {
            applyDeletionSideEffects(recordID: id)
            store.removeFailedApply(recordName: entry.recordName)
          }
        case .found:
          if deleteRetryLocalEntityExists(entry) {
            applyDeletionSideEffects(recordID: id)
          }
          store.removeFailedApply(recordName: entry.recordName)  // recreated ⇒ drop, never delete
        case .transientError:
          break  // retry next cycle
        }
      }
    }
  }

  private func deleteRetryLocalEntityExists(_ entry: FailedApply) -> Bool {
    guard let id = UUID(uuidString: entry.recordName) else { return true }
    switch entry.recordType {
    case SyncedProfile.recordType:
      return (try? BlockedProfiles.findProfile(byID: id, in: modelContext)) != nil
    case SyncedLocation.recordType:
      return (try? SavedLocation.find(byID: id, in: modelContext)) != nil
    default:
      return true
    }
  }

  /// Predicate passed to `applyFetchedModification`'s pending-delete-wins gate (§5.1):
  /// true when the recordName has a pending `.deleteRecord`, a live tombstone, or is in
  /// the in-memory confirmed-delete echo guard.
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

  /// Shared §5.2 store/driver effects for an applied deletion (used by retry + later
  /// fetch-cycle deletion handling).
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

  // MARK: - I12 delete-intent recovery (S-29, S-33, CRA-5)

  /// Recovers tombstoned deletes with no pending `.deleteRecord` (any tombstone found at
  /// controller start is a "recovered" intent — this process instance recorded no fresh
  /// delete this session — so all start-time tombstones take the verify-before-delete
  /// path). Entity still present locally ⇒ the local delete never completed ⇒ abort:
  /// clear the tombstone, enqueue nothing (fail-toward-keep, E-3). Entity absent ⇒
  /// verify against the server before re-enqueuing the delete: CRA-5 compares the seam's
  /// `changeTag` (not `record.recordChangeTag`) so the matching-tag ⇒ delete arm is
  /// deterministically testable.
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
      case .found(let record, let serverTag):
        if let tag, let serverTag, serverTag == tag {
          // Matching tag ⇒ enqueue delete; tombstone retained until confirmed.
          driver.add(pendingRecordZoneChanges: [.deleteRecord(recordID(name))])
        } else {
          // Different/absent tag ⇒ re-adopted; clear, surface conflict, no delete.
          store.clearTombstone(recordName: name)
          surfaceConflict(forRecordName: name, record: record)
        }
      case .notFound:
        // Intent already complete; clear.
        store.clearTombstone(recordName: name)
      case .zoneNotFound, .transientError:
        break  // keep tombstone; §5.6 cadence re-verifies once the zone exists again (I12).
      }
    }
  }

  private func entityExists(recordName: String) -> Bool {
    guard let uuid = UUID(uuidString: recordName) else { return false }
    if (try? modelContext.fetch(
      FetchDescriptor<BlockedProfiles>(predicate: #Predicate { $0.id == uuid })
    ).first) != nil {
      return true
    }
    if (try? modelContext.fetch(
      FetchDescriptor<SavedLocation>(predicate: #Predicate { $0.id == uuid })
    ).first) != nil {
      return true
    }
    return false
  }

  private func surfaceConflict(forRecordName name: String, record: CKRecord?) {
    guard let uuid = UUID(uuidString: name) else {
      Log.warning("Conflict surfaced for non-UUID record \(name)", category: .sync)
      return
    }
    let fallbackName = record?[SyncedProfile.FieldKey.name.rawValue] as? String ?? name
    SyncConflictManager.shared.addConflict(profileId: uuid, profileName: fallbackName)
  }

  // MARK: - T1 seed decision (S-19, S-28, I7)

  /// Exactly one of: first-bootstrap seed, crash-recovery purge+re-seed, or (ordinary
  /// relaunch) nothing — the restored `engineState` is authoritative for the queue, so an
  /// ordinary relaunch enqueues zero changes (S-19/I7).
  private func applySeedDecision() async {  // at most one seed (T1)
    if store.engineState == nil {
      seedZoneAndRecords()
    } else if store.pendingSeedIntent {
      await purgeBookkeeping()
      seedZoneAndRecords()
    }
    // else ordinary relaunch (I7): enqueue nothing.
  }

  // MARK: - Legacy cleanup resume (§11, S-38)

  /// Resumes a legacy cleanup interrupted mid-flight: a kill mid-cleanup persisted
  /// `legacyCleanupIds` to the store, and the T1 strip exempted those ids from removal
  /// (they're expected pending intent, not stale replay). Here they're re-enqueued so the
  /// cleanup actually completes. Once `legacyCleanupDone` is set, this is permanently a
  /// no-op.
  private func reEnqueueLegacyCleanup() {
    guard !store.legacyCleanupDone else { return }
    let ids = store.legacyCleanupIds
    guard !ids.isEmpty else { return }
    let existing = pendingDeleteNames()
    let toAdd = ids.subtracting(existing).map {
      CKSyncEngine.PendingRecordZoneChange.deleteRecord(
        CKRecord.ID(recordName: $0, zoneID: zoneID))
    }
    if !toAdd.isEmpty {
      driver.add(pendingRecordZoneChanges: toAdd)
    }
  }

  private func pendingDeleteNames() -> Set<String> {
    Set(
      driver.pendingRecordZoneChanges.compactMap {
        if case .deleteRecord(let id) = $0 { return id.recordName } else { return nil }
      })
  }

  // MARK: - I11 seeding (crash-durable re-seed)

  /// Crash-durable re-seed: persists intent BEFORE enqueuing anything, so a kill mid-seed
  /// leaves `pendingSeedIntent` set and the next launch re-runs this in full (I11). Enqueues
  /// the zone save first — a database change — so it sends ahead of the record saves per the
  /// engine's own AB-1 ordering guarantee (S-25). Seeds every restorable local entity except
  /// sessions, which are owned by SessionSyncService and never seeded here (§6/N13).
  ///
  /// Fix 5 (I11 observable-clear): the restorable names plus `seedZoneMarkerName` (standing
  /// in for the saveZone leg) are recorded into `pendingSeedNames` — the outstanding set this
  /// batch must observe resolved before `pendingSeedIntent` is cleared (never on a fetch or
  /// an assumption, only on an observed send outcome).
  func seedZoneAndRecords() {
    store.pendingSeedIntent = true  // intent-first (I11)
    driver.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
    let names = restorableRecordNames()
    pendingSeedNames.formUnion(names)
    pendingSeedNames.insert(Self.seedZoneMarkerName)
    let saves = names.map {
      CKSyncEngine.PendingRecordZoneChange.saveRecord(recordID($0))
    }
    if !saves.isEmpty { driver.add(pendingRecordZoneChanges: saves) }
  }

  /// Removes `name` from the outstanding I11 seed-batch set (if present) and clears
  /// `store.pendingSeedIntent` once every seeded name (restorable records + the zone
  /// marker) has been observed sent/terminally-resolved. Called only from observed driver
  /// outcomes (confirmed save, confirmed saveZone, or a terminal/dropped failure) — never
  /// from a fetch or an assumption (I11).
  private func resolveSeedName(_ name: String) {
    guard pendingSeedNames.remove(name) != nil else { return }
    if pendingSeedNames.isEmpty {
      store.pendingSeedIntent = false
    }
  }

  /// The recordNames to seed: every local profile (excluding `isNewerSchemaVersion`), every
  /// location, and the emergency-settings record. Never sessions (§6/N13). The provider
  /// naturally excludes absent entities and `isNewerSchemaVersion` profiles (§5.4) by
  /// returning nil for them.
  func restorableRecordNames() -> [String] {
    var names: [String] = []
    let profiles = (try? modelContext.fetch(FetchDescriptor<BlockedProfiles>())) ?? []
    names.append(contentsOf: profiles.map { $0.id.uuidString })
    let locations = (try? modelContext.fetch(FetchDescriptor<SavedLocation>())) ?? []
    names.append(contentsOf: locations.map { $0.id.uuidString })
    names.append(SyncedEmergencySettings.recordName)
    return names.filter { provider.record(forRecordName: $0) != nil }
  }

  /// I6: purges the change-tag cache and flushes the session cache. Used by re-seed entry
  /// points before re-seeding.
  private func purgeBookkeeping() async {
    store.purgeAllSystemFields()
    await sessionSync.flushSessionCache()
  }

  private func recordID(_ name: String) -> CKRecord.ID {
    CKRecord.ID(recordName: name, zoneID: zoneID)
  }
}

extension Notification.Name {
  /// Posted once when T6 discovers the DeviceSync zone was permanently purged (Phase F
  /// wires the one-time user-facing notice).
  static let syncEnginePurged = Notification.Name("family_foqos_sync_engine_purged")
}
