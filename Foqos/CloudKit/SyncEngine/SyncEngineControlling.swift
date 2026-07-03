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
