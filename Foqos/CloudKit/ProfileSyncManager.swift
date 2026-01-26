import CloudKit
import Combine
import Foundation
import SwiftData

/// Manages same-user multi-device profile sync via iCloud private database.
/// Handles profile, session, and location synchronization across user's devices.
class ProfileSyncManager: ObservableObject {
  static let shared = ProfileSyncManager()

  // MARK: - CloudKit Configuration

  private let containerIdentifier = "iCloud.com.cynexia.family-foqos"
  private let syncZoneName = "DeviceSync"

  private lazy var container: CKContainer = {
    CKContainer(identifier: containerIdentifier)
  }()

  private var privateDatabase: CKDatabase {
    container.privateCloudDatabase
  }

  private var syncZoneID: CKRecordZone.ID {
    CKRecordZone.ID(zoneName: syncZoneName, ownerName: CKCurrentUserDefaultName)
  }

  // MARK: - Published State

  @Published var isEnabled: Bool = false
  @Published var isSyncing: Bool = false
  @Published var syncStatus: SyncStatus = .disabled
  @Published var connectedDeviceCount: Int = 0
  @Published var lastSyncDate: Date?
  @Published var error: SyncError?

  // MARK: - Private State

  private var syncZoneVerified = false
  private var subscriptionsCreated = false
  private var cancellables = Set<AnyCancellable>()

  // Device identifier for this device
  var deviceId: String {
    SharedData.deviceSyncId.uuidString
  }

  // MARK: - Initialization

  private init() {
    // Load enabled state from SharedData
    isEnabled = SharedData.deviceSyncEnabled
    syncStatus = isEnabled ? .idle : .disabled

    // Observe changes to sync enabled setting
    $isEnabled
      .dropFirst()
      .sink { [weak self] enabled in
        SharedData.deviceSyncEnabled = enabled
        self?.syncStatus = enabled ? .idle : .disabled
        if enabled {
          Task {
            await self?.setupSync()
          }
        }
      }
      .store(in: &cancellables)
  }

  // MARK: - Sync Status

  enum SyncStatus: Equatable {
    case disabled
    case idle
    case syncing
    case error(String)

    var displayText: String {
      switch self {
      case .disabled:
        return "Disabled"
      case .idle:
        return "Synced"
      case .syncing:
        return "Syncing..."
      case .error(let message):
        return "Error: \(message)"
      }
    }
  }

  // MARK: - Sync Errors

  enum SyncError: LocalizedError {
    case notSignedIn
    case zoneCreationFailed(Error)
    case subscriptionFailed(Error)
    case fetchFailed(Error)
    case saveFailed(Error)
    case deleteFailed(Error)
    case profileNotFound
    case syncDisabled

    var errorDescription: String? {
      switch self {
      case .notSignedIn:
        return "Please sign in to iCloud to sync profiles across devices."
      case .zoneCreationFailed(let error):
        return "Failed to set up sync: \(error.localizedDescription)"
      case .subscriptionFailed(let error):
        return "Failed to set up notifications: \(error.localizedDescription)"
      case .fetchFailed(let error):
        return "Failed to fetch synced data: \(error.localizedDescription)"
      case .saveFailed(let error):
        return "Failed to save synced data: \(error.localizedDescription)"
      case .deleteFailed(let error):
        return "Failed to delete synced data: \(error.localizedDescription)"
      case .profileNotFound:
        return "Profile not found."
      case .syncDisabled:
        return "Profile sync is disabled."
      }
    }
  }

  // MARK: - Setup

  /// Initialize sync infrastructure (zone and subscriptions)
  func setupSync() async {
    guard isEnabled else {
      print("ProfileSyncManager: Sync is disabled")
      return
    }

    do {
      // Check iCloud account status
      let status = try await container.accountStatus()
      guard status == .available else {
        await MainActor.run {
          self.error = .notSignedIn
          self.syncStatus = .error("Not signed in to iCloud")
        }
        return
      }

      // Create sync zone if needed
      try await createSyncZoneIfNeeded()

      // Set up subscriptions for remote changes
      try await setupSubscriptions()

      // Perform initial sync
      await performFullSync()

      print("ProfileSyncManager: Setup complete")
    } catch {
      print("ProfileSyncManager: Setup failed - \(error)")
      await MainActor.run {
        self.error = .zoneCreationFailed(error)
        self.syncStatus = .error("Setup failed")
      }
    }
  }

