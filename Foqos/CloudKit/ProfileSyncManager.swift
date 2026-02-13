import CloudKit
import Combine
import Foundation
import SwiftData

/// Manages same-user multi-device profile sync via iCloud private database.
/// Handles profile, session, and location synchronization across user's devices.
@MainActor
class ProfileSyncManager: ObservableObject {
  static let shared = ProfileSyncManager()

  // MARK: - CloudKit Configuration

  private lazy var container: CKContainer = {
    CKContainer(identifier: CloudKitConstants.containerIdentifier)
  }()

  private var privateDatabase: CKDatabase {
    container.privateCloudDatabase
  }

  private var syncZoneID: CKRecordZone.ID {
    CKRecordZone.ID(zoneName: CloudKitConstants.syncZoneName, ownerName: CKCurrentUserDefaultName)
  }

  // MARK: - Published State

  @Published var isEnabled: Bool = false
  @Published var isSyncing: Bool = false
  @Published var syncStatus: SyncStatus = .disabled
  @Published var connectedDeviceCount: Int = 0
  @Published var lastSyncDate: Date?
  @Published var error: SyncError?
  /// Set to true when legacy records were cleaned up and user should be notified
  @Published var shouldShowSyncUpgradeNotice = false

  // MARK: - Private State

  private var syncZoneVerified = false
  private var subscriptionsCreated = false
  private var cancellables = Set<AnyCancellable>()

  // Device identifier for this device
  var deviceId: String {
    SharedData.deviceSyncId.uuidString
  }

  private func legacyCleanupKey(for userRecordName: String) -> String {
    "family_foqos_legacy_session_cleanup_complete_" + userRecordName
  }

  private func isLegacyCleanupComplete(for userRecordName: String) -> Bool {
    UserDefaults.standard.bool(forKey: legacyCleanupKey(for: userRecordName))
  }

  private func setLegacyCleanupComplete(for userRecordName: String) {
    UserDefaults.standard.set(true, forKey: legacyCleanupKey(for: userRecordName))
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
      Log.info("Sync is disabled", category: .sync)
      return
    }

