// FoqosTests/StrategyManagerStopTests.swift
import FoqosShared
import XCTest

@testable import FamilyFoqos

@MainActor
final class StrategyManagerStopTests: XCTestCase {

  func testGivenManualStopEnabled_WhenStoppingWithManual_ThenAllowed() {
    var stop = ProfileStopConditions()
    stop.manual = true

    let result = StartStopActionResolver.canStop(
      with: .manual,
      conditions: stop,
      sessionTag: nil,
      stopNFCTagId: nil,
      stopQRCodeId: nil
    )

    XCTAssertTrue(result.allowed)
  }

  func testGivenManualStopDisabled_WhenStoppingWithManual_ThenNotAllowed() {
    var stop = ProfileStopConditions()
    stop.timer = true

    let result = StartStopActionResolver.canStop(
      with: .manual,
      conditions: stop,
      sessionTag: nil,
      stopNFCTagId: nil,
      stopQRCodeId: nil
    )

    XCTAssertFalse(result.allowed)
  }

  func testGivenAnyNFCEnabled_WhenStoppingWithNFC_ThenAllowed() {
    var stop = ProfileStopConditions()
    stop.anyNFC = true

    let result = StartStopActionResolver.canStop(
      with: .nfc(tag: "any-tag"),
      conditions: stop,
      sessionTag: nil,
      stopNFCTagId: nil,
      stopQRCodeId: nil
    )

    XCTAssertTrue(result.allowed)
  }

  func testGivenSpecificNFCEnabled_WhenStoppingWithMatchingTag_ThenAllowed() {
    var stop = ProfileStopConditions()
    stop.specificNFC = true

    let result = StartStopActionResolver.canStop(
      with: .nfc(tag: "required-tag"),
      conditions: stop,
      sessionTag: nil,
      stopNFCTagId: "required-tag",
      stopQRCodeId: nil
    )

    XCTAssertTrue(result.allowed)
  }

  func testGivenSpecificNFCEnabled_WhenStoppingWithWrongTag_ThenNotAllowed() {
    var stop = ProfileStopConditions()
    stop.specificNFC = true

    let result = StartStopActionResolver.canStop(
      with: .nfc(tag: "wrong-tag"),
      conditions: stop,
      sessionTag: nil,
      stopNFCTagId: "required-tag",
      stopQRCodeId: nil
    )

    XCTAssertFalse(result.allowed)
    XCTAssertNotNil(result.errorMessage)
  }

  func testGivenSameNFCEnabled_WhenStoppingWithMatchingSessionTag_ThenAllowed() {
    var stop = ProfileStopConditions()
    stop.sameNFC = true

    // Session tags are stored with "nfc:" prefix in production (via startWithNFCTag)
    let result = StartStopActionResolver.canStop(
      with: .nfc(tag: "session-tag"),
      conditions: stop,
      sessionTag: "nfc:session-tag",
      stopNFCTagId: nil,
      stopQRCodeId: nil
    )

    XCTAssertTrue(result.allowed)
  }

  func testGivenSameNFCEnabled_WhenStoppingWithDifferentTag_ThenNotAllowed() {
    var stop = ProfileStopConditions()
    stop.sameNFC = true

    let result = StartStopActionResolver.canStop(
      with: .nfc(tag: "different-tag"),
      conditions: stop,
      sessionTag: "nfc:original-tag",
      stopNFCTagId: nil,
      stopQRCodeId: nil
    )

    XCTAssertFalse(result.allowed)
    XCTAssertNotNil(result.errorMessage)
  }

  func testGivenSameQREnabled_WhenStoppingWithMatchingSessionTag_ThenAllowed() {
    var stop = ProfileStopConditions()
    stop.sameQR = true

    // Session tags are stored with "qr:" prefix in production (via startWithQRCode)
    let result = StartStopActionResolver.canStop(
      with: .qr(code: "session-code"),
      conditions: stop,
      sessionTag: "qr:session-code",
      stopNFCTagId: nil,
      stopQRCodeId: nil
    )

    XCTAssertTrue(result.allowed)
  }

  func testGivenSameQREnabled_WhenStoppingWithDifferentCode_ThenNotAllowed() {
    var stop = ProfileStopConditions()
    stop.sameQR = true

    let result = StartStopActionResolver.canStop(
      with: .qr(code: "different-code"),
      conditions: stop,
      sessionTag: "qr:original-code",
      stopNFCTagId: nil,
      stopQRCodeId: nil
    )

    XCTAssertFalse(result.allowed)
    XCTAssertNotNil(result.errorMessage)
  }

