import SwiftData

enum ProfileMigrationUtil {
  /// Migrates V1 profiles to V2 trigger system if needed.
  /// Defers profiles with active sessions. Safe to call as a no-op when nothing needs migration.
  static func migrateProfilesIfNeeded(context: ModelContext) {
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
          if profile.migrateToV2IfEligible(hasActiveSession: hasActiveSession) {
            migratedProfiles.append(profile)
            migratedCount += 1
          } else if hasActiveSession {
            deferredCount += 1
          }
        }
      }
      if migratedCount > 0 {
        try context.save()
        Log.info("Migrated \(migratedCount) profiles to schema V2", category: .app)
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
    } catch {
      Log.error("Failed to migrate profiles: \(error.localizedDescription)", category: .app)
    }
  }
}
