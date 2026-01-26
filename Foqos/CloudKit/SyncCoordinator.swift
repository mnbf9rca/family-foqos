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

    // Observe synced sessions
    NotificationCenter.default.publisher(for: .syncedSessionsReceived)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] notification in
        guard let sessions = notification.userInfo?["sessions"] as? [SyncedSession] else { return }
        self?.handleSyncedSessions(sessions)
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

    // Reconcile deletions: remove local synced profiles not in remote set
    // Only delete profiles that were synced from remote (not originated here)
    do {
      let localProfiles = try BlockedProfiles.fetchProfiles(in: context)
      for profile in localProfiles {
        // Only consider profiles that are marked as synced
        guard profile.isSynced else { continue }

        // If profile is not in remote and wasn't originated from this device, delete it
        if !remoteProfileIds.contains(profile.id) {
          // Check if this profile has any recent remote activity before deleting
          // to avoid race conditions during initial sync
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
    profile.isSynced = true

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
      isSynced: true,
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

      // Start remote session directly via StrategyManager
      print("SyncCoordinator: Starting remote session for profile \(syncedSession.profileId)")
      StrategyManager.shared.startRemoteSession(
        context: context,
        profileId: syncedSession.profileId,
        sessionId: syncedSession.sessionId
      )

      // Track that this profile's session was triggered by remote
      remoteTriggeredProfileIds.insert(syncedSession.profileId)
    }

    // Check for sessions to STOP
    // Only stop if:
    // 1. We have a local active session for a synced profile
    // 2. That profile's session was triggered by remote (not started locally)
    // 3. The remote no longer has an active session for that profile
    if let localActiveSession = StrategyManager.shared.activeSession,
      localActiveSession.blockedProfile.isSynced
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
      // Mark all synced profiles as needing app selection
      do {
        let profiles = try BlockedProfiles.fetchProfiles(in: context)
        for profile in profiles where profile.isSynced {
          profile.needsAppSelection = true
          profile.selectedActivity = .init()  // Clear selection
          BlockedProfiles.updateSnapshot(for: profile)
        }
        try context.save()
        print("SyncCoordinator: Cleared app selections for all synced profiles")
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

  /// Re-push all local synced profiles and locations to CloudKit after a reset
  private func rePushLocalSyncedData(context: ModelContext) async {
    do {
      // Re-push synced profiles
      let profiles = try BlockedProfiles.fetchProfiles(in: context)
      for profile in profiles where profile.isSynced {
        try? await ProfileSyncManager.shared.pushProfile(profile)
        print("SyncCoordinator: Re-pushed profile '\(profile.name)' after reset")
      }

      // Re-push synced locations
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

  /// Push a profile to CloudKit when it's marked as synced
  func pushProfileIfSynced(_ profile: BlockedProfiles) {
    guard profile.isSynced else { return }
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

  /// Delete a profile from CloudKit when it's deleted locally
  func deleteProfileFromSync(_ profileId: UUID, wasSynced: Bool) {
    guard wasSynced else { return }

    Task {
      try? await ProfileSyncManager.shared.deleteProfile(profileId)
    }
  }
}
