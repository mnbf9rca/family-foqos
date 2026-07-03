import Foundation
import SwiftData
import SwiftUI
import WidgetKit

/// Typed errors for the emergency unblock flow.
/// Covers all failure modes: no unblocks remaining, no active session, and geofence restrictions.
enum EmergencyUnblockError: LocalizedError {
  case noUnblocksRemaining
  case noActiveSession
  case locationPermissionNeeded
  case locationPermissionDenied
  case geofenceBlocked(String)
  case locationLoadFailed

  var errorDescription: String? {
    switch self {
    case .noUnblocksRemaining:
      return "No emergency unblocks remaining."
    case .noActiveSession:
      return "No active session to unblock."
    case .locationPermissionNeeded:
      return "Please allow location access to use emergency unblock, then try again."
    case .locationPermissionDenied:
      return
        "Location access is denied. Enable location services in Settings to use emergency unblock."
    case .geofenceBlocked(let message):
      return message
    case .locationLoadFailed:
      return "Unable to load saved locations. Please try again."
    }
  }
}

/// Manages emergency unblock state (UserDefaults-backed counters, reset periods,
/// lock settings) and logic (unblock, reset, CloudKit sync).
/// Uses completion closures for session stop to avoid circular dependency with StrategyManager.
@MainActor
class EmergencyUnblockManager: ObservableObject {
  static let shared = EmergencyUnblockManager()

  private let geofenceEvaluator: GeofenceEvaluator
  private let profileSyncManager: ProfileSyncManager

  init(
    geofenceEvaluator: GeofenceEvaluator = .shared,
    profileSyncManager: ProfileSyncManager = .shared
  ) {
    self.geofenceEvaluator = geofenceEvaluator
    self.profileSyncManager = profileSyncManager
  }

  private enum DefaultsKey {
    static let unblocksRemaining = "family_foqos_emergency_unblocks_remaining"
    static let resetPeriodInDays = "family_foqos_emergency_unblocks_reset_period_in_days"
    static let lastResetDate = "family_foqos_last_emergency_unblocks_reset_date"
    static let settingsLocked = "family_foqos_emergency_settings_locked"
    static let settingsVersion = "family_foqos_emergency_settings_version"
  }

  @Published private var emergencyUnblocksRemaining: Int =
    UserDefaults.standard.object(forKey: DefaultsKey.unblocksRemaining) != nil
    ? UserDefaults.standard.integer(forKey: DefaultsKey.unblocksRemaining)
    : 3
  {
    didSet {
      UserDefaults.standard.set(emergencyUnblocksRemaining, forKey: DefaultsKey.unblocksRemaining)
    }
  }

  @Published private var emergencyUnblocksResetPeriodInDays: Int =
    UserDefaults.standard.object(forKey: DefaultsKey.resetPeriodInDays) != nil
    ? UserDefaults.standard.integer(forKey: DefaultsKey.resetPeriodInDays)
    : 28
  {
    didSet {
      UserDefaults.standard.set(
        emergencyUnblocksResetPeriodInDays, forKey: DefaultsKey.resetPeriodInDays)
    }
  }

  @Published private var lastEmergencyUnblocksResetDateTimestamp: Double =
    UserDefaults.standard.object(forKey: DefaultsKey.lastResetDate) != nil
    ? UserDefaults.standard.double(forKey: DefaultsKey.lastResetDate)
    : 0
  {
    didSet {
      UserDefaults.standard.set(
        lastEmergencyUnblocksResetDateTimestamp, forKey: DefaultsKey.lastResetDate)
    }
  }

  @Published private var emergencySettingsLockedStorage: Bool =
    UserDefaults.standard.object(forKey: DefaultsKey.settingsLocked) != nil
    ? UserDefaults.standard.bool(forKey: DefaultsKey.settingsLocked)
    : false
  {
    didSet {
      UserDefaults.standard.set(emergencySettingsLockedStorage, forKey: DefaultsKey.settingsLocked)
    }
  }

  private(set) var emergencySettingsVersion: Int =
    UserDefaults.standard.object(forKey: DefaultsKey.settingsVersion) != nil
    ? UserDefaults.standard.integer(forKey: DefaultsKey.settingsVersion)
    : 0
  {
    didSet {
      UserDefaults.standard.set(emergencySettingsVersion, forKey: DefaultsKey.settingsVersion)
    }
  }

  /// Increment the synced emergency-settings version as part of MutationFunnel's save path (I2).
  /// The property's `didSet` persists the new value immediately.
  func incrementEmergencySettingsVersionForSync() {
    emergencySettingsVersion += 1
  }

  // MARK: - Queries

  func getRemainingEmergencyUnblocks() -> Int {
    return emergencyUnblocksRemaining
  }

  func getNextResetDate() -> Date? {
    guard lastEmergencyUnblocksResetDateTimestamp > 0 else {
      return nil
    }

    let lastResetDate = Date(
      timeIntervalSinceReferenceDate: lastEmergencyUnblocksResetDateTimestamp)
    let calendar = Calendar.current
    return calendar.date(
      byAdding: .day,
      value: emergencyUnblocksResetPeriodInDays,
      to: lastResetDate
    )
  }

