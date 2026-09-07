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
      stopNFCValues: [],
      stopQRValues: []
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
      stopNFCValues: [],
      stopQRValues: []
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
      stopNFCValues: [],
      stopQRValues: []
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
      stopNFCValues: ["required-tag"],
      stopQRValues: []
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
      stopNFCValues: ["required-tag"],
      stopQRValues: []
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
      stopNFCValues: [],
      stopQRValues: []
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
      stopNFCValues: [],
      stopQRValues: []
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
      stopNFCValues: [],
      stopQRValues: []
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
      stopNFCValues: [],
      stopQRValues: []
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
  func testSpecificKeysMatchAnyValueWithQRParity() {
    for isNFC in [true, false] {
      let conditions = ProfileStopConditions(specificNFC: isNFC, specificQR: !isNFC)
      for value in ["Y", "missing"] {
        let result = StartStopActionResolver.canStop(
          with: isNFC ? .nfc(tag: value) : .qr(code: value), conditions: conditions,
          sessionTag: nil, stopNFCValues: ["X", "Y"], stopQRValues: ["X", "Y"])
        XCTAssertEqual(result.allowed, value == "Y")
        XCTAssertEqual(result.errorMessage, value == "Y" ? nil : "Scan the correct \(isNFC ? "NFC tag" : "QR code") to stop")
      }
    }
  }

  func testSameKeyIgnoresSpareStopKeys() {
    for isNFC in [true, false] {
      let result = StartStopActionResolver.canStop(
        with: isNFC ? .nfc(tag: "Y") : .qr(code: "Y"),
        conditions: ProfileStopConditions(sameNFC: isNFC, sameQR: !isNFC),
        sessionTag: isNFC ? "nfc:X" : "qr:X", stopNFCValues: ["Y"], stopQRValues: ["Y"])
      XCTAssertFalse(result.allowed)
    }
  }

  func testSpecificQRMatchesRawPrimarySpareAndNormalizedKeys() {
    let payload = " \nHTTPS://EXAMPLE.COM/\t"
    for keys in [[QRCodeHasher.rawHash(payload)], ["unrelated", QRCodeHasher.rawHash(payload)], [QRCodeHasher.hash("https://example.com")]] {
      for scan in [payload, "different code"] {
        let result = StartStopActionResolver.canStop(
          with: .qr(code: QRCodeHasher.hash(scan), rawHash: QRCodeHasher.rawHash(scan)),
          conditions: ProfileStopConditions(specificQR: true), sessionTag: nil,
          stopNFCValues: [], stopQRValues: keys)
        XCTAssertEqual(result.allowed, scan == payload)
      }
    }
  }

  func testSameQRAcceptsOldRawSessionAndRejectsDifferentScan() {
    let payload = " HTTPS://EXAMPLE.COM/ "
    for scan in [payload, "different code"] {
      let result = StartStopActionResolver.canStop(
        with: .qr(code: QRCodeHasher.hash(scan), rawHash: QRCodeHasher.rawHash(scan)),
        conditions: ProfileStopConditions(sameQR: true),
        sessionTag: "qr:\(QRCodeHasher.rawHash(payload))", stopNFCValues: [], stopQRValues: [])
      XCTAssertEqual(result.allowed, scan == payload)
    }
  }

}
