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
  private let database: CKDatabase

  init(database: CKDatabase, stateSerialization: Data?, delegate: SyncEngineDriverDelegate) {
    self.delegate = delegate
    self.restoredState = stateSerialization
    self.database = database
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
    // [#286 DIAGNOSTIC — remove before the fix ships] Log the exact pending-queue shape
    // handed to CloudKit at every send. The crash reports show a synchronous CloudKit
    // assertion at the top of engine.sendChanges(); the last line logged before the abort
    // is the poison shape. Grep Console for "#286".
    Log.error(
      "[#286] sendChanges pending: db=\(Self.describePending(engine.state.pendingDatabaseChanges)) "
        + "rec=\(Self.describePendingRecords(engine.state.pendingRecordZoneChanges))",
      category: .sync)
    Task { try? await engine.sendChanges() }
  }

  /// [#286 DIAGNOSTIC] Human-readable pending database-change summary.
  static func describePending(_ changes: [CKSyncEngine.PendingDatabaseChange]) -> String {
    changes.map {
      switch $0 {
      case .saveZone(let z): return "saveZone(\(z.zoneID.zoneName))"
      case .deleteZone(let id): return "deleteZone(\(id.zoneName))"
      @unknown default: return "?"
      }
    }.joined(separator: ",")
  }

  /// [#286 DIAGNOSTIC] Human-readable pending record-change summary.
  static func describePendingRecords(_ changes: [CKSyncEngine.PendingRecordZoneChange]) -> String {
    changes.map {
      switch $0 {
      case .saveRecord(let id): return "save(\(id.recordName))"
      case .deleteRecord(let id): return "del(\(id.recordName))"
      @unknown default: return "?"
      }
    }.joined(separator: ",")
  }

  func fetchRecord(_ id: CKRecord.ID) async -> FetchRecordResult {
    do {
      let record = try await database.record(for: id)
      return .found(record, changeTag: record.recordChangeTag)
    } catch let error as CKError {
      switch error.code {
      case .unknownItem: return .notFound
      case .zoneNotFound, .userDeletedZone: return .zoneNotFound
      default: return .transientError(error)
      }
    } catch {
      return .transientError((error as? CKError) ?? CKError(.serviceUnavailable))
    }
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
    await batchOnMain(scope: context.options.scope)
  }

  @MainActor
  private func handleOnMain(_ event: CKSyncEngine.Event) {
    guard let translated = Self.translate(event) else { return }
    delegate?.handle(translated)
  }

  /// Fix 4: reads `engine.state.pendingRecordZoneChanges` AFTER the delegate call, not a
  /// pre-captured snapshot. `delegate?.nextRecordZoneChangeBatch(scope:)` (§5.4) may itself
  /// call `driver.remove(...)` to prune a refused tombstone-less delete — a snapshot taken
  /// before that prune runs would still emit the refused delete to CloudKit.
  @MainActor
  private func batchOnMain(
    scope: CKSyncEngine.SendChangesOptions.Scope
  ) -> CKSyncEngine.RecordZoneChangeBatch? {
    let saves = delegate?.nextRecordZoneChangeBatch(scope: scope) ?? []
    let deletes = engine.state.pendingRecordZoneChanges.compactMap { change -> CKRecord.ID? in
      if case .deleteRecord(let id) = change, scope.contains(change) { return id }
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
