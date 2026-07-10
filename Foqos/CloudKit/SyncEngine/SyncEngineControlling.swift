import Foundation

/// Facade seam between the `ProfileSyncManager` UI surface and the engine owner (I10).
/// `SyncEngineController` conforms in Phase F (Task 131); tests inject a spy.
@MainActor
protocol SyncEngineControlling: AnyObject {
  func start()
  func stop()
  func requestSync()
  func beginReset(clearRemoteAppSelections: Bool)
  func enqueueProfileSave(_ id: UUID) throws
  func enqueueProfileDelete(_ id: UUID) throws
  func enqueueProfileDelete(_ id: UUID, requestSyncAfterPendingDelete: Bool) throws
  func enqueueLocationSave(_ id: UUID) throws
  func enqueueLocationDelete(_ id: UUID) throws
  func enqueueEmergencySettingsSave() throws
  func enqueueEmergencyUnblockEvent(_ event: SyncedEmergencyUnblockEvent) throws
  func enqueueEmergencyEpochSave() throws
  func enqueueEmergencyUnblockEventDelete(_ recordName: String) throws
  func enqueueDeferredDelete(recordName: String)
}

/// Thrown by the `SyncEngineControlling` enqueue verbs (and by `ProfileSyncManager.syncNow()`/
/// `resetSync(...)`) when the engine isn't reachable yet — either `ProfileSyncManager.
/// engineController` is nil (the brief window after cold launch before `attachEngine`
/// finishes) or the concrete controller's `MutationFunnel` hasn't been created yet (before
/// `start()` runs). Callers that perform a destructive mutation (delete) MUST fall back to a
/// direct local mutation on this case so the item is never silently left behind (review
/// findings #2–#6); callers that perform a non-destructive save may simply log and rely on
/// the engine picking the change up once attached / on the next manual sync.
enum SyncEngineControllingError: Error, Equatable {
  case notAttached
}

extension SyncEngineControllingError: LocalizedError {
  var errorDescription: String? {
    switch self {
    case .notAttached:
      return "Sync isn't ready yet. Please try again in a moment."
    }
  }
}
