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

    // Observe synced sessions (legacy - kept for backwards compatibility)
    NotificationCenter.default.publisher(for: .syncedSessionsReceived)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] notification in
        guard let sessions = notification.userInfo?["sessions"] as? [SyncedSession] else { return }
        self?.handleSyncedSessions(sessions)
      }
      .store(in: &cancellables)

    // Observe new ProfileSessionRecord notifications
    NotificationCenter.default.publisher(for: .profileSessionRecordsReceived)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] notification in
        guard let sessions = notification.userInfo?["sessions"] as? [ProfileSessionRecord] else {
          return
        }
        Task { @MainActor in
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
      print("SyncCoordinator: Global sync disabled, skipping push")
      return
    }

    guard let context = modelContext else {
      print("SyncCoordinator: No model context available for local push")
      return
    }

    do {
      let profiles = try BlockedProfiles.fetchProfiles(in: context)
      let locations = try SavedLocation.fetchAll(in: context)

      print("SyncCoordinator: Found \(profiles.count) profiles to sync")

      // Create sync objects on main queue (accesses SwiftData properties)
      let deviceId = SharedData.deviceSyncId.uuidString
      let syncedProfiles = profiles.map { SyncedProfile(from: $0, originDeviceId: deviceId) }
      let syncedLocations = locations.map { SyncedLocation(from: $0) }

      print("SyncCoordinator: Pushing \(syncedProfiles.count) profiles and \(syncedLocations.count) locations to CloudKit")

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
      print("SyncCoordinator: Error pushing local data - \(error)")
    }
  }

  // MARK: - Profile Handling

  private func handleSyncedProfiles(_ syncedProfiles: [SyncedProfile]) {
    guard let context = modelContext else {
      print("SyncCoordinator: No model context available")
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
        print("SyncCoordinator: Error handling synced profile - \(error)")
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
          print("SyncCoordinator: Removing profile '\(profile.name)' deleted from remote")
          try BlockedProfiles.deleteProfile(profile, in: context)
        }
      }
    } catch {
      print("SyncCoordinator: Error reconciling profile deletions - \(error)")
    }

    try? context.save()
  }

  private func updateLocalProfile(
    _ profile: BlockedProfiles,
    from synced: SyncedProfile,
    in context: ModelContext
  ) {
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
    profile.updatedAt = synced.updatedAt

    // Update snapshot for extensions
    BlockedProfiles.updateSnapshot(for: profile)

    print("SyncCoordinator: Updated profile '\(profile.name)' from remote")
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

    context.insert(profile)
    BlockedProfiles.updateSnapshot(for: profile)

    print("SyncCoordinator: Created profile '\(profile.name)' from remote (needs app selection)")
  }

  // MARK: - Session Handling

  private func handleSyncedSessions(_ syncedSessions: [SyncedSession]) {
    guard let context = modelContext else {
      print("SyncCoordinator: No model context available")
      return
    }

    let deviceId = SharedData.deviceSyncId.uuidString

    // Get profile IDs with active remote sessions (from other devices)
    let remoteActiveProfileIds = Set(
      syncedSessions
        .filter { $0.originDeviceId != deviceId && $0.isActive }
        .map { $0.profileId }
    )

    // Check for sessions to START
    for syncedSession in syncedSessions {
      // Skip sessions originating from this device
      if syncedSession.originDeviceId == deviceId {
        continue
      }

      // Only process active sessions for start propagation
      guard syncedSession.isActive else { continue }

      // Skip if we already have an active session for this profile
      if let existingSession = StrategyManager.shared.activeSession,
        existingSession.blockedProfile.id == syncedSession.profileId
      {
        print("SyncCoordinator: Session already active for profile")
        continue
      }

      // Start remote session directly via StrategyManager with synced startTime
      print("SyncCoordinator: Starting remote session for profile \(syncedSession.profileId) with startTime \(syncedSession.startTime)")
      StrategyManager.shared.startRemoteSession(
        context: context,
        profileId: syncedSession.profileId,
        sessionId: syncedSession.sessionId,
        startTime: syncedSession.startTime
      )

      // Track that this profile's session was triggered by remote
      remoteTriggeredProfileIds.insert(syncedSession.profileId)
    }

    // Check for sessions to STOP
    // Only stop if:
    // 1. We have a local active session and global sync is enabled
    // 2. That profile's session was triggered by remote (not started locally)
    // 3. The remote no longer has an active session for that profile
    if let localActiveSession = StrategyManager.shared.activeSession,
      ProfileSyncManager.shared.isEnabled
    {
      let localProfileId = localActiveSession.blockedProfile.id

      // Only auto-stop if this session was triggered by remote
      if remoteTriggeredProfileIds.contains(localProfileId) {
        // Check if remote no longer has active session for this profile
        if !remoteActiveProfileIds.contains(localProfileId) {
          print("SyncCoordinator: Remote session ended, stopping local session for profile \(localProfileId)")
          StrategyManager.shared.stopRemoteSession(context: context, profileId: localProfileId)

          // Remove from tracking
          remoteTriggeredProfileIds.remove(localProfileId)
        }
      }
    }
  }

  // MARK: - New Session Handling (CAS-based)

  /// Handle ProfileSessionRecord notifications from the new sync system
  @MainActor
  private func handleProfileSessionRecords(_ sessions: [ProfileSessionRecord]) {
    guard let context = modelContext else {
      print("SyncCoordinator: No model context available")
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
      print("SyncCoordinator: No model context available")
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
        print("SyncCoordinator: No remote session, stopping local")
        StrategyManager.shared.stopRemoteSession(context: context, profileId: profileId)
      }

    case .error(let error):
      print("SyncCoordinator: Error fetching session - \(error)")
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
      print("SyncCoordinator: Ignoring our own update for \(profileId)")
      return
    }

    let localActive = StrategyManager.shared.activeSession?.blockedProfile.id == profileId

    if session.isActive && !localActive {
      // Remote is active, local is not - start locally
      print("SyncCoordinator: Remote session active, starting locally")

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
      // Remote is stopped, local is active - stop locally if remote-triggered
      if remoteTriggeredProfileIds.contains(profileId) {
        print("SyncCoordinator: Remote session stopped, stopping locally")
        StrategyManager.shared.stopRemoteSession(context: context, profileId: profileId)
        remoteTriggeredProfileIds.remove(profileId)
      }
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
      print("SyncCoordinator: Error fetching profiles for sync - \(error)")
    }
  }

  // MARK: - Location Handling

  private func handleSyncedLocations(_ syncedLocations: [SyncedLocation]) {
    guard let context = modelContext else {
      print("SyncCoordinator: No model context available")
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
            print("SyncCoordinator: Updated location '\(syncedLocation.name)' from remote")
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
          print("SyncCoordinator: Created location '\(syncedLocation.name)' from remote")
        }
      } catch {
        print("SyncCoordinator: Error handling synced location - \(error)")
      }
    }
  }

  // MARK: - Sync Reset Handling

  private func handleSyncReset(clearAppSelections: Bool) {
    guard let context = modelContext else {
      print("SyncCoordinator: No model context available")
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
        print("SyncCoordinator: Cleared app selections for all profiles")
      } catch {
        print("SyncCoordinator: Error clearing app selections - \(error)")
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
      for profile in profiles {
        try? await ProfileSyncManager.shared.pushProfile(profile)
        print("SyncCoordinator: Re-pushed profile '\(profile.name)' after reset")
      }

      // Re-push all locations
      let locations = try SavedLocation.fetchAll(in: context)
      for location in locations {
        try? await ProfileSyncManager.shared.pushLocation(location)
        print("SyncCoordinator: Re-pushed location '\(location.name)' after reset")
      }
    } catch {
      print("SyncCoordinator: Error re-pushing data after reset - \(error)")
    }
  }

  // MARK: - Profile Push Helper

  /// Push a profile to CloudKit when global sync is enabled
  func pushProfile(_ profile: BlockedProfiles) {
    guard ProfileSyncManager.shared.isEnabled else { return }
    guard let context = modelContext else {
      print("SyncCoordinator: No model context available for push")
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