  func getResetPeriodInDays() -> Int {
    return emergencyUnblocksResetPeriodInDays
  }

  func isEmergencySettingsLocked() -> Bool {
    emergencySettingsLockedStorage
  }

  // MARK: - Mutations

  func setResetPeriodInDays(_ days: Int) {
    emergencyUnblocksResetPeriodInDays = days
    lastEmergencyUnblocksResetDateTimestamp = Date().timeIntervalSinceReferenceDate
    pushEmergencySettingsToCloudKit()
  }

  func setEmergencySettingsLocked(_ locked: Bool) {
    emergencySettingsLockedStorage = locked
    pushEmergencySettingsToCloudKit()
  }

  func resetEmergencyUnblocks() {
    emergencyUnblocksRemaining = 3
    lastEmergencyUnblocksResetDateTimestamp = Date().timeIntervalSinceReferenceDate
    pushEmergencySettingsToCloudKit()
  }

  func checkAndResetEmergencyUnblocks() {
    // Initialize the last reset date if it hasn't been set
    if lastEmergencyUnblocksResetDateTimestamp == 0 {
      lastEmergencyUnblocksResetDateTimestamp = Date().timeIntervalSinceReferenceDate
      return
    }

    let lastResetDate = Date(
      timeIntervalSinceReferenceDate: lastEmergencyUnblocksResetDateTimestamp)
    let periodInSeconds: TimeInterval = TimeInterval(
      emergencyUnblocksResetPeriodInDays * 24 * 60 * 60)
    let elapsedTime = Date().timeIntervalSince(lastResetDate)

    // Check if the reset period has elapsed
    if elapsedTime >= periodInSeconds {
      emergencyUnblocksRemaining = 3
      lastEmergencyUnblocksResetDateTimestamp = Date().timeIntervalSinceReferenceDate
      pushEmergencySettingsToCloudKit()
    }
  }

  // MARK: - Emergency Unblock

  /// Perform an emergency unblock if allowed. Checks remaining count and geofence rules.
  /// Throws EmergencyUnblockError on failure. Calls `onUnblock` closure on success to delegate
  /// the actual session stop to StrategyManager.
  func emergencyUnblock(
    context: ModelContext,
    activeSession: BlockedProfileSession?,
    onUnblock: @escaping (ModelContext, BlockedProfileSession) -> Void
  ) async throws(EmergencyUnblockError) {
    guard emergencyUnblocksRemaining > 0 else {
      throw .noUnblocksRemaining
    }

    guard let activeSession else {
      throw .noActiveSession
    }

    // Check geofence rule if one exists and emergency override is not allowed
    if let geofenceRule = activeSession.blockedProfile.geofenceRule,
      geofenceRule.hasLocations,
      !geofenceRule.allowEmergencyOverride
    {
      try await geofenceEvaluator.checkGeofenceForEmergencyUnblock(
        context: context, rule: geofenceRule
      )
    }

    performEmergencyUnblock(context: context, session: activeSession, onUnblock: onUnblock)
  }

  /// Actually perform the emergency unblock (called after all checks pass)
  private func performEmergencyUnblock(
    context: ModelContext,
    session: BlockedProfileSession,
    onUnblock: @escaping (ModelContext, BlockedProfileSession) -> Void
  ) {
    onUnblock(context, session)

    // Decrement the remaining emergency unblocks
    emergencyUnblocksRemaining -= 1
    pushEmergencySettingsToCloudKit()

    // Refresh widgets when emergency unblock ends session
    WidgetCenter.shared.reloadTimelines(ofKind: "ProfileControlWidget")
  }

  // MARK: - CloudKit Sync

  /// Apply emergency settings received from CloudKit sync
  func applyRemoteEmergencySettings(_ remote: SyncedEmergencySettings) {
    emergencyUnblocksRemaining = remote.unblocksRemaining
    emergencyUnblocksResetPeriodInDays = remote.resetPeriodInDays
    lastEmergencyUnblocksResetDateTimestamp = remote.lastResetDate.timeIntervalSinceReferenceDate
    emergencySettingsLockedStorage = remote.settingsLocked
    emergencySettingsVersion = remote.version
  }

  /// Snapshot of the current emergency settings for CKRecord materialization (RecordProvider).
  /// Reads the current version verbatim — never bumps (I2: version bumps only in MutationFunnel).
  func currentEmergencySettings(deviceId: String, now: Date = Date()) -> SyncedEmergencySettings {
    SyncedEmergencySettings(
      unblocksRemaining: emergencyUnblocksRemaining,
      resetPeriodInDays: emergencyUnblocksResetPeriodInDays,
      lastResetDate: Date(
        timeIntervalSinceReferenceDate: lastEmergencyUnblocksResetDateTimestamp),
      settingsLocked: emergencySettingsLockedStorage,
      version: emergencySettingsVersion,
      lastModified: now,
      originDeviceId: deviceId
    )
  }

  private func pushEmergencySettingsToCloudKit() {
    guard profileSyncManager.isEnabled else { return }

    // The funnel owns the version bump-in-write (I2) and materializes the record from
    // `currentEmergencySettings`, so no local version bump or payload construction here.
    profileSyncManager.enqueueEmergencySettingsSave()
  }
}
