// FoqosTests/StrategyManagerStopTests.swift
import XCTest

@testable import FamilyFoqos

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

    let result = StrategyManager.canStop(
      with: .nfc(tag: "session-tag"),
      conditions: stop,
      sessionTag: "session-tag",
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
      sessionTag: "original-tag",
      stopNFCTagId: nil,
      stopQRCodeId: nil
    )

    XCTAssertFalse(result.allowed)
    XCTAssertNotNil(result.errorMessage)
  }
}