  /// Create the sync zone if it doesn't exist
  private func createSyncZoneIfNeeded() async throws {
    guard !syncZoneVerified else { return }

    let zone = CKRecordZone(zoneID: syncZoneID)

    do {
      _ = try await privateDatabase.save(zone)
      syncZoneVerified = true
      print("ProfileSyncManager: Created sync zone: \(syncZoneName)")
    } catch _ as CKError {
      // Check if zone already exists
      do {
        _ = try await privateDatabase.recordZone(for: syncZoneID)
        syncZoneVerified = true
        print("ProfileSyncManager: Sync zone already exists")
      } catch {
        throw SyncError.zoneCreationFailed(error)
      }
    }
  }

  /// Set up CloudKit subscriptions for remote change notifications
  private func setupSubscriptions() async throws {
    guard !subscriptionsCreated else { return }

    // Create subscription for all record types in the sync zone
    let subscriptionID = "device-sync-changes"
    let subscription = CKDatabaseSubscription(subscriptionID: subscriptionID)

    let notificationInfo = CKSubscription.NotificationInfo()
    notificationInfo.shouldSendContentAvailable = true
    subscription.notificationInfo = notificationInfo

    do {
      _ = try await privateDatabase.save(subscription)
      subscriptionsCreated = true
      print("ProfileSyncManager: Created subscription for sync changes")
    } catch let error as CKError {
      if error.code == .serverRejectedRequest {
        // Subscription might already exist
        subscriptionsCreated = true
        print("ProfileSyncManager: Subscription already exists")
      } else {
        throw SyncError.subscriptionFailed(error)
      }
    }
  }

  // MARK: - Full Sync

  /// Perform a full sync of all profiles, sessions, and locations
  func performFullSync() async {
    guard isEnabled else { return }

    await MainActor.run {
      self.isSyncing = true
      self.syncStatus = .syncing
    }

    do {
      // Pull remote changes first
      try await pullProfiles()
      try await pullSessions()
      try await pullLocations()

      await MainActor.run {
        self.isSyncing = false
        self.syncStatus = .idle
        self.lastSyncDate = Date()
        self.error = nil
      }

      print("ProfileSyncManager: Full sync complete")
    } catch {
      print("ProfileSyncManager: Full sync failed - \(error)")
      await MainActor.run {
        self.isSyncing = false
        self.syncStatus = .error("Sync failed")
        self.error = .fetchFailed(error)
      }
    }
  }

  // MARK: - Profile Sync

  /// Push a profile to CloudKit
  func pushProfile(_ profile: BlockedProfiles) async throws {
    guard isEnabled else { throw SyncError.syncDisabled }
    guard profile.isSynced else { return }

    let syncedProfile = SyncedProfile(from: profile, originDeviceId: deviceId)
    let record = syncedProfile.toCKRecord(in: syncZoneID)

    do {
      _ = try await privateDatabase.save(record)
      print("ProfileSyncManager: Pushed profile '\(profile.name)' to CloudKit")
    } catch {
      print("ProfileSyncManager: Failed to push profile - \(error)")
      throw SyncError.saveFailed(error)
    }
  }

  /// Pull all profiles from CloudKit
  func pullProfiles() async throws {
    guard isEnabled else { throw SyncError.syncDisabled }

    let query = CKQuery(
      recordType: SyncedProfile.recordType,
      predicate: NSPredicate(value: true)
    )

    do {
      let (results, _) = try await privateDatabase.records(
        matching: query,
        inZoneWith: syncZoneID
      )

      var syncedProfiles: [SyncedProfile] = []
      for (_, result) in results {
        if case .success(let record) = result,
          let syncedProfile = SyncedProfile(from: record)
        {
          syncedProfiles.append(syncedProfile)
        }
      }

      print("ProfileSyncManager: Pulled \(syncedProfiles.count) profiles from CloudKit")

      // Process pulled profiles on main actor with context
      let profiles = syncedProfiles
      await MainActor.run {
        NotificationCenter.default.post(
          name: .syncedProfilesReceived,
          object: nil,
          userInfo: ["profiles": profiles]
        )
      }
    } catch let error as CKError {
      if error.code == .zoneNotFound || error.code == .unknownItem {
        print("ProfileSyncManager: No profiles found in CloudKit")
        return
      }
      throw SyncError.fetchFailed(error)
    }
  }

  /// Delete a profile from CloudKit
  func deleteProfile(_ profileId: UUID) async throws {
    guard isEnabled else { throw SyncError.syncDisabled }

    let recordID = CKRecord.ID(recordName: profileId.uuidString, zoneID: syncZoneID)

    do {
      try await privateDatabase.deleteRecord(withID: recordID)
      print("ProfileSyncManager: Deleted profile \(profileId) from CloudKit")
    } catch {
      print("ProfileSyncManager: Failed to delete profile - \(error)")
      throw SyncError.deleteFailed(error)
    }
  }

  // MARK: - Session Sync

