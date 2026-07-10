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
  /// Request a best-effort send; the production driver crosses a detached task boundary (§1.1).
  func requestSend()
  /// #286: purge pending CKSyncEngine work before deleting the zone. This is defensive
  /// reset hygiene (stale record changes are re-derived after recreation), while the
  /// sendChanges crash itself is prevented by the driver's detached task boundary.
  func clearPendingChangesForReset()
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
    guard store.resetIntent == nil else {
      Log.warning("beginReset called while a reset is already in progress — ignoring", category: .sync)
      return
    }
    let id = UUID()
    store.transaction { s in
      s.resetIntent = ResetIntent(
        id: id, clear: clear, stage: .deleting, priorCommandId: s.lastAppliedResetCommandId)
      s.markProcessed(id)  // I4 pre-mark carve-out (safe via §8.3 own-origin check)
      s.lastAppliedResetCommandId = id
    }
    outbox.clearPendingChangesForReset()  // #286: purge stale queue before destructive reset
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

  /// T11: user-initiated sync disable — NOT a supersession. Dequeues a live resetIntent's
  /// pending zone/command changes (mirrors `abandon(_:)`'s dequeue) and clears the intent,
  /// but never calls `surfacer` — the user disabled sync themselves, so no "reset did not
  /// run" conflict may be surfaced. Called from `SyncEngineController.stop()` via
  /// `onStopReset`, BEFORE the controller's own best-effort final `sendChanges()`, so a
  /// mid-reset `deleteZone`/`saveZone` (and the command save) never reach CloudKit.
  func abandonForStop() {
    guard store.resetIntent != nil else { return }
    outbox.removeCommandSave()
    outbox.removeResetZoneChanges()
    store.resetIntent = nil
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
    outbox.clearPendingChangesForReset()  // #286: quiesce before re-adding the deleteZone
    outbox.enqueueZoneDelete()
    outbox.requestSend()
  }
}
