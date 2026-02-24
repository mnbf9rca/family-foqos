// FoqosTests/BlockedProfilesMigrationTests.swift
import SwiftData
import XCTest

@testable import FamilyFoqos

final class BlockedProfilesMigrationTests: XCTestCase {

  func testGivenV1Profile_WhenMigrating_ThenSetsSchemaVersionToV2() {
    let profile = BlockedProfiles(name: "Test")
    profile.profileSchemaVersion = 1
    profile.blockingStrategyId = "ManualBlockingStrategy"

    profile.migrateToV2IfNeeded()

    XCTAssertEqual(profile.profileSchemaVersion, 2)
  }

  func testGivenV1NFCProfile_WhenMigrating_ThenSetsNFCTriggers() {
    let profile = BlockedProfiles(name: "Test")
    profile.profileSchemaVersion = 1
    profile.blockingStrategyId = "NFCBlockingStrategy"

    profile.migrateToV2IfNeeded()

    XCTAssertTrue(profile.startTriggers.anyNFC)
    XCTAssertTrue(profile.stopConditions.sameNFC)
  }

  func testGivenV1PhysicalUnlockProfile_WhenMigrating_ThenSetsSpecificNFCStop() {
    let profile = BlockedProfiles(name: "Test")
    profile.profileSchemaVersion = 1
    profile.blockingStrategyId = "NFCManualBlockingStrategy"
    profile.physicalUnblockNFCTagId = "tag-123"

    profile.migrateToV2IfNeeded()

    XCTAssertTrue(profile.stopConditions.specificNFC)
    XCTAssertFalse(profile.stopConditions.anyNFC)
    XCTAssertEqual(profile.stopNFCTagId, "tag-123")
  }

  func testGivenV1ScheduledProfile_WhenMigrating_ThenSetsStartAndStopSchedules() {
    let profile = BlockedProfiles(name: "Test")
    profile.profileSchemaVersion = 1
    profile.blockingStrategyId = "ManualBlockingStrategy"
    profile.schedule = BlockedProfileSchedule(
      days: [.monday],
      startHour: 9,
      startMinute: 0,
      endHour: 17,
      endMinute: 0,
      updatedAt: Date()
    )

    profile.migrateToV2IfNeeded()

    XCTAssertEqual(profile.startSchedule?.hour, 9)
    XCTAssertEqual(profile.stopSchedule?.hour, 17)
  }

  func testGivenV2Profile_WhenMigrating_ThenDoesNothing() {
    let profile = BlockedProfiles(name: "Test")
    profile.profileSchemaVersion = 2
    var triggers = profile.startTriggers
    triggers.manual = true
    profile.startTriggers = triggers

    profile.migrateToV2IfNeeded()

    // Should remain unchanged
    XCTAssertEqual(profile.profileSchemaVersion, 2)
    XCTAssertTrue(profile.startTriggers.manual)
  }

  func testGivenV1Profile_WhenCheckingNeedsMigration_ThenReturnsTrue() {
    let profile = BlockedProfiles(name: "Test")
    profile.profileSchemaVersion = 1
    XCTAssertTrue(profile.needsMigration)
  }

  func testGivenV2Profile_WhenCheckingNeedsMigration_ThenReturnsFalse() {
    let profile = BlockedProfiles(name: "Test")
    profile.profileSchemaVersion = 2
    XCTAssertFalse(profile.needsMigration)
  }

  func testGivenActiveSession_WhenMigrating_ThenSkipsProfile() {
    let profile = BlockedProfiles(name: "Active")
    profile.profileSchemaVersion = 1
    profile.blockingStrategyId = "ManualBlockingStrategy"

    let migrated = profile.migrateToV2IfEligible(hasActiveSession: true)

    XCTAssertFalse(migrated)
    XCTAssertEqual(profile.profileSchemaVersion, 1)  // Still V1
  }

  func testGivenV1ScheduledProfile_WhenMigrating_ThenSetsTriggerFlags() {
    let profile = BlockedProfiles(name: "Scheduled")
    profile.profileSchemaVersion = 1
    profile.blockingStrategyId = "ManualBlockingStrategy"
    profile.schedule = BlockedProfileSchedule(
      days: [.monday, .friday],
      startHour: 9, startMinute: 0,
      endHour: 17, endMinute: 0,
      updatedAt: Date()
    )

    profile.migrateToV2IfNeeded()

    XCTAssertTrue(profile.startTriggers.schedule, "Start triggers should have schedule enabled")
    XCTAssertTrue(profile.stopConditions.schedule, "Stop conditions should have schedule enabled")
    XCTAssertEqual(profile.startSchedule?.hour, 9)
    XCTAssertEqual(profile.stopSchedule?.hour, 17)
  }

  func testGivenCurrentSchemaVersion_WhenCheckingIsNewer_ThenReturnsFalse() {
    let profile = BlockedProfiles(name: "Current")
    profile.profileSchemaVersion = 2
    XCTAssertFalse(profile.isNewerSchemaVersion)
  }

  func testGivenOlderSchemaVersion_WhenCheckingIsNewer_ThenReturnsFalse() {
    let profile = BlockedProfiles(name: "Old")
    profile.profileSchemaVersion = 1
    XCTAssertFalse(profile.isNewerSchemaVersion)
  }

  func testGivenFutureSchemaVersion_WhenCheckingIsNewer_ThenReturnsTrue() {
    let profile = BlockedProfiles(name: "Future")
    profile.profileSchemaVersion = 3
    XCTAssertTrue(profile.isNewerSchemaVersion)
  }

  func testGivenSchemaVersionConstant_WhenCheckingIsNewer_ThenUsesCurrentSchemaVersion() {
    // Verify the threshold is based on currentSchemaVersion, not a hardcoded value
    let profile = BlockedProfiles(name: "Test")
    profile.profileSchemaVersion = BlockedProfiles.currentSchemaVersion
    XCTAssertFalse(profile.isNewerSchemaVersion, "Current version should not be 'newer'")

    profile.profileSchemaVersion = BlockedProfiles.currentSchemaVersion + 1
    XCTAssertTrue(profile.isNewerSchemaVersion, "Version above current should be 'newer'")
  }

  func testGivenNoActiveSession_WhenMigrating_ThenMigratesSuccessfully() {
    let profile = BlockedProfiles(name: "Inactive")
    profile.profileSchemaVersion = 1
    profile.blockingStrategyId = "ManualBlockingStrategy"

    let migrated = profile.migrateToV2IfEligible(hasActiveSession: false)

    XCTAssertTrue(migrated)
    XCTAssertEqual(profile.profileSchemaVersion, 2)  // Now V2
  }
}
