import Foundation

/// Typed contract for sync events from ProfileSyncManager to SyncCoordinator.
/// Replaces NotificationCenter event bus with compile-time-safe delegate calls.
@MainActor
protocol SyncEventDelegate: AnyObject {
  func didReceiveSyncedProfiles(_ profiles: [SyncedProfile], remoteProfileIds: Set<UUID>)
  func didReceiveSessionRecords(_ sessions: [ProfileSessionRecord])
  func didReceiveSyncedLocations(_ locations: [SyncedLocation], remoteLocationIds: Set<UUID>)
  func didReceiveSyncReset(clearAppSelections: Bool)
  func didReceiveEmergencySettings(_ settings: SyncedEmergencySettings)
  func didRequestLocalDataPush()
}
