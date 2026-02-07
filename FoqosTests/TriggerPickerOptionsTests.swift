// FoqosTests/TriggerPickerOptionsTests.swift
import XCTest

@testable import FamilyFoqos

final class TriggerPickerOptionsTests: XCTestCase {

  // MARK: - NFCStartOption from triggers

  func testNFCStartOptionNoneWhenBothFalse() {
    let triggers = ProfileStartTriggers()
    XCTAssertEqual(NFCStartOption.from(triggers), .none)
  }

  func testNFCStartOptionAnyWhenAnyNFC() {
    var triggers = ProfileStartTriggers()
    triggers.anyNFC = true
    XCTAssertEqual(NFCStartOption.from(triggers), .any)
  }

  func testNFCStartOptionSpecificWhenSpecificNFC() {
    var triggers = ProfileStartTriggers()
    triggers.specificNFC = true
    XCTAssertEqual(NFCStartOption.from(triggers), .specific)
  }

  func testNFCStartOptionAnyWinsBothTrue() {
    var triggers = ProfileStartTriggers()
    triggers.anyNFC = true
    triggers.specificNFC = true
    XCTAssertEqual(NFCStartOption.from(triggers), .any)
  }

  // MARK: - NFCStartOption apply to triggers

  func testNFCStartOptionNoneApply() {
    var triggers = ProfileStartTriggers()
    triggers.anyNFC = true
    NFCStartOption.none.apply(to: &triggers)
    XCTAssertFalse(triggers.anyNFC)
    XCTAssertFalse(triggers.specificNFC)
  }

  func testNFCStartOptionAnyApply() {
    var triggers = ProfileStartTriggers()
    NFCStartOption.any.apply(to: &triggers)
    XCTAssertTrue(triggers.anyNFC)
    XCTAssertFalse(triggers.specificNFC)
  }

  func testNFCStartOptionSpecificApply() {
    var triggers = ProfileStartTriggers()
    NFCStartOption.specific.apply(to: &triggers)
    XCTAssertFalse(triggers.anyNFC)
    XCTAssertTrue(triggers.specificNFC)
  }

  // MARK: - QRStartOption from triggers

  func testQRStartOptionNoneWhenBothFalse() {
    let triggers = ProfileStartTriggers()
    XCTAssertEqual(QRStartOption.from(triggers), .none)
  }

  func testQRStartOptionAnyWhenAnyQR() {
    var triggers = ProfileStartTriggers()
    triggers.anyQR = true
    XCTAssertEqual(QRStartOption.from(triggers), .any)
  }

  func testQRStartOptionSpecificWhenSpecificQR() {
    var triggers = ProfileStartTriggers()
    triggers.specificQR = true
    XCTAssertEqual(QRStartOption.from(triggers), .specific)
  }

  // MARK: - NFCStopOption from conditions

  func testNFCStopOptionNoneWhenAllFalse() {
    let conditions = ProfileStopConditions()
    XCTAssertEqual(NFCStopOption.from(conditions), .none)
  }

  func testNFCStopOptionAnyWhenAnyNFC() {
    var conditions = ProfileStopConditions()
    conditions.anyNFC = true
    XCTAssertEqual(NFCStopOption.from(conditions), .any)
  }

  func testNFCStopOptionSameWhenSameNFC() {
    var conditions = ProfileStopConditions()
    conditions.sameNFC = true
    XCTAssertEqual(NFCStopOption.from(conditions), .same)
  }

  func testNFCStopOptionSpecificWhenSpecificNFC() {
    var conditions = ProfileStopConditions()
    conditions.specificNFC = true
    XCTAssertEqual(NFCStopOption.from(conditions), .specific)
  }

  func testNFCStopOptionAnyWinsOverSame() {
    var conditions = ProfileStopConditions()
    conditions.anyNFC = true
    conditions.sameNFC = true
    XCTAssertEqual(NFCStopOption.from(conditions), .any)
  }

  // MARK: - NFCStopOption apply to conditions

  func testNFCStopOptionNoneApply() {
    var conditions = ProfileStopConditions()
    conditions.anyNFC = true
    NFCStopOption.none.apply(to: &conditions)
    XCTAssertFalse(conditions.anyNFC)
    XCTAssertFalse(conditions.sameNFC)
    XCTAssertFalse(conditions.specificNFC)
  }