  /// Push a session to CloudKit (for start/stop propagation)
  func pushSession(_ session: BlockedProfileSession) async throws {
    guard isEnabled else { throw SyncError.syncDisabled }
    guard session.blockedProfile.isSynced else { return }

    let syncedSession = SyncedSession(from: session, originDeviceId: deviceId)
    let record = syncedSession.toCKRecord(in: syncZoneID)

    do {
      _ = try await privateDatabase.save(record)
      print("ProfileSyncManager: Pushed session to CloudKit (active: \(syncedSession.isActive))")
    } catch {
      print("ProfileSyncManager: Failed to push session - \(error)")
      throw SyncError.saveFailed(error)
    }
  }

  /// Update session end time in CloudKit (for stop propagation)
  func pushSessionEnd(_ sessionId: String, endTime: Date) async throws {
    guard isEnabled else { throw SyncError.syncDisabled }

    let recordID = CKRecord.ID(recordName: sessionId, zoneID: syncZoneID)

    do {
      let record = try await privateDatabase.record(for: recordID)
      record[SyncedSession.FieldKey.endTime.rawValue] = endTime
      record[SyncedSession.FieldKey.lastModified.rawValue] = Date()
      _ = try await privateDatabase.save(record)
      print("ProfileSyncManager: Updated session end time in CloudKit")
    } catch {
      print("ProfileSyncManager: Failed to update session end time - \(error)")
      throw SyncError.saveFailed(error)
    }
  }

  /// Pull all active sessions from CloudKit
  func pullSessions() async throws {
    guard isEnabled else { throw SyncError.syncDisabled }

    // Only fetch active sessions (endTime is nil)
    let predicate = NSPredicate(format: "%K == nil", SyncedSession.FieldKey.endTime.rawValue)
    let query = CKQuery(
      recordType: SyncedSession.recordType,
      predicate: predicate
    )

    do {
      let (results, _) = try await privateDatabase.records(
        matching: query,
        inZoneWith: syncZoneID
      )

      var syncedSessions: [SyncedSession] = []
      for (_, result) in results {
        if case .success(let record) = result,
          let syncedSession = SyncedSession(from: record)
        {
          syncedSessions.append(syncedSession)
        }
      }

      print("ProfileSyncManager: Pulled \(syncedSessions.count) active sessions from CloudKit")

      // Notify about received sessions
      let sessions = syncedSessions
      await MainActor.run {
        NotificationCenter.default.post(
          name: .syncedSessionsReceived,
          object: nil,
          userInfo: ["sessions": sessions]
        )
      }
    } catch let error as CKError {
      if error.code == .zoneNotFound || error.code == .unknownItem {
        print("ProfileSyncManager: No sessions found in CloudKit")
        return
      }
      throw SyncError.fetchFailed(error)
    }
  }

  /// Delete a session from CloudKit
  func deleteSession(_ sessionId: String) async throws {
    guard isEnabled else { throw SyncError.syncDisabled }

    let recordID = CKRecord.ID(recordName: sessionId, zoneID: syncZoneID)

    do {
      try await privateDatabase.deleteRecord(withID: recordID)
      print("ProfileSyncManager: Deleted session from CloudKit")
    } catch {
      print("ProfileSyncManager: Failed to delete session - \(error)")
      throw SyncError.deleteFailed(error)
    }
  }

  // MARK: - Location Sync

  /// Push a location to CloudKit
  func pushLocation(_ location: SavedLocation) async throws {
    guard isEnabled else { throw SyncError.syncDisabled }

    let syncedLocation = SyncedLocation(from: location)
    let record = syncedLocation.toCKRecord(in: syncZoneID)

    do {
      _ = try await privateDatabase.save(record)
      print("ProfileSyncManager: Pushed location '\(location.name)' to CloudKit")
    } catch {
      print("ProfileSyncManager: Failed to push location - \(error)")
      throw SyncError.saveFailed(error)
    }
  }

  /// Pull all locations from CloudKit
  func pullLocations() async throws {
    guard isEnabled else { throw SyncError.syncDisabled }

    let query = CKQuery(
      recordType: SyncedLocation.recordType,
      predicate: NSPredicate(value: true)
    )

    do {
      let (results, _) = try await privateDatabase.records(
        matching: query,
        inZoneWith: syncZoneID
      )

      var syncedLocations: [SyncedLocation] = []
      for (_, result) in results {
        if case .success(let record) = result,
          let syncedLocation = SyncedLocation(from: record)
        {
          syncedLocations.append(syncedLocation)
        }
      }

      print("ProfileSyncManager: Pulled \(syncedLocations.count) locations from CloudKit")

      // Notify about received locations
      let locations = syncedLocations
      await MainActor.run {
        NotificationCenter.default.post(
          name: .syncedLocationsReceived,
          object: nil,
          userInfo: ["locations": locations]
        )
      }
    } catch let error as CKError {
      if error.code == .zoneNotFound || error.code == .unknownItem {
        print("ProfileSyncManager: No locations found in CloudKit")
        return
      }
      throw SyncError.fetchFailed(error)
    }
  }

