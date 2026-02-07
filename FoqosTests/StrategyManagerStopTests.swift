// FoqosTests/StrategyManagerStopTests.swift
import XCTest

@testable import FamilyFoqos

@MainActor
final class StrategyManagerStopTests: XCTestCase {

  func testCanStopWithManualWhenManualEnabled() {
    var stop = ProfileStopConditions()
    stop.manual = true

    let result = StrategyManager.canStop(
      with: .manual,
      conditions: stop,
      sessionTag: nil,
      stopNFCTagId: nil,
      stopQRCodeId: nil
    )

    XCTAssertTrue(result.allowed)
  }

  func testCannotStopWithManualWhenNotEnabled() {
    var stop = ProfileStopConditions()
    stop.timer = true

    let result = StrategyManager.canStop(
      with: .manual,
      conditions: stop,
      sessionTag: nil,
      stopNFCTagId: nil,
      stopQRCodeId: nil
    )

    XCTAssertFalse(result.allowed)
  }

  func testCanStopWithAnyNFCWhenEnabled() {
    var stop = ProfileStopConditions()
    stop.anyNFC = true

    let result = StrategyManager.canStop(
      with: .nfc(tag: "any-tag"),
      conditions: stop,
      sessionTag: nil,
      stopNFCTagId: nil,
      stopQRCodeId: nil
    )

    XCTAssertTrue(result.allowed)
  }

  func testCanStopWithSpecificNFCWhenMatches() {
    var stop = ProfileStopConditions()
    stop.specificNFC = true

    let result = StrategyManager.canStop(
      with: .nfc(tag: "required-tag"),
      conditions: stop,
      sessionTag: nil,
      stopNFCTagId: "required-tag",
      stopQRCodeId: nil
    )

    XCTAssertTrue(result.allowed)
  }

  func testCannotStopWithSpecificNFCWhenMismatch() {
    var stop = ProfileStopConditions()
    stop.specificNFC = true

    let result = StrategyManager.canStop(
      with: .nfc(tag: "wrong-tag"),
      conditions: stop,
      sessionTag: nil,
      stopNFCTagId: "required-tag",
      stopQRCodeId: nil
    )

    XCTAssertFalse(result.allowed)
    XCTAssertNotNil(result.errorMessage)
  }

  func testCanStopWithSameNFCWhenSessionTagMatches() {
    var stop = ProfileStopConditions()
    stop.sameNFC = true

    // Session tags are stored with "nfc:" prefix in production (via startWithNFCTag)
    let result = StrategyManager.canStop(
      with: .nfc(tag: "session-tag"),
      conditions: stop,
      sessionTag: "nfc:session-tag",
      stopNFCTagId: nil,
      stopQRCodeId: nil
    )

    XCTAssertTrue(result.allowed)
  }

  func testCannotStopWithSameNFCWhenSessionTagMismatch() {
    var stop = ProfileStopConditions()
    stop.sameNFC = true

    let result = StrategyManager.canStop(
      with: .nfc(tag: "different-tag"),
      conditions: stop,
      sessionTag: "nfc:original-tag",
      stopNFCTagId: nil,
      stopQRCodeId: nil
    )

    XCTAssertFalse(result.allowed)
    XCTAssertNotNil(result.errorMessage)
  }

  // MARK: - determineStopAction Tests

  func testDetermineStopActionManualReturnsStopImmediately() {
    var conditions = ProfileStopConditions()
    conditions.manual = true
    conditions.anyNFC = true  // Even with NFC, manual wins

    let action = StrategyManager.determineStopAction(for: conditions)

    XCTAssertEqual(action, .stopImmediately)
  }

  func testDetermineStopActionOnlyAnyNFCReturnsScanNFC() {
    var conditions = ProfileStopConditions()
    conditions.anyNFC = true

    let action = StrategyManager.determineStopAction(for: conditions)

    XCTAssertEqual(action, .scanNFC)
  }

  func testDetermineStopActionOnlySameNFCReturnsScanNFC() {
    var conditions = ProfileStopConditions()
    conditions.sameNFC = true

    let action = StrategyManager.determineStopAction(for: conditions)

    XCTAssertEqual(action, .scanNFC)
  }

  func testDetermineStopActionOnlySpecificNFCReturnsScanNFC() {
    var conditions = ProfileStopConditions()
    conditions.specificNFC = true

    let action = StrategyManager.determineStopAction(for: conditions)

    XCTAssertEqual(action, .scanNFC)
  }

  func testDetermineStopActionOnlyAnyQRReturnsScanQR() {
    var conditions = ProfileStopConditions()
    conditions.anyQR = true

    let action = StrategyManager.determineStopAction(for: conditions)

    XCTAssertEqual(action, .scanQR)
  }

  func testDetermineStopActionOnlySameQRReturnsScanQR() {
    var conditions = ProfileStopConditions()
    conditions.sameQR = true

    let action = StrategyManager.determineStopAction(for: conditions)

    XCTAssertEqual(action, .scanQR)
  }

  func testDetermineStopActionOnlySpecificQRReturnsScanQR() {
    var conditions = ProfileStopConditions()
    conditions.specificQR = true

    let action = StrategyManager.determineStopAction(for: conditions)

    XCTAssertEqual(action, .scanQR)
  }

  func testDetermineStopActionBothNFCAndQRReturnsShowPicker() {
    var conditions = ProfileStopConditions()
    conditions.anyNFC = true
    conditions.anyQR = true

    let action = StrategyManager.determineStopAction(for: conditions)

    XCTAssertEqual(action, .showPicker(options: [.scanNFC, .scanQR]))
  }

  func testDetermineStopActionOnlyTimerReturnsCannotStop() {
    var conditions = ProfileStopConditions()
    conditions.timer = true

    let action = StrategyManager.determineStopAction(for: conditions)

    if case .cannotStop = action {
      // pass
    } else {
      XCTFail("Expected .cannotStop, got \(action)")
    }
  }

  func testDetermineStopActionOnlyScheduleReturnsCannotStop() {
    var conditions = ProfileStopConditions()
    conditions.schedule = true

    let action = StrategyManager.determineStopAction(for: conditions)

    if case .cannotStop = action {
      // pass
    } else {
      XCTFail("Expected .cannotStop, got \(action)")
    }
  }

  func testDetermineStopActionEmptyConditionsReturnsCannotStop() {
    let conditions = ProfileStopConditions()

    let action = StrategyManager.determineStopAction(for: conditions)

    if case .cannotStop = action {
      // pass
    } else {
      XCTFail("Expected .cannotStop, got \(action)")
    }
  }

  func testDetermineStopActionManualOverridesEverything() {
    var conditions = ProfileStopConditions()
    conditions.manual = true
    conditions.anyNFC = true
    conditions.anyQR = true
    conditions.timer = true
    conditions.schedule = true

    let action = StrategyManager.determineStopAction(for: conditions)

    XCTAssertEqual(action, .stopImmediately)
  }
}