  func testNFCStopOptionAnyApply() {
    var conditions = ProfileStopConditions()
    NFCStopOption.any.apply(to: &conditions)
    XCTAssertTrue(conditions.anyNFC)
    XCTAssertFalse(conditions.sameNFC)
    XCTAssertFalse(conditions.specificNFC)
  }

  func testNFCStopOptionSameApply() {
    var conditions = ProfileStopConditions()
    NFCStopOption.same.apply(to: &conditions)
    XCTAssertFalse(conditions.anyNFC)
    XCTAssertTrue(conditions.sameNFC)
    XCTAssertFalse(conditions.specificNFC)
  }

  func testNFCStopOptionSpecificApply() {
    var conditions = ProfileStopConditions()
    NFCStopOption.specific.apply(to: &conditions)
    XCTAssertFalse(conditions.anyNFC)
    XCTAssertFalse(conditions.sameNFC)
    XCTAssertTrue(conditions.specificNFC)
  }

  // MARK: - QRStopOption from conditions

  func testQRStopOptionNoneWhenAllFalse() {
    let conditions = ProfileStopConditions()
    XCTAssertEqual(QRStopOption.from(conditions), .none)
  }

  func testQRStopOptionAnyWhenAnyQR() {
    var conditions = ProfileStopConditions()
    conditions.anyQR = true
    XCTAssertEqual(QRStopOption.from(conditions), .any)
  }

  func testQRStopOptionSameWhenSameQR() {
    var conditions = ProfileStopConditions()
    conditions.sameQR = true
    XCTAssertEqual(QRStopOption.from(conditions), .same)
  }

  func testQRStopOptionSpecificWhenSpecificQR() {
    var conditions = ProfileStopConditions()
    conditions.specificQR = true
    XCTAssertEqual(QRStopOption.from(conditions), .specific)
  }

  // MARK: - NFCStopOption available options

  func testNFCStopAvailableOptionsWithNoNFCStart() {
    let start = ProfileStartTriggers()
    let options = NFCStopOption.availableOptions(forStart: start)
    XCTAssertEqual(options, [.none, .any, .specific])
    XCTAssertFalse(options.contains(.same))
  }

  func testNFCStopAvailableOptionsWithAnyNFCStart() {
    var start = ProfileStartTriggers()
    start.anyNFC = true
    let options = NFCStopOption.availableOptions(forStart: start)
    XCTAssertEqual(options, [.none, .any, .same, .specific])
  }

  func testNFCStopAvailableOptionsWithSpecificNFCStart() {
    var start = ProfileStartTriggers()
    start.specificNFC = true
    let options = NFCStopOption.availableOptions(forStart: start)
    XCTAssertEqual(options, [.none, .any, .same, .specific])
  }

  // MARK: - QRStopOption available options

  func testQRStopAvailableOptionsWithNoQRStart() {
    let start = ProfileStartTriggers()
    let options = QRStopOption.availableOptions(forStart: start)
    XCTAssertEqual(options, [.none, .any, .specific])
  }

  func testQRStopAvailableOptionsWithAnyQRStart() {
    var start = ProfileStartTriggers()
    start.anyQR = true
    let options = QRStopOption.availableOptions(forStart: start)
    XCTAssertEqual(options, [.none, .any, .same, .specific])
  }

  // MARK: - Display labels

  func testNFCStartOptionLabels() {
    XCTAssertEqual(NFCStartOption.none.label, "None")
    XCTAssertEqual(NFCStartOption.any.label, "Any tag")
    XCTAssertEqual(NFCStartOption.specific.label, "Specific tag")
  }

  func testNFCStopOptionLabels() {
    XCTAssertEqual(NFCStopOption.none.label, "None")
    XCTAssertEqual(NFCStopOption.any.label, "Any tag")
    XCTAssertEqual(NFCStopOption.same.label, "Same tag")
    XCTAssertEqual(NFCStopOption.specific.label, "Specific tag")
  }

  func testQRStartOptionLabels() {
    XCTAssertEqual(QRStartOption.none.label, "None")
    XCTAssertEqual(QRStartOption.any.label, "Any code")
    XCTAssertEqual(QRStartOption.specific.label, "Specific code")
  }

  func testQRStopOptionLabels() {
    XCTAssertEqual(QRStopOption.none.label, "None")
    XCTAssertEqual(QRStopOption.any.label, "Any code")
    XCTAssertEqual(QRStopOption.same.label, "Same code")
    XCTAssertEqual(QRStopOption.specific.label, "Specific code")
  }
}