  /// Delete a location from CloudKit
  func deleteLocation(_ locationId: UUID) async throws {
    guard isEnabled else { throw SyncError.syncDisabled }

    let recordID = CKRecord.ID(recordName: locationId.uuidString, zoneID: syncZoneID)

    do {
      try await privateDatabase.deleteRecord(withID: recordID)
      print("ProfileSyncManager: Deleted location from CloudKit")
    } catch {
      print("ProfileSyncManager: Failed to delete location - \(error)")
      throw SyncError.deleteFailed(error)
    }
  }

  // MARK: - Reset Sync

  /// Reset syncing - delete all synced data and re-push from this device
  func resetSync(clearRemoteAppSelections: Bool) async throws {
    guard isEnabled else { throw SyncError.syncDisabled }

    await MainActor.run {
      self.isSyncing = true
      self.syncStatus = .syncing
    }

    do {
      // Delete all records in the sync zone
      try await deleteAllSyncedData()

      // Create and push reset request for other devices
      let resetRequest = SyncResetRequest(
        clearRemoteAppSelections: clearRemoteAppSelections,
        originDeviceId: deviceId
      )
      let record = resetRequest.toCKRecord(in: syncZoneID)
      _ = try await privateDatabase.save(record)

      await MainActor.run {
        self.isSyncing = false
        self.syncStatus = .idle
        self.lastSyncDate = Date()
      }

      print("ProfileSyncManager: Reset sync complete")

      // Notify to re-push local profiles
      await MainActor.run {
        NotificationCenter.default.post(
          name: .syncResetRequested,
          object: nil,
          userInfo: ["clearAppSelections": clearRemoteAppSelections]
        )
      }
    } catch {
      print("ProfileSyncManager: Reset sync failed - \(error)")
      await MainActor.run {
        self.isSyncing = false
        self.syncStatus = .error("Reset failed")
      }
      throw error
    }
  }

  /// Delete all synced data from CloudKit
  private func deleteAllSyncedData() async throws {
    // Fetch and delete all profiles
    let profileQuery = CKQuery(
      recordType: SyncedProfile.recordType,
      predicate: NSPredicate(value: true)
    )
    let (profileResults, _) = try await privateDatabase.records(
      matching: profileQuery,
      inZoneWith: syncZoneID
    )
    for (recordID, _) in profileResults {
      try await privateDatabase.deleteRecord(withID: recordID)
    }

    // Fetch and delete all sessions
    let sessionQuery = CKQuery(
      recordType: SyncedSession.recordType,
      predicate: NSPredicate(value: true)
    )
    let (sessionResults, _) = try await privateDatabase.records(
      matching: sessionQuery,
      inZoneWith: syncZoneID
    )
    for (recordID, _) in sessionResults {
      try await privateDatabase.deleteRecord(withID: recordID)
    }

    // Fetch and delete all locations
    let locationQuery = CKQuery(
      recordType: SyncedLocation.recordType,
      predicate: NSPredicate(value: true)
    )
    let (locationResults, _) = try await privateDatabase.records(
      matching: locationQuery,
      inZoneWith: syncZoneID
    )
    for (recordID, _) in locationResults {
      try await privateDatabase.deleteRecord(withID: recordID)
    }

    // Fetch and delete reset requests
    let resetQuery = CKQuery(
      recordType: SyncResetRequest.recordType,
      predicate: NSPredicate(value: true)
    )
    let (resetResults, _) = try await privateDatabase.records(
      matching: resetQuery,
      inZoneWith: syncZoneID
    )
    for (recordID, _) in resetResults {
      try await privateDatabase.deleteRecord(withID: recordID)
    }

    print("ProfileSyncManager: Deleted all synced data from CloudKit")
  }

  // MARK: - Remote Change Handling

  /// Handle remote change notification from CloudKit
  func handleRemoteNotification() async {
    guard isEnabled else { return }

    print("ProfileSyncManager: Handling remote notification")
    await performFullSync()
  }
}

// MARK: - Notification Names

extension Notification.Name {
  static let syncedProfilesReceived = Notification.Name("syncedProfilesReceived")
  static let syncedSessionsReceived = Notification.Name("syncedSessionsReceived")
  static let syncedLocationsReceived = Notification.Name("syncedLocationsReceived")
  static let syncResetRequested = Notification.Name("syncResetRequested")
}