  // MARK: - determineStopAction Tests

  func testGivenManualAndNFC_WhenDeterminingStopAction_ThenStopImmediately() {
    var conditions = ProfileStopConditions()
    conditions.manual = true
    conditions.anyNFC = true  // Even with NFC, manual wins

    let action = StartStopActionResolver.determineStopAction(for: conditions)

    XCTAssertEqual(action, .stopImmediately)
  }

  func testGivenOnlyAnyNFC_WhenDeterminingStopAction_ThenScanNFC() {
    var conditions = ProfileStopConditions()
    conditions.anyNFC = true

    let action = StartStopActionResolver.determineStopAction(for: conditions)

    XCTAssertEqual(action, .scanNFC)
  }

  func testGivenOnlySameNFC_WhenDeterminingStopAction_ThenScanNFC() {
    var conditions = ProfileStopConditions()
    conditions.sameNFC = true

    let action = StartStopActionResolver.determineStopAction(for: conditions)

    XCTAssertEqual(action, .scanNFC)
  }

  func testGivenOnlySpecificNFC_WhenDeterminingStopAction_ThenScanNFC() {
    var conditions = ProfileStopConditions()
    conditions.specificNFC = true

    let action = StartStopActionResolver.determineStopAction(for: conditions)

    XCTAssertEqual(action, .scanNFC)
  }

  func testGivenOnlyAnyQR_WhenDeterminingStopAction_ThenScanQR() {
    var conditions = ProfileStopConditions()
    conditions.anyQR = true

    let action = StartStopActionResolver.determineStopAction(for: conditions)

    XCTAssertEqual(action, .scanQR)
  }

  func testGivenOnlySameQR_WhenDeterminingStopAction_ThenScanQR() {
    var conditions = ProfileStopConditions()
    conditions.sameQR = true

    let action = StartStopActionResolver.determineStopAction(for: conditions)

    XCTAssertEqual(action, .scanQR)
  }

  func testGivenOnlySpecificQR_WhenDeterminingStopAction_ThenScanQR() {
    var conditions = ProfileStopConditions()
    conditions.specificQR = true

    let action = StartStopActionResolver.determineStopAction(for: conditions)

    XCTAssertEqual(action, .scanQR)
  }

  func testGivenNFCAndQR_WhenDeterminingStopAction_ThenShowPicker() {
    var conditions = ProfileStopConditions()
    conditions.anyNFC = true
    conditions.anyQR = true

    let action = StartStopActionResolver.determineStopAction(for: conditions)

    XCTAssertEqual(action, .showPicker(options: [.scanNFC, .scanQR]))
  }

  func testGivenOnlyTimer_WhenDeterminingStopAction_ThenCannotStop() {
    var conditions = ProfileStopConditions()
    conditions.timer = true

    let action = StartStopActionResolver.determineStopAction(for: conditions)

    if case .cannotStop = action {
      // pass
    } else {
      XCTFail("Expected .cannotStop, got \(action)")
    }
  }

  func testGivenOnlySchedule_WhenDeterminingStopAction_ThenCannotStop() {
    var conditions = ProfileStopConditions()
    conditions.schedule = true

    let action = StartStopActionResolver.determineStopAction(for: conditions)

    if case .cannotStop = action {
      // pass
    } else {
      XCTFail("Expected .cannotStop, got \(action)")
    }
  }

  func testGivenEmptyConditions_WhenDeterminingStopAction_ThenCannotStop() {
    let conditions = ProfileStopConditions()

    let action = StartStopActionResolver.determineStopAction(for: conditions)

    if case .cannotStop = action {
      // pass
    } else {
      XCTFail("Expected .cannotStop, got \(action)")
    }
  }

  func testGivenAllConditionsEnabled_WhenDeterminingStopAction_ThenManualOverrides() {
    var conditions = ProfileStopConditions()
    conditions.manual = true
    conditions.anyNFC = true
    conditions.anyQR = true
    conditions.timer = true
    conditions.schedule = true

    let action = StartStopActionResolver.determineStopAction(for: conditions)

    XCTAssertEqual(action, .stopImmediately)
  }
}
