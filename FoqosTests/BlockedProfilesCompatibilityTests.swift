// FoqosTests/BlockedProfilesCompatibilityTests.swift
import XCTest

@testable import FamilyFoqos

final class BlockedProfilesCompatibilityTests: XCTestCase {

  private func makeProfile(
    configuringStart: (inout ProfileStartTriggers) -> Void = { _ in },
    configuringStop: (inout ProfileStopConditions) -> Void = { _ in }
  ) -> BlockedProfiles {
    let profile = BlockedProfiles(name: "Test")
    var start = profile.startTriggers
    var stop = profile.stopConditions
    configuringStart(&start)
    configuringStop(&stop)
    profile.startTriggers = start
    profile.stopConditions = stop
    return profile
  }

  func testCompatibilityStrategyIdForNFCBlockingStrategy() {
    let profile = makeProfile(
      configuringStart: { $0.anyNFC = true },
      configuringStop: { $0.sameNFC = true }
    )
    XCTAssertEqual(profile.compatibilityStrategyId, "NFCBlockingStrategy")
  }

  func testCompatibilityStrategyIdForNFCTimerBlockingStrategy() {
    let profile = makeProfile(
      configuringStart: { $0.manual = true },
      configuringStop: { $0.anyNFC = true; $0.timer = true }
    )
    XCTAssertEqual(profile.compatibilityStrategyId, "NFCTimerBlockingStrategy")
  }

  func testCompatibilityStrategyIdForNFCManualBlockingStrategy() {
    let profile = makeProfile(
      configuringStart: { $0.manual = true },
      configuringStop: { $0.anyNFC = true }
    )
    XCTAssertEqual(profile.compatibilityStrategyId, "NFCManualBlockingStrategy")
  }

  func testCompatibilityStrategyIdForQRCodeBlockingStrategy() {
    let profile = makeProfile(
      configuringStart: { $0.anyQR = true },
      configuringStop: { $0.sameQR = true }
    )
    XCTAssertEqual(profile.compatibilityStrategyId, "QRCodeBlockingStrategy")
  }

  func testCompatibilityStrategyIdForQRTimerBlockingStrategy() {
    let profile = makeProfile(
      configuringStart: { $0.manual = true },
      configuringStop: { $0.anyQR = true; $0.timer = true }
    )
    XCTAssertEqual(profile.compatibilityStrategyId, "QRTimerBlockingStrategy")
  }

  func testCompatibilityStrategyIdForQRManualBlockingStrategy() {
    let profile = makeProfile(
      configuringStart: { $0.manual = true },
      configuringStop: { $0.anyQR = true }
    )
    XCTAssertEqual(profile.compatibilityStrategyId, "QRManualBlockingStrategy")
  }

  func testCompatibilityStrategyIdForShortcutTimerBlockingStrategy() {
    let profile = makeProfile(
      configuringStart: { $0.manual = true },
      configuringStop: { $0.timer = true }
    )
    XCTAssertEqual(profile.compatibilityStrategyId, "ShortcutTimerBlockingStrategy")
  }

  func testCompatibilityStrategyIdForManualBlockingStrategy() {
    let profile = makeProfile(
      configuringStart: { $0.manual = true },
      configuringStop: { $0.manual = true }
    )
    XCTAssertEqual(profile.compatibilityStrategyId, "ManualBlockingStrategy")
  }

  func testCompatibilityStrategyIdDefaultsToManual() {
    let profile = BlockedProfiles(name: "Test")
    // Empty triggers - should default to manual
    XCTAssertEqual(profile.compatibilityStrategyId, "ManualBlockingStrategy")
  }

  func testUpdateCompatibilityStrategyIdSetsBlockingStrategyId() {
    let profile = makeProfile(
      configuringStart: { $0.anyNFC = true },
      configuringStop: { $0.sameNFC = true }
    )
    profile.updateCompatibilityStrategyId()
    XCTAssertEqual(profile.blockingStrategyId, "NFCBlockingStrategy")
  }

  func testNFCTimerTakesPrecedenceOverNFCManual() {
    // When both timer and anyNFC are true, NFCTimerBlockingStrategy should win
    let profile = makeProfile(
      configuringStart: { $0.manual = true },
      configuringStop: { $0.anyNFC = true; $0.timer = true; $0.manual = true }
    )
    XCTAssertEqual(profile.compatibilityStrategyId, "NFCTimerBlockingStrategy")
  }

  func testShortcutTimerExcludesNFCAndQR() {
    // ShortcutTimerBlockingStrategy only applies when NFC and QR are NOT enabled
    let profile = makeProfile(
      configuringStart: { $0.manual = true },
      configuringStop: { $0.timer = true; $0.anyNFC = true }
    )
    XCTAssertNotEqual(profile.compatibilityStrategyId, "ShortcutTimerBlockingStrategy")
    XCTAssertEqual(profile.compatibilityStrategyId, "NFCTimerBlockingStrategy")
  }
}
