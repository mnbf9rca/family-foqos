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

  /// Forwards to the `ResetController` composed in `start()` (CRA-4, Task 134b). A no-op
  /// (with a warning) if called before the engine has been started.
  func beginReset(clearRemoteAppSelections: Bool) {
    guard let reset else {
      Log.warning("beginReset called before start() — no ResetController — no-op", category: .sync)
      return
    }
    reset.beginReset(clearRemoteAppSelections: clearRemoteAppSelections, now: Date())
  }

  // The engine's `MutationFunnel` is created in `start()`, so it can briefly be nil even
  // once `SyncEngineController` itself exists (I10 attach window). Every verb below throws
  // `SyncEngineControllingError.notAttached` in that case instead of silently no-op'ing
  // (review findings #2–#6) and otherwise propagates whatever the funnel itself throws
  // instead of swallowing it (review finding #15) — callers decide how to react.
  func enqueueProfileSave(_ id: UUID) throws {
    guard let funnel else { throw SyncEngineControllingError.notAttached }
    try funnel.enqueueSave(profileId: id)
  }
  func enqueueProfileDelete(_ id: UUID) throws {
    try enqueueProfileDelete(id, requestSyncAfterPendingDelete: false)
  }
  func enqueueProfileDelete(_ id: UUID, requestSyncAfterPendingDelete: Bool) throws {
    guard let funnel else { throw SyncEngineControllingError.notAttached }
    let onPendingDeleteEnqueued: @MainActor () -> Void = { [weak self] in
      if requestSyncAfterPendingDelete { self?.requestSync() }
    }
    try funnel.enqueueDelete(
      profileId: id,
      onPendingDeleteEnqueued: onPendingDeleteEnqueued)
  }
  func enqueueLocationSave(_ id: UUID) throws {
    guard let funnel else { throw SyncEngineControllingError.notAttached }
    try funnel.enqueueSave(locationId: id)
  }
  func enqueueLocationDelete(_ id: UUID) throws {
    guard let funnel else { throw SyncEngineControllingError.notAttached }
    try funnel.enqueueDelete(locationId: id)
  }
  func enqueueEmergencySettingsSave() throws {
    guard let funnel else { throw SyncEngineControllingError.notAttached }
    funnel.enqueueEmergencySettingsSave()
  }
  func enqueueDeferredDelete(recordName: String) {
    funnel?.enqueueTombstoneDelete(recordName: recordName)
  }
}
