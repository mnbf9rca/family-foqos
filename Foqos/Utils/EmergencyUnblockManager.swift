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
  private let defaults: UserDefaults

  init(
    defaults: UserDefaults = .standard,
    geofenceEvaluator: GeofenceEvaluator = .shared,
    profileSyncManager: ProfileSyncManager = .shared
  ) {
    self.defaults = defaults
    self.geofenceEvaluator = geofenceEvaluator
    self.profileSyncManager = profileSyncManager
  }

  private enum DefaultsKey {
    static let resetPeriodInDays = "family_foqos_emergency_unblocks_reset_period_in_days"
    static let lastResetDate = "family_foqos_last_emergency_unblocks_reset_date"
    static let settingsLocked = "family_foqos_emergency_settings_locked"
    static let settingsVersion = "family_foqos_emergency_settings_version"
  }

  private enum LedgerKey {
    static let events = "family_foqos_emergency_unblock_events"
    static let resetEpoch = "family_foqos_emergency_reset_epoch"
    static let allowance = 3
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
    let consumed = unblockEvents.filter { $0.resetEpoch == currentResetEpoch }.count
    return max(0, LedgerKey.allowance - consumed)
  }

  var currentResetEpoch: Int {
    get { defaults.integer(forKey: LedgerKey.resetEpoch) }
    set { defaults.set(newValue, forKey: LedgerKey.resetEpoch) }
  }

  private var unblockEvents: [SyncedEmergencyUnblockEvent] {
    get {
      guard let data = defaults.data(forKey: LedgerKey.events),
        let events = try? JSONDecoder().decode([SyncedEmergencyUnblockEvent].self, from: data)
      else {
        return []
      }
      return events
    }
    set {
      if let data = try? JSONEncoder().encode(newValue) {
        defaults.set(data, forKey: LedgerKey.events)
      }
    }
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

  /// Records a locally-consumed unblock as an immutable event at the current epoch and returns it
  /// for the caller to enqueue through the funnel. The sync push is deliberately separate.
  func consumeUnblockEvent(now: Date) -> SyncedEmergencyUnblockEvent {
    let event = SyncedEmergencyUnblockEvent(
      id: UUID(),
      deviceId: SharedData.deviceSyncId.uuidString,
      consumedAt: now,
      resetEpoch: currentResetEpoch)
    var all = unblockEvents
    all.append(event)
    unblockEvents = all
    objectWillChange.send()
    return event
  }

  /// Union insert of a remote event, idempotent by event id.
  func mergeRemoteUnblockEvent(_ event: SyncedEmergencyUnblockEvent) {
    var all = unblockEvents
    guard !all.contains(where: { $0.id == event.id }) else { return }
    all.append(event)
    unblockEvents = all
    objectWillChange.send()
  }

  func eventRecord(forRecordName recordName: String) -> SyncedEmergencyUnblockEvent? {
    unblockEvents.first { $0.recordName == recordName }
  }

  func allUnblockEventRecordNames() -> [String] {
    unblockEvents.map { $0.recordName }
  }

  /// Events from epochs strictly older than the merged monotonic epoch are safe to prune (#221).
  func staleUnblockEventRecordNames() -> [String] {
    unblockEvents.filter { $0.resetEpoch < currentResetEpoch }.map { $0.recordName }
  }

  func removeUnblockEvent(recordName: String) {
    unblockEvents = unblockEvents.filter { $0.recordName != recordName }
    objectWillChange.send()
  }

  func garbageCollectStaleUnblockEvents() {
    let stale = staleUnblockEventRecordNames()
    guard !stale.isEmpty else { return }
    for name in stale {
      removeUnblockEvent(recordName: name)
      if profileSyncManager.isEnabled {
        do {
          try profileSyncManager.enqueueEmergencyUnblockEventDelete(name)
        } catch {
          Log.warning(
            "enqueueEmergencyUnblockEventDelete skipped: \(error.localizedDescription)",
            category: .sync)
        }
      }
    }
  }

  /// #221: record a consumed unblock as an immutable event and push it through the funnel.
  /// Extracted so the record+enqueue behavior is unit-testable without a live session.
  @discardableResult
  func recordAndEnqueueUnblock(now: Date = Date()) -> SyncedEmergencyUnblockEvent {
    let event = consumeUnblockEvent(now: now)
    if profileSyncManager.isEnabled {
      do {
        try profileSyncManager.enqueueEmergencyUnblockEvent(event)
      } catch {
        Log.warning(
          "enqueueEmergencyUnblockEvent skipped: \(error.localizedDescription)", category: .sync)
      }
    }
    return event
  }

  /// Adopt a remote epoch by max with no version gate. The merge is commutative, idempotent, and
  /// order-independent, so drain/fetch ordering cannot lower or clobber the reset boundary.
  func adoptRemoteEpoch(_ epoch: Int) {
    let merged = max(currentResetEpoch, epoch)
    guard merged != currentResetEpoch else { return }
    currentResetEpoch = merged
    objectWillChange.send()
  }

  func currentEpochRecord() -> SyncedEmergencyEpoch {
    SyncedEmergencyEpoch(epoch: currentResetEpoch)
  }

  func clearLedgerForGenerationAdoption() {
    currentResetEpoch = 0
    defaults.removeObject(forKey: LedgerKey.events)
    objectWillChange.send()
  }

  func resetAllStateForAccountSwitch() {
    CloudKitManager.shared.dismissFamilyRevocationMessage()
    emergencyUnblocksResetPeriodInDays = 28
    lastEmergencyUnblocksResetDateTimestamp = 0
    emergencySettingsLockedStorage = false
    emergencySettingsVersion = 0
    defaults.set(28, forKey: DefaultsKey.resetPeriodInDays)
    defaults.set(0, forKey: DefaultsKey.lastResetDate)
    defaults.set(false, forKey: DefaultsKey.settingsLocked)
    defaults.set(0, forKey: DefaultsKey.settingsVersion)
    defaults.set(0, forKey: LedgerKey.resetEpoch)
    defaults.removeObject(forKey: LedgerKey.events)
    objectWillChange.send()
  }

  #if DEBUG
    func seedForTesting(epoch: Int) {
      currentResetEpoch = epoch
      unblockEvents = []
      objectWillChange.send()
    }

    func advanceResetEpochForTesting() {
      currentResetEpoch += 1
      objectWillChange.send()
    }
  #endif

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
    currentResetEpoch += 1
    lastEmergencyUnblocksResetDateTimestamp = Date().timeIntervalSinceReferenceDate
    pushEmergencyEpochToCloudKit()
    pushEmergencySettingsToCloudKit()
    garbageCollectStaleUnblockEvents()
    objectWillChange.send()
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
      currentResetEpoch += 1
      lastEmergencyUnblocksResetDateTimestamp = Date().timeIntervalSinceReferenceDate
      pushEmergencyEpochToCloudKit()
      pushEmergencySettingsToCloudKit()
      garbageCollectStaleUnblockEvents()
      objectWillChange.send()
    }
  }

  // MARK: - Emergency Unblock

  /// Perform an emergency unblock if allowed. Checks remaining count and geofence rules.
  /// Throws EmergencyUnblockError on failure. Calls `onUnblock` closure on success to delegate
  /// the actual session stop to StrategyManager.
  func emergencyUnblock(
    context: ModelContext,
    activeSession: BlockedProfileSession?,
    onUnblock: @escaping (ModelContext, BlockedProfileSession) -> Void,
    now: Date = Date()
  ) async throws(EmergencyUnblockError) {
    guard getRemainingEmergencyUnblocks() > 0 else {
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

    performEmergencyUnblock(context: context, session: activeSession, onUnblock: onUnblock, now: now)
  }

  /// Actually perform the emergency unblock (called after all checks pass)
  private func performEmergencyUnblock(
    context: ModelContext,
    session: BlockedProfileSession,
    onUnblock: @escaping (ModelContext, BlockedProfileSession) -> Void,
    now: Date = Date()
  ) {
    onUnblock(context, session)

    recordAndEnqueueUnblock(now: now)

    // Refresh widgets when emergency unblock ends session
    WidgetCenter.shared.reloadTimelines(ofKind: "ProfileControlWidget")
  }

  // MARK: - CloudKit Sync

  /// Apply emergency settings received from CloudKit sync
  func applyRemoteEmergencySettings(_ remote: SyncedEmergencySettings) {
    emergencyUnblocksResetPeriodInDays = remote.resetPeriodInDays
    lastEmergencyUnblocksResetDateTimestamp = remote.lastResetDate.timeIntervalSinceReferenceDate
    emergencySettingsLockedStorage = remote.settingsLocked
    emergencySettingsVersion = remote.version
    objectWillChange.send()
  }

  /// Snapshot of the current emergency settings for CKRecord materialization (RecordProvider).
  /// Reads the current version verbatim — never bumps (I2: version bumps only in MutationFunnel).
  func currentEmergencySettings(deviceId: String, now: Date = Date()) -> SyncedEmergencySettings {
    SyncedEmergencySettings(
      unblocksRemaining: getRemainingEmergencyUnblocks(),
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
    do {
      try profileSyncManager.enqueueEmergencySettingsSave()
    } catch {
      Log.warning("enqueueEmergencySettingsSave skipped: \(error.localizedDescription)", category: .sync)
    }
  }

  private func pushEmergencyEpochToCloudKit() {
    guard profileSyncManager.isEnabled else { return }

    do {
      try profileSyncManager.enqueueEmergencyEpochSave()
    } catch {
      Log.warning("enqueueEmergencyEpochSave skipped: \(error.localizedDescription)", category: .sync)
    }
  }
}
