// FoqosTests/TriggerMigrationTests.swift
import XCTest

@testable import FamilyFoqos

final class TriggerMigrationTests: XCTestCase {

  // MARK: - ManualBlockingStrategy

  func testMigrateManualStrategy() {
    let (start, stop) = TriggerMigration.migrateFromStrategy("ManualBlockingStrategy")

    XCTAssertTrue(start.manual)
    XCTAssertFalse(start.anyNFC)
    XCTAssertFalse(start.anyQR)

    XCTAssertTrue(stop.manual)
    XCTAssertFalse(stop.sameNFC)
    XCTAssertFalse(stop.timer)
  }

  // MARK: - NFCBlockingStrategy

  func testMigrateNFCStrategy() {
    let (start, stop) = TriggerMigration.migrateFromStrategy("NFCBlockingStrategy")

    XCTAssertTrue(start.anyNFC)
    XCTAssertFalse(start.manual)

    XCTAssertTrue(stop.sameNFC)
    XCTAssertFalse(stop.manual)
  }

  // MARK: - NFCManualBlockingStrategy

  func testMigrateNFCManualStrategy() {
    let (start, stop) = TriggerMigration.migrateFromStrategy("NFCManualBlockingStrategy")

    XCTAssertTrue(start.manual)
    XCTAssertFalse(start.anyNFC)

    XCTAssertTrue(stop.anyNFC)
    XCTAssertFalse(stop.sameNFC)
  }

  // MARK: - NFCTimerBlockingStrategy

  func testMigrateNFCTimerStrategy() {
    let (start, stop) = TriggerMigration.migrateFromStrategy("NFCTimerBlockingStrategy")

    XCTAssertTrue(start.manual)

    XCTAssertTrue(stop.anyNFC)
    XCTAssertTrue(stop.timer)
  }

  // MARK: - QRCodeBlockingStrategy

  func testMigrateQRCodeStrategy() {
    let (start, stop) = TriggerMigration.migrateFromStrategy("QRCodeBlockingStrategy")

    XCTAssertTrue(start.anyQR)
    XCTAssertFalse(start.manual)

    XCTAssertTrue(stop.sameQR)
    XCTAssertFalse(stop.manual)
  }

  // MARK: - QRManualBlockingStrategy

  func testMigrateQRManualStrategy() {
    let (start, stop) = TriggerMigration.migrateFromStrategy("QRManualBlockingStrategy")

    XCTAssertTrue(start.manual)
    XCTAssertFalse(start.anyQR)

    XCTAssertTrue(stop.anyQR)
    XCTAssertFalse(stop.sameQR)
  }

  // MARK: - QRTimerBlockingStrategy

  func testMigrateQRTimerStrategy() {
    let (start, stop) = TriggerMigration.migrateFromStrategy("QRTimerBlockingStrategy")

    XCTAssertTrue(start.manual)

    XCTAssertTrue(stop.anyQR)
    XCTAssertTrue(stop.timer)
  }

  // MARK: - ShortcutTimerBlockingStrategy

  func testMigrateShortcutTimerStrategy() {
    let (start, stop) = TriggerMigration.migrateFromStrategy("ShortcutTimerBlockingStrategy")

    XCTAssertTrue(start.manual)
    XCTAssertFalse(start.anyNFC)
    XCTAssertFalse(start.anyQR)

    XCTAssertTrue(stop.timer)
    XCTAssertFalse(stop.manual)
    XCTAssertFalse(stop.anyNFC)
    XCTAssertFalse(stop.anyQR)
  }

  // MARK: - Unknown Strategy

  func testMigrateUnknownStrategyDefaultsToManual() {
    let (start, stop) = TriggerMigration.migrateFromStrategy("UnknownStrategy")

    XCTAssertTrue(start.manual)
    XCTAssertTrue(stop.manual)
  }

  // MARK: - Physical Unlock Migration

  func testMigratePhysicalUnlockNFC() {
    var stop = ProfileStopConditions()
    stop.anyNFC = true

    let (newStop, newStopTagId) = TriggerMigration.migratePhysicalUnlock(
      stopConditions: stop,
      physicalUnblockNFCTagId: "nfc-tag-123",
      physicalUnblockQRCodeId: nil
    )

    XCTAssertTrue(newStop.specificNFC)
    XCTAssertFalse(newStop.anyNFC)  // Replaced by specific
    XCTAssertEqual(newStopTagId, "nfc-tag-123")
  }

  func testMigratePhysicalUnlockQR() {
    var stop = ProfileStopConditions()
    stop.anyQR = true

    let (newStop, newStopCodeId) = TriggerMigration.migratePhysicalUnlock(
      stopConditions: stop,
      physicalUnblockNFCTagId: nil,
      physicalUnblockQRCodeId: "qr-code-456"
    )

    XCTAssertTrue(newStop.specificQR)
    XCTAssertFalse(newStop.anyQR)  // Replaced by specific
    XCTAssertEqual(newStopCodeId, "qr-code-456")
  }

  // MARK: - Schedule Migration

  func testMigrateScheduleToStartAndStop() {
    let legacySchedule = BlockedProfileSchedule(
      days: [.monday, .tuesday],
      startHour: 9,
      startMinute: 0,
      endHour: 17,
      endMinute: 30,
      updatedAt: Date()
    )

    let (startSchedule, stopSchedule) = TriggerMigration.migrateSchedule(legacySchedule)

    XCTAssertEqual(startSchedule?.days, [.monday, .tuesday])
    XCTAssertEqual(startSchedule?.hour, 9)
    XCTAssertEqual(startSchedule?.minute, 0)

    XCTAssertEqual(stopSchedule?.days, [.monday, .tuesday])
    XCTAssertEqual(stopSchedule?.hour, 17)
    XCTAssertEqual(stopSchedule?.minute, 30)
  }

  func testMigrateNilScheduleReturnsNils() {
    let (startSchedule, stopSchedule) = TriggerMigration.migrateSchedule(nil)

    XCTAssertNil(startSchedule)
    XCTAssertNil(stopSchedule)
  }
}
