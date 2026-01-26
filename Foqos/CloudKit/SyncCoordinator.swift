import Combine
import Foundation
import SwiftData

/// Coordinates between ProfileSyncManager notifications and local SwiftData storage.
/// Handles incoming synced profiles, sessions, and locations from other devices.
class SyncCoordinator: ObservableObject {
  static let shared = SyncCoordinator()

  private var cancellables = Set<AnyCancellable>()
  private var modelContext: ModelContext?

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

    for syncedSession in syncedSessions {
      // Skip sessions originating from this device
      if syncedSession.originDeviceId == deviceId {
        continue
      }

      // Only process active sessions (for start propagation)
      // Session end is handled via StrategyManager notification
      if syncedSession.isActive {
        // Check if we already have this session
        if (try? BlockedProfileSession.findSession(
          byID: syncedSession.sessionId.uuidString,
          in: context
        )) != nil {
          // Session already exists locally
          print("SyncCoordinator: Session already exists locally")
          continue
        }

        // Post notification for StrategyManager to start the session
        NotificationCenter.default.post(
          name: .remoteSessionStartRequested,
          object: nil,
          userInfo: [
            "profileId": syncedSession.profileId,
            "sessionId": syncedSession.sessionId
          ]
        )
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
          // Create new location from synced data
          _ = try SavedLocation.create(
            in: context,
            name: syncedLocation.name,
            latitude: syncedLocation.latitude,
            longitude: syncedLocation.longitude,
            defaultRadiusMeters: syncedLocation.defaultRadiusMeters,
            isLocked: syncedLocation.isLocked
          )
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

    // Trigger a full sync to get fresh data
    Task {
      await ProfileSyncManager.shared.performFullSync()
    }
  }

  // MARK: - Profile Push Helper

  /// Push a profile to CloudKit when it's marked as synced
  func pushProfileIfSynced(_ profile: BlockedProfiles) {
    guard profile.isSynced else { return }

    // Increment version before pushing
    profile.syncVersion += 1

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
