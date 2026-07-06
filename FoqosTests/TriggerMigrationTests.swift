// FoqosTests/TriggerMigrationTests.swift
import FoqosShared
import XCTest

@testable import FamilyFoqos

final class TriggerMigrationTests: XCTestCase {

  // MARK: - ManualBlockingStrategy

  func testGivenManualStrategyV1_WhenMigrating_ThenSetsManualTriggers() {
    let (start, stop) = TriggerMigration.migrateFromStrategy("ManualBlockingStrategy")

    XCTAssertTrue(start.manual)
    XCTAssertFalse(start.anyNFC)
    XCTAssertFalse(start.anyQR)

    XCTAssertTrue(stop.manual)
    XCTAssertFalse(stop.sameNFC)
    XCTAssertFalse(stop.timer)
  }

  // MARK: - NFCBlockingStrategy

  func testGivenNFCStrategyV1_WhenMigrating_ThenSetsNFCTriggers() {
    let (start, stop) = TriggerMigration.migrateFromStrategy("NFCBlockingStrategy")

    XCTAssertTrue(start.anyNFC)
    XCTAssertFalse(start.manual)

    XCTAssertTrue(stop.sameNFC)
    XCTAssertFalse(stop.manual)
  }

  // MARK: - NFCManualBlockingStrategy

  func testGivenNFCManualStrategyV1_WhenMigrating_ThenSetsManualStartAnyNFCStop() {
    let (start, stop) = TriggerMigration.migrateFromStrategy("NFCManualBlockingStrategy")

    XCTAssertTrue(start.manual)
    XCTAssertFalse(start.anyNFC)

    XCTAssertTrue(stop.anyNFC)
    XCTAssertFalse(stop.sameNFC)
  }

  // MARK: - NFCTimerBlockingStrategy

  func testGivenNFCTimerStrategyV1_WhenMigrating_ThenSetsManualStartAnyNFCAndTimerStop() {
    let (start, stop) = TriggerMigration.migrateFromStrategy("NFCTimerBlockingStrategy")

    XCTAssertTrue(start.manual)

    XCTAssertTrue(stop.anyNFC)
    XCTAssertTrue(stop.timer)
  }

  // MARK: - QRCodeBlockingStrategy

  func testGivenQRCodeStrategyV1_WhenMigrating_ThenSetsQRTriggers() {
    let (start, stop) = TriggerMigration.migrateFromStrategy("QRCodeBlockingStrategy")

    XCTAssertTrue(start.anyQR)
    XCTAssertFalse(start.manual)

    XCTAssertTrue(stop.sameQR)
    XCTAssertFalse(stop.manual)
  }

  // MARK: - QRManualBlockingStrategy

  func testGivenQRManualStrategyV1_WhenMigrating_ThenSetsManualStartAnyQRStop() {
    let (start, stop) = TriggerMigration.migrateFromStrategy("QRManualBlockingStrategy")

    XCTAssertTrue(start.manual)
    XCTAssertFalse(start.anyQR)

    XCTAssertTrue(stop.anyQR)
    XCTAssertFalse(stop.sameQR)
  }

  // MARK: - QRTimerBlockingStrategy

  func testGivenQRTimerStrategyV1_WhenMigrating_ThenSetsManualStartAnyQRAndTimerStop() {
    let (start, stop) = TriggerMigration.migrateFromStrategy("QRTimerBlockingStrategy")

    XCTAssertTrue(start.manual)

    XCTAssertTrue(stop.anyQR)
    XCTAssertTrue(stop.timer)
  }

  // MARK: - ShortcutTimerBlockingStrategy

  func testGivenShortcutTimerStrategyV1_WhenMigrating_ThenSetsManualStartTimerStop() {
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

  func testGivenUnknownStrategyV1_WhenMigrating_ThenDefaultsToManual() {
    let (start, stop) = TriggerMigration.migrateFromStrategy("UnknownStrategy")

    XCTAssertTrue(start.manual)
    XCTAssertTrue(stop.manual)
  }

  // MARK: - Physical Unlock Migration

  func testGivenAnyNFCStop_WhenMigratingPhysicalUnlockNFC_ThenSetsSpecificNFC() {
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

  func testGivenSameNFCStop_WhenMigratingPhysicalUnlockNFC_ThenClearsSameNFC() {
    // Simulates NFCBlockingStrategy migration path: sameNFC is set,
    // then physical unlock adds specificNFC — sameNFC must be cleared
    var stop = ProfileStopConditions()
    stop.sameNFC = true

    let (newStop, _) = TriggerMigration.migratePhysicalUnlock(
      stopConditions: stop,
      physicalUnblockNFCTagId: "nfc-tag-123",
      physicalUnblockQRCodeId: nil
    )

    XCTAssertTrue(newStop.specificNFC)
    XCTAssertFalse(newStop.sameNFC)  // Must be cleared
    XCTAssertFalse(newStop.anyNFC)
  }

  func testGivenAnyQRStop_WhenMigratingPhysicalUnlockQR_ThenSetsSpecificQR() {
    var stop = ProfileStopConditions()
    stop.anyQR = true

    let (newStop, newStopCodeId) = TriggerMigration.migratePhysicalUnlock(
      stopConditions: stop,
      physicalUnblockNFCTagId: nil,
      physicalUnblockQRCodeId: "qr-code-456"
    )

    XCTAssertTrue(newStop.specificQR)
    XCTAssertFalse(newStop.anyQR)  // Replaced by specific
    XCTAssertEqual(newStopCodeId, QRCodeHasher.hash("qr-code-456"))
  }

  func testGivenSameQRStop_WhenMigratingPhysicalUnlockQR_ThenClearsSameQR() {
    // Simulates QRCodeBlockingStrategy migration path: sameQR is set,
    // then physical unlock adds specificQR — sameQR must be cleared
    var stop = ProfileStopConditions()
    stop.sameQR = true

    let (newStop, _) = TriggerMigration.migratePhysicalUnlock(
      stopConditions: stop,
      physicalUnblockNFCTagId: nil,
      physicalUnblockQRCodeId: "qr-code-456"
    )

    XCTAssertTrue(newStop.specificQR)
    XCTAssertFalse(newStop.sameQR)  // Must be cleared
    XCTAssertFalse(newStop.anyQR)
  }

  // MARK: - Schedule Migration

  func testGivenLegacySchedule_WhenMigrating_ThenSplitsIntoStartAndStop() {
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

  func testGivenNilSchedule_WhenMigrating_ThenReturnsNils() {
    let (startSchedule, stopSchedule) = TriggerMigration.migrateSchedule(nil)

    XCTAssertNil(startSchedule)
    XCTAssertNil(stopSchedule)
  }
}
