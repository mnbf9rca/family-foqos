import SwiftData

@MainActor
enum ProfileMigrationUtil {
  /// Saves migration before enqueueing; pre-attach saves are buffered by the facade.
  @discardableResult
  static func migrate(_ profile: BlockedProfiles, hasActiveSession: Bool) throws -> Bool {
    let previousVersion = profile.profileSchemaVersion
    let created = try profile.migrateIfEligible(hasActiveSession: hasActiveSession)
    guard profile.profileSchemaVersion != previousVersion else { return false }
    let manager = ProfileSyncManager.shared
    if manager.isEnabled {
      do { try manager.enqueueProfileSave(profile.id) } catch SyncEngineControllingError.notAttached {
        Log.info("Migrated profile upload deferred until sync attaches", category: .sync)
      }
      for id in created {
        do { try manager.enqueueTagSave(id) } catch SyncEngineControllingError.notAttached {
          Log.info("Migrated tag upload deferred until sync attaches", category: .sync)
        }
      }
    }
    return true
  }

  /// Migrates legacy profiles to the current trigger system if needed.
  /// Defers profiles with active sessions. Safe to call as a no-op when nothing needs migration.
  @discardableResult
  static func migrateProfilesIfNeeded(context: ModelContext) -> Int {
    do {
      let profiles = try BlockedProfiles.fetchProfiles(in: context)

      // Find profile ID with active session (if any)
      let activeSession = try BlockedProfileSession.mostRecentActiveSession(in: context)
      let activeProfileId = activeSession?.blockedProfile.id

      var migratedCount = 0
      var deferredCount = 0
      var migratedProfiles: [BlockedProfiles] = []
      for profile in profiles {
        if profile.needsMigration {
          let hasActiveSession = (profile.id == activeProfileId)
          if try migrate(profile, hasActiveSession: hasActiveSession) {
            migratedProfiles.append(profile)
            migratedCount += 1
          } else if hasActiveSession {
            deferredCount += 1
          }
        }
      }
      if migratedCount > 0 {
        Log.info("Migrated \(migratedCount) profiles to schema V3", category: .app)
        // Refresh shared snapshots before the centralized launch reconciliation registers
        // DeviceActivity schedules. Registering here would duplicate the launch refresh.
        for profile in migratedProfiles {
          BlockedProfiles.updateSnapshot(for: profile)
        }
      }
      if deferredCount > 0 {
        Log.info(
          "Deferred migration for \(deferredCount) profiles with active sessions",
          category: .app
        )
      }
      return migratedCount
    } catch {
      Log.error("Failed to migrate profiles: \(error.localizedDescription)", category: .app)
      return 0
    }
  }
}