    do {
      // Check iCloud account status
      let status = try await container.accountStatus()
      guard status == .available else {
        self.error = .notSignedIn
        self.syncStatus = .error("Not signed in to iCloud")
        return
      }

      // Create sync zone if needed
      try await createSyncZoneIfNeeded()

      // Set up subscriptions for remote changes
      try await setupSubscriptions()

      // Clean up legacy session records if present
      let foundLegacyRecords = await cleanupLegacySessionsIfNeeded()
      if foundLegacyRecords {
        self.shouldShowSyncUpgradeNotice = true
      }

      // Perform initial sync
      await performFullSync()

      Log.info("Setup complete", category: .sync)
    } catch {
      Log.info("Setup failed - \(error)", category: .sync)
      self.error = .zoneCreationFailed(error)
      self.syncStatus = .error("Setup failed")
    }
  }

  /// Create the sync zone if it doesn't exist
  private func createSyncZoneIfNeeded() async throws {
    guard !syncZoneVerified else { return }

    let zone = CKRecordZone(zoneID: syncZoneID)

    do {
      _ = try await privateDatabase.save(zone)
      syncZoneVerified = true
      Log.info("Created sync zone: \(CloudKitConstants.syncZoneName)", category: .sync)
    } catch _ as CKError {
      // Check if zone already exists
      do {
        _ = try await privateDatabase.recordZone(for: syncZoneID)
        syncZoneVerified = true
        Log.info("Sync zone already exists", category: .sync)
      } catch {
        throw SyncError.zoneCreationFailed(error)
      }
    }
  }

  /// Set up CloudKit subscriptions for remote change notifications
  private func setupSubscriptions() async throws {
    guard !subscriptionsCreated else { return }

    // Create zone-scoped subscription for changes in our sync zone only
    let subscriptionID = "device-sync-zone-changes"
    let subscription = CKRecordZoneSubscription(
      zoneID: syncZoneID,
      subscriptionID: subscriptionID
    )

    let notificationInfo = CKSubscription.NotificationInfo()
    notificationInfo.shouldSendContentAvailable = true
    subscription.notificationInfo = notificationInfo

    do {
      _ = try await privateDatabase.save(subscription)
      subscriptionsCreated = true
      Log.info("Created zone subscription for sync changes", category: .sync)
    } catch let error as CKError {
      if error.code == .serverRejectedRequest {
        // Subscription might already exist
        subscriptionsCreated = true
        Log.info("Zone subscription already exists", category: .sync)
      } else {
        throw SyncError.subscriptionFailed(error)
      }
    }
  }

  // MARK: - Paginated Fetch Helper

  /// Fetch all records matching a query with cursor-based pagination.
  /// Returns raw results so callers can map/filter as needed.
  private func fetchAllRecords(
    matching query: CKQuery
  ) async throws -> [(CKRecord.ID, Result<CKRecord, any Error>)] {
    var allResults: [(CKRecord.ID, Result<CKRecord, any Error>)] = []

    let (initialResults, initialCursor) = try await privateDatabase.records(
      matching: query,
      inZoneWith: syncZoneID
    )
    allResults.append(contentsOf: initialResults)
    var cursor = initialCursor

    while let currentCursor = cursor {
      let (moreResults, nextCursor) = try await privateDatabase.records(
        continuingMatchFrom: currentCursor
      )
      allResults.append(contentsOf: moreResults)
      cursor = nextCursor
    }

    return allResults
  }

  // MARK: - Legacy Cleanup

  /// Check for and delete legacy SyncedSession records.
  /// Returns true if legacy records were found and deleted (should show notice).
  private func cleanupLegacySessionsIfNeeded() async -> Bool {
    // Get user record name to track cleanup per account
    guard let userRecordID = try? await container.userRecordID() else {
      return false
    }
    let userRecordName = userRecordID.recordName

    // Skip if already done for this account
    guard !isLegacyCleanupComplete(for: userRecordName) else { return false }

    let query = CKQuery(
      recordType: LegacySyncedSession.recordType,
      predicate: NSPredicate(value: true)
    )

    do {
      let allResults = try await fetchAllRecords(matching: query)
      let recordIDsToDelete = allResults.map { $0.0 }

      if recordIDsToDelete.isEmpty {
        // No legacy records - mark complete, no notice needed
        setLegacyCleanupComplete(for: userRecordName)
        Log.info("No legacy session records found", category: .sync)
        return false
      }

      // Delete all legacy records, tracking failures
      Log.info("Found \(recordIDsToDelete.count) legacy session records, deleting", category: .sync)

      var allDeletesSucceeded = true
      for recordID in recordIDsToDelete {
        do {
          try await privateDatabase.deleteRecord(withID: recordID)
        } catch {
          Log.info("Failed to delete legacy record \(recordID) - \(error)", category: .sync)
          allDeletesSucceeded = false
        }
      }

      // Only mark complete if all deletions succeeded
      if allDeletesSucceeded {
        setLegacyCleanupComplete(for: userRecordName)
        Log.info("Legacy session cleanup complete", category: .sync)
      } else {
        Log.info("Legacy session cleanup incomplete - some deletions failed, will retry next sync", category: .sync)
      }

      return true  // Should show notice (records were found)

    } catch let error as CKError {
      if error.code == .unknownItem || error.code == .zoneNotFound {
        // No records exist
        setLegacyCleanupComplete(for: userRecordName)
        return false
      }
      Log.info("Error checking for legacy sessions - \(error)", category: .sync)
      return false
    } catch {
      Log.info("Error checking for legacy sessions - \(error)", category: .sync)
      return false
    }
  }

  // MARK: - Full Sync

  /// Perform a full sync of all profiles, sessions, and locations
  func performFullSync() async {
    guard isEnabled else { return }

    self.isSyncing = true
    self.syncStatus = .syncing

    do {
      // Check for reset requests first (from other devices)
      try await pullResetRequests()

      // Pull remote changes
      try await pullProfiles()
      try await pullProfileSessionRecords()  // CAS-based session sync
      try await pullLocations()

      // Request push of local data (SyncCoordinator will handle this)
      NotificationCenter.default.post(name: .localDataPushRequested, object: nil)

      self.isSyncing = false
      self.syncStatus = .idle
      self.lastSyncDate = Date()
      self.error = nil

      Log.info("Full sync complete", category: .sync)
    } catch {
      Log.info("Full sync failed - \(error)", category: .sync)
      self.isSyncing = false
      self.syncStatus = .error("Sync failed")
      self.error = .fetchFailed(error)
    }
  }

  // MARK: - Reset Request Handling

  /// Pull and process reset requests from other devices
  private func pullResetRequests() async throws {
    let query = CKQuery(
      recordType: SyncResetRequest.recordType,
      predicate: NSPredicate(value: true)
    )

    do {
      let allResults = try await fetchAllRecords(matching: query)

      for (recordID, result) in allResults {
        if case .success(let record) = result,
          let resetRequest = SyncResetRequest(from: record)
        {
          // Skip requests from this device
          if resetRequest.originDeviceId == deviceId {
            continue
          }

          Log.info(
            "Processing reset request from device \(resetRequest.originDeviceId)",
            category: .sync)

          // Notify coordinator to handle the reset
          NotificationCenter.default.post(
            name: .syncResetRequested,
            object: nil,
            userInfo: ["clearAppSelections": resetRequest.clearRemoteAppSelections]
          )

          // Delete the processed reset request
          _ = try? await privateDatabase.deleteRecord(withID: recordID)
        }
      }
    } catch let error as CKError {
      if error.code == .zoneNotFound || error.code == .unknownItem {
        Log.info("No reset requests found", category: .sync)
        return
      }
      throw SyncError.fetchFailed(error)
    }
  }

  // MARK: - Profile Sync

  /// Push a profile to CloudKit
  func pushProfile(_ profile: BlockedProfiles) async throws {
    guard isEnabled else { throw SyncError.syncDisabled }

    let syncedProfile = SyncedProfile(from: profile, originDeviceId: deviceId)
    try await pushSyncedProfile(syncedProfile)
  }

  /// Push a SyncedProfile to CloudKit (handles create and update)
  func pushSyncedProfile(_ syncedProfile: SyncedProfile) async throws {
    guard isEnabled else { throw SyncError.syncDisabled }

    let recordID = CKRecord.ID(recordName: syncedProfile.profileId.uuidString, zoneID: syncZoneID)

    do {
      // Try to fetch existing record first
      let existingRecord = try? await privateDatabase.record(for: recordID)

      let record: CKRecord
      if let existing = existingRecord {
        // Update existing record
        record = existing
        syncedProfile.updateCKRecord(record)
      } else {
        // Create new record
        record = syncedProfile.toCKRecord(in: syncZoneID)
      }

      _ = try await privateDatabase.save(record)
      Log.info("Pushed profile '\(syncedProfile.name)' to CloudKit", category: .sync)
    } catch {
      Log.info("Failed to push profile - \(error)", category: .sync)
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
      let allResults = try await fetchAllRecords(matching: query)

      // Extract ALL remote record IDs before filtering decode failures.
      // This prevents false deletions when a record fails to decode —
      // without the full ID set, reconciliation would incorrectly delete
      // the local copy of any record that failed to decode.
      var allRemoteProfileIds = Set<UUID>()
      for (recordID, _) in allResults {
        if let uuid = UUID(uuidString: recordID.recordName) {
          allRemoteProfileIds.insert(uuid)
        }
      }

      var decodeFailureCount = 0
      let syncedProfiles = allResults.compactMap { (recordID, result) -> SyncedProfile? in
        switch result {
        case .success(let record):
          return SyncedProfile(from: record)
        case .failure(let error):
          decodeFailureCount += 1
          Log.warning(
            "Failed to decode profile record '\(recordID.recordName)': \(error.localizedDescription)",
            category: .sync
          )
          return nil
        }
      }

      if decodeFailureCount > 0 {
        Log.warning(
          "Pulled \(syncedProfiles.count) profiles from CloudKit (\(decodeFailureCount) records failed to decode)",
          category: .sync
        )
      } else {
        Log.info("Pulled \(syncedProfiles.count) profiles from CloudKit", category: .sync)
      }

      // Notify about received profiles, including full remote ID set
      // so deletion reconciliation doesn't treat decode failures as deletions
      NotificationCenter.default.post(
        name: .syncedProfilesReceived,
        object: nil,
        userInfo: [
          "profiles": syncedProfiles,
          "remoteProfileIds": allRemoteProfileIds,
        ]
      )
    } catch let error as CKError {
      if error.code == .zoneNotFound || error.code == .unknownItem {
        Log.info("No profiles found in CloudKit", category: .sync)
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
      Log.info("Deleted profile \(profileId) from CloudKit", category: .sync)
    } catch {
      Log.info("Failed to delete profile - \(error)", category: .sync)
      throw SyncError.deleteFailed(error)
    }
  }

  // MARK: - Session Sync

  /// Pull session records using the new ProfileSessionRecord format (CAS-based)
  func pullProfileSessionRecords() async throws {
    guard isEnabled else { throw SyncError.syncDisabled }

    // Query all ProfileSession records with pagination
    let query = CKQuery(
      recordType: ProfileSessionRecord.recordType,
      predicate: NSPredicate(value: true)
    )

    do {
      let allResults = try await fetchAllRecords(matching: query)
      var decodeFailureCount = 0
      let sessions = allResults.compactMap { (recordID, result) -> ProfileSessionRecord? in
        switch result {
        case .success(let record):
          return ProfileSessionRecord(from: record)
        case .failure(let error):
          decodeFailureCount += 1
          Log.warning(
            "Failed to decode session record '\(recordID.recordName)': \(error.localizedDescription)",
            category: .sync
          )
          return nil
        }
      }

      if decodeFailureCount > 0 {
        Log.warning(
          "Pulled \(sessions.count) session records from CloudKit (\(decodeFailureCount) records failed to decode)",
          category: .sync
        )
      } else {
        Log.info("Pulled \(sessions.count) session records from CloudKit", category: .sync)
      }

      // Notify coordinator about sessions
      NotificationCenter.default.post(
        name: .profileSessionRecordsReceived,
        object: nil,
        userInfo: [ProfileSessionRecord.sessionsUserInfoKey: sessions]
      )
    } catch let error as CKError {
      if error.code == .zoneNotFound || error.code == .unknownItem {
        Log.info("No session records found in CloudKit", category: .sync)
        return
      }
      throw SyncError.fetchFailed(error)
    }
  }

  // MARK: - Location Sync

  /// Push a location to CloudKit
  func pushLocation(_ location: SavedLocation) async throws {
    guard isEnabled else { throw SyncError.syncDisabled }

    let syncedLocation = SyncedLocation(from: location)
    try await pushSyncedLocation(syncedLocation)
  }

  /// Push a SyncedLocation to CloudKit (handles create and update)
  func pushSyncedLocation(_ syncedLocation: SyncedLocation) async throws {
    guard isEnabled else { throw SyncError.syncDisabled }

    let recordID = CKRecord.ID(recordName: syncedLocation.locationId.uuidString, zoneID: syncZoneID)

    do {
      // Try to fetch existing record first
      let existingRecord = try? await privateDatabase.record(for: recordID)

      let record: CKRecord
      if let existing = existingRecord {
        // Update existing record
        record = existing
        syncedLocation.updateCKRecord(record)
      } else {
        // Create new record
        record = syncedLocation.toCKRecord(in: syncZoneID)
      }

      _ = try await privateDatabase.save(record)
      Log.info("Pushed location '\(syncedLocation.name)' to CloudKit", category: .sync)
    } catch {
      Log.info("Failed to push location - \(error)", category: .sync)
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
      let allResults = try await fetchAllRecords(matching: query)

      // Extract ALL remote record IDs before filtering decode failures.
      // This prevents false deletions when a record fails to decode —
      // without the full ID set, reconciliation would incorrectly delete
      // the local copy of any record that failed to decode.
      var allRemoteLocationIds = Set<UUID>()
      for (recordID, _) in allResults {
        if let uuid = UUID(uuidString: recordID.recordName) {
          allRemoteLocationIds.insert(uuid)
        }
      }

      var decodeFailureCount = 0
      let syncedLocations = allResults.compactMap { (recordID, result) -> SyncedLocation? in
        switch result {
        case .success(let record):
          return SyncedLocation(from: record)
        case .failure(let error):
          decodeFailureCount += 1
          Log.warning(
            "Failed to decode location record '\(recordID.recordName)': \(error.localizedDescription)",
            category: .sync
          )
          return nil
        }
      }

      if decodeFailureCount > 0 {
        Log.warning(
          "Pulled \(syncedLocations.count) locations from CloudKit (\(decodeFailureCount) records failed to decode)",
          category: .sync
        )
      } else {
        Log.info("Pulled \(syncedLocations.count) locations from CloudKit", category: .sync)
      }

      // Notify about received locations, including full remote ID set
      // so deletion reconciliation doesn't treat decode failures as deletions
      NotificationCenter.default.post(
        name: .syncedLocationsReceived,
        object: nil,
        userInfo: [
          "locations": syncedLocations,
          "remoteLocationIds": allRemoteLocationIds,
        ]
      )
    } catch let error as CKError {
      if error.code == .zoneNotFound || error.code == .unknownItem {
        Log.info("No locations found in CloudKit", category: .sync)
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
      Log.info("Deleted location from CloudKit", category: .sync)
    } catch {
      Log.info("Failed to delete location - \(error)", category: .sync)
      throw SyncError.deleteFailed(error)
    }
  }

  // MARK: - Reset Sync

  /// Reset syncing - delete all synced data and re-push from this device
  func resetSync(clearRemoteAppSelections: Bool) async throws {
    guard isEnabled else { throw SyncError.syncDisabled }

    self.isSyncing = true
    self.syncStatus = .syncing

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

      self.isSyncing = false
      self.syncStatus = .idle
      self.lastSyncDate = Date()

      Log.info("Reset sync complete", category: .sync)

      // Notify to re-push local profiles
      NotificationCenter.default.post(
        name: .syncResetRequested,
        object: nil,
        userInfo: ["clearAppSelections": clearRemoteAppSelections]
      )
    } catch {
      Log.info("Reset sync failed - \(error)", category: .sync)
      self.isSyncing = false
      self.syncStatus = .error("Reset failed")
      throw error
    }
  }

  /// Delete all synced data from CloudKit
  private func deleteAllSyncedData() async throws {
    let recordTypes = [
      SyncedProfile.recordType,
      LegacySyncedSession.recordType,
      ProfileSessionRecord.recordType,
      SyncedLocation.recordType,
      SyncResetRequest.recordType,
    ]

    for recordType in recordTypes {
      let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
      let results = try await fetchAllRecords(matching: query)
      let recordIDs = results.map { $0.0 }
      guard !recordIDs.isEmpty else { continue }
      _ = try await privateDatabase.modifyRecords(saving: [], deleting: recordIDs)
    }

    Log.info("Deleted all synced data from CloudKit", category: .sync)
  }

  // MARK: - Remote Change Handling

  /// Minimum interval between background syncs to prevent memory accumulation
  private static let backgroundSyncThrottleInterval: TimeInterval = 300  // 5 minutes

  /// Handle remote change notification from CloudKit
  func handleRemoteNotification() async {
    guard isEnabled else { return }

    // Throttle background syncs to prevent memory accumulation from rapid notifications
    if let lastSync = lastSyncDate,
      Date().timeIntervalSince(lastSync) < Self.backgroundSyncThrottleInterval
    {
      Log.info(
        "Skipping background sync, last sync was \(Int(Date().timeIntervalSince(lastSync)))s ago",
        category: .sync)
      return
    }

    Log.info("Handling remote notification", category: .sync)
    await performFullSync()
  }
}

// MARK: - Notification Names

extension Notification.Name {
  static let syncedProfilesReceived = Notification.Name("syncedProfilesReceived")
  static let syncedLocationsReceived = Notification.Name("syncedLocationsReceived")
  static let syncResetRequested = Notification.Name("syncResetRequested")
  static let localDataPushRequested = Notification.Name("localDataPushRequested")
  static let profileSessionRecordsReceived = Notification.Name("profileSessionRecordsReceived")
}
