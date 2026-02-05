// FoqosTests/BlockedProfilesCompatibilityTests.swift
import XCTest

@testable import FamilyFoqos

final class BlockedProfilesCompatibilityTests: XCTestCase {

  func testCompatibilityStrategyIdForNFCBlockingStrategy() {
    let profile = BlockedProfiles(name: "Test")
    var start = profile.startTriggers
    var stop = profile.stopConditions
    start.anyNFC = true
    stop.sameNFC = true
    profile.startTriggers = start
    profile.stopConditions = stop

    XCTAssertEqual(profile.compatibilityStrategyId, "NFCBlockingStrategy")
  }

  func testCompatibilityStrategyIdForNFCTimerBlockingStrategy() {
    let profile = BlockedProfiles(name: "Test")
    var start = profile.startTriggers
    var stop = profile.stopConditions
    start.manual = true
    stop.anyNFC = true
    stop.timer = true
    profile.startTriggers = start
    profile.stopConditions = stop

    XCTAssertEqual(profile.compatibilityStrategyId, "NFCTimerBlockingStrategy")
  }

  func testCompatibilityStrategyIdForNFCManualBlockingStrategy() {
    let profile = BlockedProfiles(name: "Test")
    var start = profile.startTriggers
    var stop = profile.stopConditions
    start.manual = true
    stop.anyNFC = true
    profile.startTriggers = start
    profile.stopConditions = stop

    XCTAssertEqual(profile.compatibilityStrategyId, "NFCManualBlockingStrategy")
  }

  func testCompatibilityStrategyIdForQRCodeBlockingStrategy() {
    let profile = BlockedProfiles(name: "Test")
    var start = profile.startTriggers
    var stop = profile.stopConditions
    start.anyQR = true
    stop.sameQR = true
    profile.startTriggers = start
    profile.stopConditions = stop

    XCTAssertEqual(profile.compatibilityStrategyId, "QRCodeBlockingStrategy")
  }

  func testCompatibilityStrategyIdForQRTimerBlockingStrategy() {
    let profile = BlockedProfiles(name: "Test")
    var start = profile.startTriggers
    var stop = profile.stopConditions
    start.manual = true
    stop.anyQR = true
    stop.timer = true
    profile.startTriggers = start
    profile.stopConditions = stop

    XCTAssertEqual(profile.compatibilityStrategyId, "QRTimerBlockingStrategy")
  }

  func testCompatibilityStrategyIdForQRManualBlockingStrategy() {
    let profile = BlockedProfiles(name: "Test")
    var start = profile.startTriggers
    var stop = profile.stopConditions
    start.manual = true
    stop.anyQR = true
    profile.startTriggers = start
    profile.stopConditions = stop

    XCTAssertEqual(profile.compatibilityStrategyId, "QRManualBlockingStrategy")
  }

  func testCompatibilityStrategyIdForShortcutTimerBlockingStrategy() {
    let profile = BlockedProfiles(name: "Test")
    var start = profile.startTriggers
    var stop = profile.stopConditions
    start.manual = true
    stop.timer = true
    profile.startTriggers = start
    profile.stopConditions = stop

    XCTAssertEqual(profile.compatibilityStrategyId, "ShortcutTimerBlockingStrategy")
  }

  func testCompatibilityStrategyIdForManualBlockingStrategy() {
    let profile = BlockedProfiles(name: "Test")
    var start = profile.startTriggers
    var stop = profile.stopConditions
    start.manual = true
    stop.manual = true
    profile.startTriggers = start
    profile.stopConditions = stop

    XCTAssertEqual(profile.compatibilityStrategyId, "ManualBlockingStrategy")
  }

  func testCompatibilityStrategyIdDefaultsToManual() {
    let profile = BlockedProfiles(name: "Test")
    // Empty triggers - should default to manual
    XCTAssertEqual(profile.compatibilityStrategyId, "ManualBlockingStrategy")
  }

  func testUpdateCompatibilityStrategyIdSetsBlockingStrategyId() {
    let profile = BlockedProfiles(name: "Test")
    var start = profile.startTriggers
    var stop = profile.stopConditions
    start.anyNFC = true
    stop.sameNFC = true
    profile.startTriggers = start
    profile.stopConditions = stop

    profile.updateCompatibilityStrategyId()

    XCTAssertEqual(profile.blockingStrategyId, "NFCBlockingStrategy")
  }

  func testNFCTimerTakesPrecedenceOverNFCManual() {
    // When both timer and anyNFC are true, NFCTimerBlockingStrategy should win
    let profile = BlockedProfiles(name: "Test")
    var start = profile.startTriggers
    var stop = profile.stopConditions
    start.manual = true
    stop.anyNFC = true
    stop.timer = true
    stop.manual = true // Also has manual, but timer+NFC takes precedence
    profile.startTriggers = start
    profile.stopConditions = stop

    XCTAssertEqual(profile.compatibilityStrategyId, "NFCTimerBlockingStrategy")
  }

  func testShortcutTimerExcludesNFCAndQR() {
    // ShortcutTimerBlockingStrategy only applies when NFC and QR are NOT enabled
    let profile = BlockedProfiles(name: "Test")
    var start = profile.startTriggers
    var stop = profile.stopConditions
    start.manual = true
    stop.timer = true
    stop.anyNFC = true // Has NFC, so should NOT be ShortcutTimer
    profile.startTriggers = start
    profile.stopConditions = stop

    XCTAssertNotEqual(profile.compatibilityStrategyId, "ShortcutTimerBlockingStrategy")
    XCTAssertEqual(profile.compatibilityStrategyId, "NFCTimerBlockingStrategy")
  }
}
