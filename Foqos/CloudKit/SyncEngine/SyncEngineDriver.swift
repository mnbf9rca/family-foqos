import CloudKit

/// Result of a single-record fetch (I12 verify S-33, §5.6 `.delete` verify S-35, §8.1 reset
/// gate). CRA-5: `.found` carries the fetched record's `changeTag` alongside the record so
/// callers can compare it against a locally-known tag without re-deriving it from `record`
/// (keeps the S-33 "matching tag ⇒ delete" arm deterministically testable).
enum FetchRecordResult {
  case found(CKRecord, changeTag: String?)
  case notFound
  case zoneNotFound
  case transientError(CKError)
}

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
  func fetchChanges()  // CKSyncEngine await MUST cross a detached boundary (§1.1)
  func sendChanges()  // CKSyncEngine await MUST cross a detached boundary (§1.1)
  func fetchRecord(_ id: CKRecord.ID) async -> FetchRecordResult
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
    scope: CKSyncEngine.SendChangesOptions.Scope?
  ) -> [CKRecord]?
}
