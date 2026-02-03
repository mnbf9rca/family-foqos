// FoqosTests/BlockedProfilesTriggersTests.swift
import SwiftData
import XCTest

@testable import FamilyFoqos

final class BlockedProfilesTriggersTests: XCTestCase {

  func testNewProfileHasSchemaVersion2() throws {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(
      for: BlockedProfiles.self,
      configurations: config
    )
    let context = ModelContext(container)

    let profile = BlockedProfiles(name: "Test")
    context.insert(profile)

    XCTAssertEqual(profile.profileSchemaVersion, 2)
  }

  func testNewProfileHasEmptyTriggers() throws {
    let profile = BlockedProfiles(name: "Test")

    XCTAssertFalse(profile.startTriggers.isValid)
    XCTAssertFalse(profile.stopConditions.isValid)
  }

  func testCanSetStartTriggers() throws {
    let profile = BlockedProfiles(name: "Test")
    var triggers = profile.startTriggers
    triggers.manual = true
    triggers.anyNFC = true
    profile.startTriggers = triggers

    XCTAssertTrue(profile.startTriggers.manual)
    XCTAssertTrue(profile.startTriggers.anyNFC)
    XCTAssertTrue(profile.startTriggers.isValid)
  }

  func testCanSetStopConditions() throws {
    let profile = BlockedProfiles(name: "Test")
    var conditions = profile.stopConditions
    conditions.manual = true
    conditions.timer = true
    profile.stopConditions = conditions

    XCTAssertTrue(profile.stopConditions.manual)
    XCTAssertTrue(profile.stopConditions.timer)
    XCTAssertTrue(profile.stopConditions.isValid)
  }

  func testCanSetStartNFCTagId() throws {
    let profile = BlockedProfiles(name: "Test")
    profile.startNFCTagId = "tag-123"
    XCTAssertEqual(profile.startNFCTagId, "tag-123")
  }

  func testCanSetStopNFCTagId() throws {
    let profile = BlockedProfiles(name: "Test")
    profile.stopNFCTagId = "tag-456"
    XCTAssertEqual(profile.stopNFCTagId, "tag-456")
  }

  func testCanSetStartQRCodeId() throws {
    let profile = BlockedProfiles(name: "Test")
    profile.startQRCodeId = "qr-123"
    XCTAssertEqual(profile.startQRCodeId, "qr-123")
  }

  func testCanSetStopQRCodeId() throws {
    let profile = BlockedProfiles(name: "Test")
    profile.stopQRCodeId = "qr-456"
    XCTAssertEqual(profile.stopQRCodeId, "qr-456")
  }

  func testCanSetStartSchedule() throws {
    let profile = BlockedProfiles(name: "Test")
    let schedule = ProfileScheduleTime(
      days: [.monday, .friday],
      hour: 9,
      minute: 0,
      updatedAt: Date()
    )
    profile.startSchedule = schedule

    XCTAssertEqual(profile.startSchedule?.days, [.monday, .friday])
    XCTAssertEqual(profile.startSchedule?.hour, 9)
  }

  func testCanSetStopSchedule() throws {
    let profile = BlockedProfiles(name: "Test")
    let schedule = ProfileScheduleTime(
      days: [.monday, .friday],
      hour: 17,
      minute: 30,
      updatedAt: Date()
    )
    profile.stopSchedule = schedule

    XCTAssertEqual(profile.stopSchedule?.days, [.monday, .friday])
    XCTAssertEqual(profile.stopSchedule?.hour, 17)
  }
}
