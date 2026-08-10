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
  private(set) var shutdownCallCount = 0

  var stateSerialization: Data?
  var pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange]
  private(set) var pendingDatabaseChanges: [CKSyncEngine.PendingDatabaseChange]

  var fetchRecordResults: [String: FetchRecordResult] = [:]
  var defaultFetchRecordResult: FetchRecordResult = .notFound
  var beforeFetchRecord: (() async -> Void)?
  private(set) var fetchedRecordIDs: [CKRecord.ID] = []

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

  func reset() {
    operations.removeAll()
    fetchChangesCount = 0
    sendChangesCount = 0
  }

  func setPendingRecordZoneChangesForTest(
    _ changes: [CKSyncEngine.PendingRecordZoneChange]
  ) {
    pendingRecordZoneChanges = changes
  }

  func setPendingDatabaseChangesForTest(
    _ changes: [CKSyncEngine.PendingDatabaseChange]
  ) {
    pendingDatabaseChanges = changes
  }

  func fetchRecord(_ id: CKRecord.ID) async -> FetchRecordResult {
    fetchedRecordIDs.append(id)
    await beforeFetchRecord?()
    return fetchRecordResults[id.recordName] ?? defaultFetchRecordResult
  }

  func shutdown() {
    shutdownCallCount += 1
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

  /// Deliver a full fetch cycle: willFetchChanges, then the inner record/state events,
  /// then didFetchChanges (AB-3 delimiters). Used by the echo-guard/cycle-scoping tests.
  func deliverFetchCycle(_ innerEvents: [SyncEngineEvent]) {
    delegate?.handle(.willFetchChanges)
    for event in innerEvents { delegate?.handle(event) }
    delegate?.handle(.didFetchChanges)
  }

  /// Pull a materialized batch from the delegate for a given scope (§5.4).
  func pullNextRecordZoneChangeBatch(
    scope: CKSyncEngine.SendChangesOptions.Scope?
  ) -> [CKRecord]? {
    delegate?.nextRecordZoneChangeBatch(scope: scope)
  }
}
