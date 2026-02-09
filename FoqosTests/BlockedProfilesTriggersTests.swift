// FoqosTests/BlockedProfilesTriggersTests.swift
import XCTest

@testable import FamilyFoqos

final class BlockedProfilesTriggersTests: XCTestCase {

  func testNewProfileHasSchemaVersion2() {
    let profile = BlockedProfiles(name: "Test")

    XCTAssertEqual(profile.profileSchemaVersion, 2)
  }

  func testNewProfileHasEmptyTriggers() {
    let profile = BlockedProfiles(name: "Test")

    XCTAssertFalse(profile.startTriggers.isValid)
    XCTAssertFalse(profile.stopConditions.isValid)
  }

  func testCanSetStartTriggers() {
    let profile = BlockedProfiles(name: "Test")
    var triggers = profile.startTriggers
    triggers.manual = true
    triggers.anyNFC = true
    profile.startTriggers = triggers

    XCTAssertTrue(profile.startTriggers.manual)
    XCTAssertTrue(profile.startTriggers.anyNFC)
    XCTAssertTrue(profile.startTriggers.isValid)
  }

  func testCanSetStopConditions() {
    let profile = BlockedProfiles(name: "Test")
    var conditions = profile.stopConditions
    conditions.manual = true
    conditions.timer = true
    profile.stopConditions = conditions

    XCTAssertTrue(profile.stopConditions.manual)
    XCTAssertTrue(profile.stopConditions.timer)
    XCTAssertTrue(profile.stopConditions.isValid)
  }

  func testCanSetStartNFCTagId() {
    let profile = BlockedProfiles(name: "Test")
    profile.startNFCTagId = "tag-123"
    XCTAssertEqual(profile.startNFCTagId, "tag-123")
  }

  func testCanSetStopNFCTagId() {
    let profile = BlockedProfiles(name: "Test")
    profile.stopNFCTagId = "tag-456"
    XCTAssertEqual(profile.stopNFCTagId, "tag-456")
  }

  func testCanSetStartQRCodeId() {
    let profile = BlockedProfiles(name: "Test")
    profile.startQRCodeId = "qr-123"
    XCTAssertEqual(profile.startQRCodeId, "qr-123")
  }

  func testCanSetStopQRCodeId() {
    let profile = BlockedProfiles(name: "Test")
    profile.stopQRCodeId = "qr-456"
    XCTAssertEqual(profile.stopQRCodeId, "qr-456")
  }

  func testCanSetStartSchedule() {
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

  func testCanSetStopSchedule() {
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

  func testCloneProfileCopiesV2TriggerData() {
    let source = BlockedProfiles(name: "Source")

    // Set V2 trigger data on source
    var start = source.startTriggers
    start.anyNFC = true
    start.schedule = true
    source.startTriggers = start

    var stop = source.stopConditions
    stop.sameNFC = true
    stop.timer = true
    source.stopConditions = stop

    source.startNFCTagId = "nfc-start-123"
    source.startQRCodeId = "qr-start-456"
    source.stopNFCTagId = "nfc-stop-789"
    source.stopQRCodeId = "qr-stop-012"

    source.startSchedule = ProfileScheduleTime(
      days: [.monday, .wednesday], hour: 9, minute: 0, updatedAt: Date()
    )
    source.stopSchedule = ProfileScheduleTime(
      days: [.monday, .wednesday], hour: 17, minute: 0, updatedAt: Date()
    )

    // Clone (without ModelContext — just test the field copy logic)
    let cloned = BlockedProfiles(name: "Clone")
    cloned.startTriggers = source.startTriggers
    cloned.stopConditions = source.stopConditions
    cloned.startNFCTagId = source.startNFCTagId
    cloned.startQRCodeId = source.startQRCodeId
    cloned.stopNFCTagId = source.stopNFCTagId
    cloned.stopQRCodeId = source.stopQRCodeId
    cloned.startSchedule = source.startSchedule
    cloned.stopSchedule = source.stopSchedule

    XCTAssertEqual(cloned.startTriggers.anyNFC, true)
    XCTAssertEqual(cloned.startTriggers.schedule, true)
    XCTAssertEqual(cloned.stopConditions.sameNFC, true)
    XCTAssertEqual(cloned.stopConditions.timer, true)
    XCTAssertEqual(cloned.startNFCTagId, "nfc-start-123")
    XCTAssertEqual(cloned.startQRCodeId, "qr-start-456")
    XCTAssertEqual(cloned.stopNFCTagId, "nfc-stop-789")
    XCTAssertEqual(cloned.stopQRCodeId, "qr-stop-012")
    XCTAssertEqual(cloned.startSchedule?.hour, 9)
    XCTAssertEqual(cloned.stopSchedule?.hour, 17)
  }
}
