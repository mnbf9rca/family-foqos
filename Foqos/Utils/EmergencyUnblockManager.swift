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

  private let geofenceEvaluator = GeofenceEvaluator.shared
  private let profileSyncManager = ProfileSyncManager.shared

  private enum DefaultsKey {
    static let unblocksRemaining = "emergencyUnblocksRemaining"
    static let resetPeriodInDays = "emergencyUnblocksResetPeriodInDays"
    static let lastResetDate = "lastEmergencyUnblocksResetDate"
    static let settingsLocked = "emergencySettingsLocked"
    static let settingsVersion = "emergencySettingsVersion"
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
  /// Calls `onUnblock` closure to delegate the actual session stop to StrategyManager.
  func emergencyUnblock(
    context: ModelContext,
    activeSession: BlockedProfileSession?,
    onUnblock: @escaping (ModelContext, BlockedProfileSession) -> Void
  ) {
    // Do not allow emergency unblocks if there are no remaining
    if emergencyUnblocksRemaining == 0 {
      return
    }

    // Do not allow emergency unblocks if there is no active session
    guard let activeSession else {
      return
    }

    // Check geofence rule if one exists and emergency override is not allowed
    if let geofenceRule = activeSession.blockedProfile.geofenceRule,
      geofenceRule.hasLocations,
      !geofenceRule.allowEmergencyOverride
    {
      geofenceEvaluator.checkGeofenceAndEmergencyUnblock(
        context: context, rule: geofenceRule, session: activeSession
      ) { ctx, sess in
        self.performEmergencyUnblock(context: ctx, session: sess, onUnblock: onUnblock)
      }
      return
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

  private func pushEmergencySettingsToCloudKit() {
    guard profileSyncManager.isEnabled else { return }

    let nextVersion = emergencySettingsVersion + 1
    let settings = SyncedEmergencySettings(
      unblocksRemaining: emergencyUnblocksRemaining,
      resetPeriodInDays: emergencyUnblocksResetPeriodInDays,
      lastResetDate: Date(
        timeIntervalSinceReferenceDate: lastEmergencyUnblocksResetDateTimestamp),
      settingsLocked: emergencySettingsLockedStorage,
      version: nextVersion,
      lastModified: Date(),
      originDeviceId: SharedData.deviceSyncId.uuidString
    )

    Task {
      do {
        try await profileSyncManager.pushEmergencySettings(settings)
        await MainActor.run { self.emergencySettingsVersion = nextVersion }
      } catch {
        Log.error(
          "Failed to push emergency settings: \(error.localizedDescription)", category: .sync)
      }
    }
  }
}
