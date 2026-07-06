import XCTest

@testable import FamilyFoqos

final class UserDefaultsMigrationTests: XCTestCase {
  private var defaults: UserDefaults!

  override func setUp() {
    super.setUp()
    defaults = UserDefaults(suiteName: "UserDefaultsMigrationTests")!
    defaults.removePersistentDomain(forName: "UserDefaultsMigrationTests")
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: "UserDefaultsMigrationTests")
    defaults = nil
    super.tearDown()
  }

  // MARK: - Standard suite tests

  func testGivenOldStandardKeys_WhenMigrate_ThenValuesCopiedToNewKeys() {
    // Given
    defaults.set(false, forKey: "showIntroScreen")
    defaults.set(true, forKey: "showModeSelection")
    defaults.set(true, forKey: "hasCompletedOnboarding")
    defaults.set(false, forKey: "warnWhenActivatingAwayFromLocation")
    defaults.set(7, forKey: "launchCount")
    defaults.set("2.0", forKey: "lastVersionPromptedForReview")
    defaults.set(false, forKey: "showHabitTracker")
    defaults.set("activity-123", forKey: "com.cynexia.family-foqos.currentActivityId")
    defaults.set(2, forKey: "emergencyUnblocksRemaining")
    defaults.set(14, forKey: "emergencyUnblocksResetPeriodInDays")
    defaults.set(1000.0, forKey: "lastEmergencyUnblocksResetDate")
    defaults.set(true, forKey: "emergencySettingsLocked")
    defaults.set(3, forKey: "emergencySettingsVersion")
    defaults.set(["key": "val"], forKey: "com.cynexia.family-foqos.backgroundtasks")

    // When
    UserDefaultsMigration.migrateIfNeeded(defaults: defaults)

    // Then
    XCTAssertEqual(defaults.bool(forKey: "family_foqos_show_intro_screen"), false)
    XCTAssertEqual(defaults.bool(forKey: "family_foqos_show_mode_selection"), true)
    XCTAssertEqual(defaults.bool(forKey: "family_foqos_has_completed_onboarding"), true)
    XCTAssertEqual(
      defaults.bool(forKey: "family_foqos_warn_when_activating_away_from_location"), false)
    XCTAssertEqual(defaults.integer(forKey: "family_foqos_launch_count"), 7)
    XCTAssertEqual(
      defaults.string(forKey: "family_foqos_last_version_prompted_for_review"), "2.0")
    XCTAssertEqual(defaults.bool(forKey: "family_foqos_show_habit_tracker"), false)
    XCTAssertEqual(
      defaults.string(forKey: "family_foqos_current_activity_id"), "activity-123")
    XCTAssertEqual(defaults.integer(forKey: "family_foqos_emergency_unblocks_remaining"), 2)
    XCTAssertEqual(
      defaults.integer(forKey: "family_foqos_emergency_unblocks_reset_period_in_days"), 14)
    XCTAssertEqual(
      defaults.double(forKey: "family_foqos_last_emergency_unblocks_reset_date"), 1000.0)
    XCTAssertEqual(defaults.bool(forKey: "family_foqos_emergency_settings_locked"), true)
    XCTAssertEqual(defaults.integer(forKey: "family_foqos_emergency_settings_version"), 3)
    XCTAssertNotNil(defaults.dictionary(forKey: "family_foqos_background_tasks"))
  }

  func testGivenOldKeys_WhenMigrate_ThenOldKeysRemoved() {
    defaults.set(false, forKey: "showIntroScreen")
    defaults.set(7, forKey: "launchCount")

    UserDefaultsMigration.migrateIfNeeded(defaults: defaults)

    XCTAssertNil(defaults.object(forKey: "showIntroScreen"))
    XCTAssertNil(defaults.object(forKey: "launchCount"))
  }

  func testGivenAlreadyMigrated_WhenMigrate_ThenNoOp() {
    defaults.set(true, forKey: "family_foqos_user_defaults_migrated")
    defaults.set(42, forKey: "family_foqos_launch_count")

    UserDefaultsMigration.migrateIfNeeded(defaults: defaults)

    XCTAssertEqual(defaults.integer(forKey: "family_foqos_launch_count"), 42)
  }

  func testGivenNoOldKeys_WhenMigrate_ThenSetsFlag() {
    UserDefaultsMigration.migrateIfNeeded(defaults: defaults)

    XCTAssertTrue(defaults.bool(forKey: "family_foqos_user_defaults_migrated"))
  }

  func testGivenPartialOldKeys_WhenMigrate_ThenOnlyExistingKeysMigrated() {
    defaults.set(3, forKey: "launchCount")

    UserDefaultsMigration.migrateIfNeeded(defaults: defaults)

    XCTAssertEqual(defaults.integer(forKey: "family_foqos_launch_count"), 3)
    XCTAssertNil(defaults.object(forKey: "family_foqos_last_version_prompted_for_review"))
  }

  // MARK: - App group suite tests

  func testGivenOldAppGroupKeys_WhenMigrate_ThenValuesCopiedToNewKeys() {
    // Given
    defaults.set("Warm Sandstone", forKey: "familyFoqosThemeColorName")
    defaults.set(Data([1, 2, 3]), forKey: "profileSnapshots")
    defaults.set(Data([4, 5, 6]), forKey: "activeScheduleSession")
    defaults.set(Data([7, 8, 9]), forKey: "completedScheduleSessions")
    defaults.set("device-uuid-123", forKey: "deviceSyncId")
    defaults.set(true, forKey: "deviceSyncEnabled")

    // When
    UserDefaultsMigration.migrateAppGroupIfNeeded(defaults: defaults)

    // Then
    XCTAssertEqual(defaults.string(forKey: "family_foqos_theme_color_name"), "Warm Sandstone")
    XCTAssertEqual(defaults.data(forKey: "family_foqos_profile_snapshots"), Data([1, 2, 3]))
    XCTAssertEqual(
      defaults.data(forKey: "family_foqos_active_schedule_session"), Data([4, 5, 6]))
    XCTAssertEqual(
      defaults.data(forKey: "family_foqos_completed_schedule_sessions"), Data([7, 8, 9]))
    XCTAssertEqual(defaults.string(forKey: "family_foqos_device_sync_id"), "device-uuid-123")
    XCTAssertEqual(defaults.bool(forKey: "family_foqos_device_sync_enabled"), true)
  }

  func testGivenOldAppGroupKeys_WhenMigrate_ThenOldKeysRemoved() {
    defaults.set("Warm Sandstone", forKey: "familyFoqosThemeColorName")
    defaults.set(true, forKey: "deviceSyncEnabled")

    UserDefaultsMigration.migrateAppGroupIfNeeded(defaults: defaults)

    XCTAssertNil(defaults.object(forKey: "familyFoqosThemeColorName"))
    XCTAssertNil(defaults.object(forKey: "deviceSyncEnabled"))
  }

  func testGivenAlreadyMigratedAppGroup_WhenMigrate_ThenNoOp() {
    defaults.set(true, forKey: "family_foqos_app_group_migrated")
    defaults.set("Slate Stone", forKey: "family_foqos_theme_color_name")

    UserDefaultsMigration.migrateAppGroupIfNeeded(defaults: defaults)

    XCTAssertEqual(defaults.string(forKey: "family_foqos_theme_color_name"), "Slate Stone")
  }

  func testGivenNilSuite_WhenMigrateAppGroup_ThenNoOp() {
    UserDefaultsMigration.migrateAppGroupIfNeeded(defaults: nil)
    // Should not crash or set any flags — just returns early
  }

  func testGivenNewAppGroupKeyAlreadyWritten_WhenMigrate_ThenNewValueKeptAndOldRemoved() {
    // An extension wrote the new key before the first app launch; the legacy shadow lingers.
    defaults.set(Data([4, 5, 6]), forKey: "family_foqos_active_schedule_session")
    defaults.set(Data([9, 9, 9]), forKey: "activeScheduleSession")

    UserDefaultsMigration.migrateAppGroupIfNeeded(defaults: defaults)

    XCTAssertEqual(
      defaults.data(forKey: "family_foqos_active_schedule_session"), Data([4, 5, 6]),
      "fresh extension-written value must survive migration (#217)")
    XCTAssertNil(
      defaults.object(forKey: "activeScheduleSession"), "stale legacy key must be removed")
  }

  func testGivenNewCompletedListWithFreshSession_WhenMigrate_ThenNotClobberedByLegacyList() {
    // Legacy completed list from before the update...
    defaults.set(Data([1, 1]), forKey: "completedScheduleSessions")
    // ...and the extension's appended (superset) list under the new key.
    defaults.set(Data([1, 1, 2, 2]), forKey: "family_foqos_completed_schedule_sessions")

    UserDefaultsMigration.migrateAppGroupIfNeeded(defaults: defaults)

    XCTAssertEqual(
      defaults.data(forKey: "family_foqos_completed_schedule_sessions"), Data([1, 1, 2, 2]),
      "the just-completed session must not be lost to the stale legacy list (#217)")
    XCTAssertNil(defaults.object(forKey: "completedScheduleSessions"))
  }

  func testGivenLegacyOnlyAppGroupKey_WhenMigrate_ThenStillCopiedToNewKey() {
    // Normal migration path (no extension pre-write) must be unchanged.
    defaults.set(Data([7, 8, 9]), forKey: "completedScheduleSessions")

    UserDefaultsMigration.migrateAppGroupIfNeeded(defaults: defaults)

    XCTAssertEqual(
      defaults.data(forKey: "family_foqos_completed_schedule_sessions"), Data([7, 8, 9]))
    XCTAssertNil(defaults.object(forKey: "completedScheduleSessions"))
  }

  // MARK: - Synchronous contract tests

  func testGivenOldShowIntroScreen_WhenMigrate_ThenNewKeyPopulatedSynchronously() {
    // Given: old key set to false (returning user)
    defaults.set(false, forKey: "showIntroScreen")

    // When: migration runs
    UserDefaultsMigration.migrateIfNeeded(defaults: defaults)

    // Then: new key is immediately readable (no async gap)
    // This documents the contract that @AppStorage("family_foqos_show_intro_screen")
    // will find the correct value if migration runs before view init.
    XCTAssertFalse(defaults.bool(forKey: "family_foqos_show_intro_screen"))
  }
}
