// FoqosTests/BlockedProfilesMigrationTests.swift
import SwiftData
import XCTest

@testable import FamilyFoqos

final class BlockedProfilesMigrationTests: XCTestCase {

  func testMigrateV1ToV2SetsSchemaVersion() throws {
    let profile = BlockedProfiles(name: "Test")
    profile.profileSchemaVersion = 1
    profile.blockingStrategyId = "ManualBlockingStrategy"

    profile.migrateToV2IfNeeded()

    XCTAssertEqual(profile.profileSchemaVersion, 2)
  }

  func testMigrateV1ToV2SetsTriggers() throws {
    let profile = BlockedProfiles(name: "Test")
    profile.profileSchemaVersion = 1
    profile.blockingStrategyId = "NFCBlockingStrategy"

    profile.migrateToV2IfNeeded()

    XCTAssertTrue(profile.startTriggers.anyNFC)
    XCTAssertTrue(profile.stopConditions.sameNFC)
  }

  func testMigrateV1ToV2MigratesPhysicalUnlock() throws {
    let profile = BlockedProfiles(name: "Test")
    profile.profileSchemaVersion = 1
    profile.blockingStrategyId = "NFCManualBlockingStrategy"
    profile.physicalUnblockNFCTagId = "tag-123"

    profile.migrateToV2IfNeeded()

    XCTAssertTrue(profile.stopConditions.specificNFC)
    XCTAssertFalse(profile.stopConditions.anyNFC)
    XCTAssertEqual(profile.stopNFCTagId, "tag-123")
  }

  func testMigrateV1ToV2MigratesSchedule() throws {
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

  func testMigrateV2DoesNothing() throws {
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

  func testNeedsMigrationForV1() {
    let profile = BlockedProfiles(name: "Test")
    profile.profileSchemaVersion = 1
    XCTAssertTrue(profile.needsMigration)
  }

  func testNeedsMigrationFalseForV2() {
    let profile = BlockedProfiles(name: "Test")
    profile.profileSchemaVersion = 2
    XCTAssertFalse(profile.needsMigration)
  }

  func testMigrateSkipsProfileWithActiveSession() {
    let profile = BlockedProfiles(name: "Active")
    profile.profileSchemaVersion = 1
    profile.blockingStrategyId = "ManualBlockingStrategy"

    let migrated = profile.migrateToV2IfEligible(hasActiveSession: true)

    XCTAssertFalse(migrated)
    XCTAssertEqual(profile.profileSchemaVersion, 1)  // Still V1
  }

  func testMigrationSetsSchemaVersionLast() {
    // Verify that migrateToV2IfNeeded sets all fields before schema version
    let profile = BlockedProfiles(name: "Test")
    profile.profileSchemaVersion = 1
    profile.blockingStrategyId = "NFCBlockingStrategy"

    profile.migrateToV2IfNeeded()

    // If migration succeeded, all V2 fields should be populated
    XCTAssertEqual(profile.profileSchemaVersion, 2)
    XCTAssertTrue(profile.startTriggers.anyNFC)
    XCTAssertTrue(profile.stopConditions.sameNFC)
  }

  func testMigrateV1ScheduleSetsTriggerFlags() {
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

  func testMigrateRunsWhenNoActiveSession() {
    let profile = BlockedProfiles(name: "Inactive")
    profile.profileSchemaVersion = 1
    profile.blockingStrategyId = "ManualBlockingStrategy"

    let migrated = profile.migrateToV2IfEligible(hasActiveSession: false)

    XCTAssertTrue(migrated)
    XCTAssertEqual(profile.profileSchemaVersion, 2)  // Now V2
  }
}
