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

  func enqueueProfileSave(_ id: UUID) {
    do {
      try funnel?.enqueueSave(profileId: id)
    } catch {
      Log.error("enqueueProfileSave failed: \(error.localizedDescription)", category: .sync)
    }
  }
  func enqueueProfileDelete(_ id: UUID) {
    do {
      try funnel?.enqueueDelete(profileId: id)
    } catch {
      Log.error("enqueueProfileDelete failed: \(error.localizedDescription)", category: .sync)
    }
  }
  func enqueueLocationSave(_ id: UUID) {
    do {
      try funnel?.enqueueSave(locationId: id)
    } catch {
      Log.error("enqueueLocationSave failed: \(error.localizedDescription)", category: .sync)
    }
  }
  func enqueueLocationDelete(_ id: UUID) {
    do {
      try funnel?.enqueueDelete(locationId: id)
    } catch {
      Log.error("enqueueLocationDelete failed: \(error.localizedDescription)", category: .sync)
    }
  }
  func enqueueEmergencySettingsSave() {
    do {
      try funnel?.enqueueEmergencySettingsSave()
    } catch {
      Log.error("enqueueEmergencySettingsSave failed: \(error.localizedDescription)", category: .sync)
    }
  }
}
