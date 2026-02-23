import Foundation

enum UserDefaultsMigration {
  private static let standardMigrationFlag = "family_foqos_user_defaults_migrated"
  private static let appGroupMigrationFlag = "family_foqos_app_group_migrated"

  private static let standardKeyMapping: [(old: String, new: String)] = [
    ("showIntroScreen", "family_foqos_show_intro_screen"),
    ("showModeSelection", "family_foqos_show_mode_selection"),
    ("hasCompletedOnboarding", "family_foqos_has_completed_onboarding"),
    ("warnWhenActivatingAwayFromLocation", "family_foqos_warn_when_activating_away_from_location"),
    ("launchCount", "family_foqos_launch_count"),
    ("lastVersionPromptedForReview", "family_foqos_last_version_prompted_for_review"),
    ("showHabitTracker", "family_foqos_show_habit_tracker"),
    ("com.cynexia.family-foqos.currentActivityId", "family_foqos_current_activity_id"),
    ("emergencyUnblocksRemaining", "family_foqos_emergency_unblocks_remaining"),
    ("emergencyUnblocksResetPeriodInDays", "family_foqos_emergency_unblocks_reset_period_in_days"),
    ("lastEmergencyUnblocksResetDate", "family_foqos_last_emergency_unblocks_reset_date"),
    ("emergencySettingsLocked", "family_foqos_emergency_settings_locked"),
    ("emergencySettingsVersion", "family_foqos_emergency_settings_version"),
    ("com.cynexia.family-foqos.backgroundtasks", "family_foqos_background_tasks"),
  ]

  private static let appGroupKeyMapping: [(old: String, new: String)] = [
    ("familyFoqosThemeColorName", "family_foqos_theme_color_name"),
    ("profileSnapshots", "family_foqos_profile_snapshots"),
    ("activeScheduleSession", "family_foqos_active_schedule_session"),
    ("completedScheduleSessions", "family_foqos_completed_schedule_sessions"),
    ("deviceSyncId", "family_foqos_device_sync_id"),
    ("deviceSyncEnabled", "family_foqos_device_sync_enabled"),
  ]

  static func migrateIfNeeded(defaults: UserDefaults = .standard) {
    guard !defaults.bool(forKey: standardMigrationFlag) else { return }

    for (old, new) in standardKeyMapping {
      if let value = defaults.object(forKey: old) {
        defaults.set(value, forKey: new)
        defaults.removeObject(forKey: old)
      }
    }

    defaults.set(true, forKey: standardMigrationFlag)
  }

  static func migrateAppGroupIfNeeded(
    defaults: UserDefaults? = UserDefaults(suiteName: "group.com.cynexia.family-foqos")
  ) {
    guard let defaults = defaults else {
      Log.warning(
        "Failed to create app group suite; skipping app group migration",
        category: .app)
      return
    }
    guard !defaults.bool(forKey: appGroupMigrationFlag) else { return }

    for (old, new) in appGroupKeyMapping {
      if let value = defaults.object(forKey: old) {
        defaults.set(value, forKey: new)
        defaults.removeObject(forKey: old)
      }
    }

    defaults.set(true, forKey: appGroupMigrationFlag)
  }
}
