import CloudKit

@testable import FamilyFoqos

/// Phase-F-local recording driver for the cutover integration tests (Task 131). Mirrors
/// Phase A's `MockSyncEngineDriver` shape but is kept separate so this phase is
/// self-contained; also used by Tasks 136/137.
@MainActor
final class CutoverRecordingDriver: SyncEngineDriver {
  var stateSerialization: Data?
  private(set) var recordChanges: [CKSyncEngine.PendingRecordZoneChange] = []
  private(set) var databaseChanges: [CKSyncEngine.PendingDatabaseChange] = []
  private(set) var fetchChangesCount = 0
  private(set) var sendChangesCount = 0
  private(set) var shutdownCallCount = 0

  var fetchRecordResults: [String: FetchRecordResult] = [:]
  var defaultFetchRecordResult: FetchRecordResult = .notFound

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
  func fetchRecord(_ id: CKRecord.ID) async -> FetchRecordResult {
    fetchRecordResults[id.recordName] ?? defaultFetchRecordResult
  }
  func shutdown() { shutdownCallCount += 1 }

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
