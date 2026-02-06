import Combine
import Foundation
import SwiftData

/// Coordinates between ProfileSyncManager notifications and local SwiftData storage.
/// Handles incoming synced profiles, sessions, and locations from other devices.
class SyncCoordinator: ObservableObject {
  static let shared = SyncCoordinator()

  private var cancellables = Set<AnyCancellable>()
  private var modelContext: ModelContext?

  /// Tracks profile IDs that have active sessions started via remote trigger.
  /// Used to determine which sessions should be auto-stopped when remote ends.
  private var remoteTriggeredProfileIds: Set<UUID> = []

  private init() {
    setupNotificationObservers()
  }

  // MARK: - Setup

  /// Set the model context for database operations
  func setModelContext(_ context: ModelContext) {
    self.modelContext = context
  }

  private func setupNotificationObservers() {
    // Observe synced profiles
    NotificationCenter.default.publisher(for: .syncedProfilesReceived)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] notification in
        guard let profiles = notification.userInfo?["profiles"] as? [SyncedProfile] else { return }
        self?.handleSyncedProfiles(profiles)
      }
      .store(in: &cancellables)

    // Observe ProfileSessionRecord notifications (CAS-based session sync)
    NotificationCenter.default.publisher(for: .profileSessionRecordsReceived)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] notification in
        guard
          let sessions = notification.userInfo?[ProfileSessionRecord.sessionsUserInfoKey]
            as? [ProfileSessionRecord]
        else {
          return
        }
        MainActor.assumeIsolated {
          self?.handleProfileSessionRecords(sessions)
        }
      }
      .store(in: &cancellables)

    // Observe synced locations
    NotificationCenter.default.publisher(for: .syncedLocationsReceived)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] notification in
        guard let locations = notification.userInfo?["locations"] as? [SyncedLocation] else { return }
        self?.handleSyncedLocations(locations)
      }
      .store(in: &cancellables)

    // Observe sync reset requests
    NotificationCenter.default.publisher(for: .syncResetRequested)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] notification in
        guard
          let clearAppSelections = notification.userInfo?["clearAppSelections"] as? Bool
        else { return }
        self?.handleSyncReset(clearAppSelections: clearAppSelections)
      }
      .store(in: &cancellables)

    // Observe local data push requests (push local data to CloudKit)
    NotificationCenter.default.publisher(for: .localDataPushRequested)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        Task { @MainActor in
          self?.pushLocalData()
        }
      }
      .store(in: &cancellables)

  }

  // MARK: - Local Data Push

  /// Push all local profiles and locations to CloudKit (when global sync is enabled)
  @MainActor
  private func pushLocalData() {
    guard ProfileSyncManager.shared.isEnabled else {
      Log.info("Global sync disabled, skipping push", category: .sync)
      return
    }

    guard let context = modelContext else {
      Log.info("No model context available for local push", category: .sync)
      return
    }

    do {
      let profiles = try BlockedProfiles.fetchProfiles(in: context)
      let locations = try SavedLocation.fetchAll(in: context)

      Log.info("Found \(profiles.count) profiles to sync", category: .sync)

      // Create sync objects on main queue (accesses SwiftData properties)
      let deviceId = SharedData.deviceSyncId.uuidString
      // Skip V2+ profiles to avoid overwriting their CloudKit records with incomplete V1 data
      let syncedProfiles = profiles.filter { !$0.isNewerSchemaVersion }
        .map { SyncedProfile(from: $0, originDeviceId: deviceId) }
      let syncedLocations = locations.map { SyncedLocation(from: $0) }

      Log.info("Pushing \(syncedProfiles.count) profiles and \(syncedLocations.count) locations to CloudKit", category: .sync)

      Task.detached {
        // Push synced profiles
        for syncedProfile in syncedProfiles {
          try? await ProfileSyncManager.shared.pushSyncedProfile(syncedProfile)
        }

        // Push all locations
        for syncedLocation in syncedLocations {
          try? await ProfileSyncManager.shared.pushSyncedLocation(syncedLocation)
        }
      }
    } catch {
      Log.info("Error pushing local data - \(error)", category: .sync)
    }
  }

  // MARK: - Profile Handling

  private func handleSyncedProfiles(_ syncedProfiles: [SyncedProfile]) {
    guard let context = modelContext else {
      Log.info("No model context available", category: .sync)
      return
    }

    let deviceId = SharedData.deviceSyncId.uuidString

    // Collect remote profile IDs for deletion reconciliation
    let remoteProfileIds = Set(syncedProfiles.map { $0.profileId })

    for syncedProfile in syncedProfiles {
      // Skip profiles originating from this device
      if syncedProfile.originDeviceId == deviceId {
        continue
      }

      do {
        if let existingProfile = try BlockedProfiles.findProfile(
          byID: syncedProfile.profileId,
          in: context
        ) {
          // Update existing profile if remote version is newer
          if syncedProfile.version > existingProfile.syncVersion {
            updateLocalProfile(existingProfile, from: syncedProfile, in: context)
          }
        } else {
          // Create new profile from synced data
          createLocalProfile(from: syncedProfile, in: context)
        }
      } catch {
        Log.info("Error handling synced profile - \(error)", category: .sync)
      }
    }

    // Reconcile deletions: remove local profiles not in remote set
    // Only delete profiles that have been synced at least once (syncVersion > 0)
    // This avoids deleting locally-created profiles that haven't been pushed yet
    do {
      let localProfiles = try BlockedProfiles.fetchProfiles(in: context)
      for profile in localProfiles {
        // Only consider profiles that have been synced at least once
        guard profile.syncVersion > 0 else { continue }

        // If profile was synced but is no longer in remote, it was deleted remotely
        if !remoteProfileIds.contains(profile.id) {
          Log.info("Removing profile '\(profile.name)' deleted from remote", category: .sync)
          try BlockedProfiles.deleteProfile(profile, in: context)
        }
      }
    } catch {
      Log.info("Error reconciling profile deletions - \(error)", category: .sync)
    }

    try? context.save()
  }

  private func updateLocalProfile(
    _ profile: BlockedProfiles,
    from synced: SyncedProfile,
    in context: ModelContext
  ) {
    // Don't overwrite profiles with data from an older schema version
    if synced.profileSchemaVersion < profile.profileSchemaVersion {
      Log.info(
        "Skipping sync update for profile '\(profile.name)' from older schema version \(synced.profileSchemaVersion)",
        category: .sync
      )
      return
    }

    profile.name = synced.name
    profile.blockingStrategyId = synced.blockingStrategyId
    profile.strategyData = synced.strategyData
    profile.order = synced.order
    profile.enableLiveActivity = synced.enableLiveActivity
    profile.reminderTimeInSeconds = synced.reminderTimeInSeconds
    profile.customReminderMessage = synced.customReminderMessage
    profile.enableBreaks = synced.enableBreaks
    profile.breakTimeInMinutes = synced.breakTimeInMinutes
    profile.enableStrictMode = synced.enableStrictMode
    profile.enableAllowMode = synced.enableAllowMode
    profile.enableAllowModeDomains = synced.enableAllowModeDomains
    profile.enableSafariBlocking = synced.enableSafariBlocking
    profile.physicalUnblockNFCTagId = synced.physicalUnblockNFCTagId
    profile.physicalUnblockQRCodeId = synced.physicalUnblockQRCodeId
    profile.domains = synced.domains
    profile.schedule = synced.schedule
    profile.geofenceRule = synced.geofenceRule
    profile.disableBackgroundStops = synced.disableBackgroundStops
    profile.isManaged = synced.isManaged
    profile.managedByChildId = synced.managedByChildId
    profile.syncVersion = synced.version
    profile.profileSchemaVersion = max(profile.profileSchemaVersion, synced.profileSchemaVersion)
    profile.updatedAt = synced.updatedAt

    // Update snapshot for extensions
    BlockedProfiles.updateSnapshot(for: profile)

    Log.info("Updated profile '\(profile.name)' from remote", category: .sync)
  }

  private func createLocalProfile(from synced: SyncedProfile, in context: ModelContext) {
    let profile = BlockedProfiles(
      id: synced.profileId,
      name: synced.name,
      createdAt: synced.createdAt,
      updatedAt: synced.updatedAt,
      blockingStrategyId: synced.blockingStrategyId ?? NFCBlockingStrategy.id,
      strategyData: synced.strategyData,
      enableLiveActivity: synced.enableLiveActivity,
      reminderTimeInSeconds: synced.reminderTimeInSeconds,
      customReminderMessage: synced.customReminderMessage,
      enableBreaks: synced.enableBreaks,
      breakTimeInMinutes: synced.breakTimeInMinutes,
      enableStrictMode: synced.enableStrictMode,
      enableAllowMode: synced.enableAllowMode,
      enableAllowModeDomains: synced.enableAllowModeDomains,
      enableSafariBlocking: synced.enableSafariBlocking,
      order: synced.order,
      domains: synced.domains,
      physicalUnblockNFCTagId: synced.physicalUnblockNFCTagId,
      physicalUnblockQRCodeId: synced.physicalUnblockQRCodeId,
      schedule: synced.schedule,
      geofenceRule: synced.geofenceRule,
      disableBackgroundStops: synced.disableBackgroundStops,
      isManaged: synced.isManaged,
      managedByChildId: synced.managedByChildId,
      syncVersion: synced.version,
      needsAppSelection: true  // New profile from another device needs app selection
    )

    profile.profileSchemaVersion = synced.profileSchemaVersion

    context.insert(profile)
    BlockedProfiles.updateSnapshot(for: profile)

    Log.info("Created profile '\(profile.name)' from remote (needs app selection)", category: .sync)
  }

  // MARK: - Session Handling (CAS-based)

  /// Handle ProfileSessionRecord notifications from the sync system
  @MainActor
  private func handleProfileSessionRecords(_ sessions: [ProfileSessionRecord]) {
    guard let context = modelContext else {
      Log.info("No model context available", category: .sync)
      return
    }

    let deviceId = SharedData.deviceSyncId.uuidString

    for session in sessions {
      applySessionState(session, context: context, deviceId: deviceId)
    }
  }

  /// Sync session state for a specific profile using the new CAS-based system
  @MainActor
  func handleSessionSync(for profileId: UUID) async {
    guard let context = modelContext else {
      Log.info("No model context available", category: .sync)
      return
    }

    let deviceId = SharedData.deviceSyncId.uuidString

    // Fetch authoritative state from CloudKit
    let result = await SessionSyncService.shared.fetchSession(profileId: profileId)

    switch result {
    case .found(let session):
      applySessionState(session, context: context, deviceId: deviceId)

    case .notFound:
      // No session record - ensure local is stopped
      if let active = StrategyManager.shared.activeSession,
        active.blockedProfile.id == profileId
      {
        Log.info("No remote session, stopping local", category: .sync)
        StrategyManager.shared.stopRemoteSession(context: context, profileId: profileId)
      }

    case .error(let error):
      Log.info("Error fetching session - \(error)", category: .sync)
    }
  }

  @MainActor
  private func applySessionState(
    _ session: ProfileSessionRecord,
    context: ModelContext,
    deviceId: String
  ) {
    let profileId = session.profileId

    // Check if this came from us
    if session.lastModifiedBy == deviceId {
      Log.info("Ignoring our own update for \(profileId)", category: .sync)
      return
    }

    let localActive = StrategyManager.shared.activeSession?.blockedProfile.id == profileId

    if session.isActive && !localActive {
      // Remote is active, local is not - start locally
      Log.info("Remote session active, starting locally", category: .sync)

      if let startTime = session.startTime {
        StrategyManager.shared.startRemoteSession(
          context: context,
          profileId: profileId,
          sessionId: UUID(),  // Local tracking only
          startTime: startTime
        )
        remoteTriggeredProfileIds.insert(profileId)
      }

    } else if !session.isActive && localActive {
      // Remote is stopped, local is active - stop locally
      // In the single-record model, the CloudKit record is authoritative
      Log.info("Remote session stopped, stopping locally", category: .sync)
      StrategyManager.shared.stopRemoteSession(context: context, profileId: profileId)
      remoteTriggeredProfileIds.remove(profileId)
    }
  }

  /// Sync session state for all profiles that might be active
  func syncAllProfileSessions() async {
    guard let context = modelContext else { return }

    do {
      let profiles = try BlockedProfiles.fetchProfiles(in: context)
      for profile in profiles {
        await handleSessionSync(for: profile.id)
      }
    } catch {
      Log.info("Error fetching profiles for sync - \(error)", category: .sync)
    }
  }

  // MARK: - Location Handling

  private func handleSyncedLocations(_ syncedLocations: [SyncedLocation]) {
    guard let context = modelContext else {
      Log.info("No model context available", category: .sync)
      return
    }

    for syncedLocation in syncedLocations {
      do {
        if let existingLocation = try SavedLocation.find(
          byID: syncedLocation.locationId,
          in: context
        ) {
          // Update existing location if remote version is newer
          if syncedLocation.lastModified > existingLocation.updatedAt {
            _ = try SavedLocation.update(
              existingLocation,
              in: context,
              name: syncedLocation.name,
              latitude: syncedLocation.latitude,
              longitude: syncedLocation.longitude,
              defaultRadiusMeters: syncedLocation.defaultRadiusMeters,
              isLocked: syncedLocation.isLocked
            )
            Log.info("Updated location '\(syncedLocation.name)' from remote", category: .sync)
          }
        } else {
          // Create new location from synced data with original ID preserved
          let location = SavedLocation(
            id: syncedLocation.locationId,
            name: syncedLocation.name,
            latitude: syncedLocation.latitude,
            longitude: syncedLocation.longitude,
            defaultRadiusMeters: syncedLocation.defaultRadiusMeters,
            isLocked: syncedLocation.isLocked
          )
          context.insert(location)
          try context.save()
          Log.info("Created location '\(syncedLocation.name)' from remote", category: .sync)
        }
      } catch {
        Log.info("Error handling synced location - \(error)", category: .sync)
      }
    }
  }

  // MARK: - Sync Reset Handling

  private func handleSyncReset(clearAppSelections: Bool) {
    guard let context = modelContext else {
      Log.info("No model context available", category: .sync)
      return
    }

    if clearAppSelections {
      // Mark all profiles as needing app selection
      do {
        let profiles = try BlockedProfiles.fetchProfiles(in: context)
        for profile in profiles {
          profile.needsAppSelection = true
          profile.selectedActivity = .init()  // Clear selection
          BlockedProfiles.updateSnapshot(for: profile)
        }
        try context.save()
        Log.info("Cleared app selections for all profiles", category: .sync)
      } catch {
        Log.info("Error clearing app selections - \(error)", category: .sync)
      }
    }

    // Re-push all local synced profiles and locations to CloudKit
    Task {
      await rePushLocalSyncedData(context: context)

      // Then trigger a full sync to get any data from other devices
      await ProfileSyncManager.shared.performFullSync()
    }
  }

  /// Re-push all local profiles and locations to CloudKit after a reset
  private func rePushLocalSyncedData(context: ModelContext) async {
    do {
      // Re-push all profiles
      let profiles = try BlockedProfiles.fetchProfiles(in: context)
      for profile in profiles where !profile.isNewerSchemaVersion {
        try? await ProfileSyncManager.shared.pushProfile(profile)
        Log.info("Re-pushed profile '\(profile.name)' after reset", category: .sync)
      }

      // Re-push all locations
      let locations = try SavedLocation.fetchAll(in: context)
      for location in locations {
        try? await ProfileSyncManager.shared.pushLocation(location)
        Log.info("Re-pushed location '\(location.name)' after reset", category: .sync)
      }
    } catch {
      Log.info("Error re-pushing data after reset - \(error)", category: .sync)
    }
  }

  // MARK: - Profile Push Helper

  /// Push a profile to CloudKit when global sync is enabled
  func pushProfile(_ profile: BlockedProfiles) {
    guard ProfileSyncManager.shared.isEnabled else { return }
    guard !profile.isNewerSchemaVersion else {
      Log.info("Skipping push for V2+ profile '\(profile.name)'", category: .sync)
      return
    }
    guard let context = modelContext else {
      Log.info("No model context available for push", category: .sync)
      return
    }

    // Increment version before pushing and persist
    profile.syncVersion += 1
    try? context.save()

    Task {
      try? await ProfileSyncManager.shared.pushProfile(profile)
    }
  }

  /// Delete a profile from CloudKit when it's deleted locally (if global sync is enabled)
  func deleteProfileFromSync(_ profileId: UUID) {
    guard ProfileSyncManager.shared.isEnabled else { return }

    Task {
      try? await ProfileSyncManager.shared.deleteProfile(profileId)
    }
  }
}
