// FoqosTests/TriggerPickerOptionsTests.swift
import XCTest

@testable import FamilyFoqos

final class TriggerPickerOptionsTests: XCTestCase {

  // MARK: - NFCStartOption from triggers

  func testGivenBothNFCFlagsFalse_WhenGettingNFCStartOption_ThenReturnsNone() {
    let triggers = ProfileStartTriggers()
    XCTAssertEqual(NFCStartOption.from(triggers), .none)
  }

  func testGivenAnyNFCTrue_WhenGettingNFCStartOption_ThenReturnsAny() {
    var triggers = ProfileStartTriggers()
    triggers.anyNFC = true
    XCTAssertEqual(NFCStartOption.from(triggers), .any)
  }

  func testGivenSpecificNFCTrue_WhenGettingNFCStartOption_ThenReturnsSpecific() {
    var triggers = ProfileStartTriggers()
    triggers.specificNFC = true
    XCTAssertEqual(NFCStartOption.from(triggers), .specific)
  }

  func testGivenBothNFCFlagsTrue_WhenGettingNFCStartOption_ThenAnyWins() {
    var triggers = ProfileStartTriggers()
    triggers.anyNFC = true
    triggers.specificNFC = true
    XCTAssertEqual(NFCStartOption.from(triggers), .any)
  }

  // MARK: - NFCStartOption apply to triggers

  func testGivenNFCStartOptionNone_WhenApplying_ThenClearsBothFlags() {
    var triggers = ProfileStartTriggers()
    triggers.anyNFC = true
    NFCStartOption.none.apply(to: &triggers)
    XCTAssertFalse(triggers.anyNFC)
    XCTAssertFalse(triggers.specificNFC)
  }

  func testGivenNFCStartOptionAny_WhenApplying_ThenSetsAnyNFCTrue() {
    var triggers = ProfileStartTriggers()
    NFCStartOption.any.apply(to: &triggers)
    XCTAssertTrue(triggers.anyNFC)
    XCTAssertFalse(triggers.specificNFC)
  }

  func testGivenNFCStartOptionSpecific_WhenApplying_ThenSetsSpecificNFCTrue() {
    var triggers = ProfileStartTriggers()
    NFCStartOption.specific.apply(to: &triggers)
    XCTAssertFalse(triggers.anyNFC)
    XCTAssertTrue(triggers.specificNFC)
  }

  // MARK: - QRStartOption from triggers

  func testGivenBothQRFlagsFalse_WhenGettingQRStartOption_ThenReturnsNone() {
    let triggers = ProfileStartTriggers()
    XCTAssertEqual(QRStartOption.from(triggers), .none)
  }

  func testGivenAnyQRTrue_WhenGettingQRStartOption_ThenReturnsAny() {
    var triggers = ProfileStartTriggers()
    triggers.anyQR = true
    XCTAssertEqual(QRStartOption.from(triggers), .any)
  }

  func testGivenSpecificQRTrue_WhenGettingQRStartOption_ThenReturnsSpecific() {
    var triggers = ProfileStartTriggers()
    triggers.specificQR = true
    XCTAssertEqual(QRStartOption.from(triggers), .specific)
  }

  func testGivenBothQRFlagsTrue_WhenGettingQRStartOption_ThenAnyWins() {
    var triggers = ProfileStartTriggers()
    triggers.anyQR = true
    triggers.specificQR = true
    XCTAssertEqual(QRStartOption.from(triggers), .any)
  }

  // MARK: - QRStartOption apply to triggers

  func testGivenQRStartOptionNone_WhenApplying_ThenClearsBothFlags() {
    var triggers = ProfileStartTriggers()
    triggers.anyQR = true
    QRStartOption.none.apply(to: &triggers)
    XCTAssertFalse(triggers.anyQR)
    XCTAssertFalse(triggers.specificQR)
  }

  func testGivenQRStartOptionAny_WhenApplying_ThenSetsAnyQRTrue() {
    var triggers = ProfileStartTriggers()
    QRStartOption.any.apply(to: &triggers)
    XCTAssertTrue(triggers.anyQR)
    XCTAssertFalse(triggers.specificQR)
  }

  func testGivenQRStartOptionSpecific_WhenApplying_ThenSetsSpecificQRTrue() {
    var triggers = ProfileStartTriggers()
    QRStartOption.specific.apply(to: &triggers)
    XCTAssertFalse(triggers.anyQR)
    XCTAssertTrue(triggers.specificQR)
  }

  // MARK: - NFCStopOption from conditions

  func testGivenAllNFCStopFlagsFalse_WhenGettingNFCStopOption_ThenReturnsNone() {
    let conditions = ProfileStopConditions()
    XCTAssertEqual(NFCStopOption.from(conditions), .none)
  }

  func testGivenAnyNFCStopTrue_WhenGettingNFCStopOption_ThenReturnsAny() {
    var conditions = ProfileStopConditions()
    conditions.anyNFC = true
    XCTAssertEqual(NFCStopOption.from(conditions), .any)
  }

  func testGivenSameNFCTrue_WhenGettingNFCStopOption_ThenReturnsSame() {
    var conditions = ProfileStopConditions()
    conditions.sameNFC = true
    XCTAssertEqual(NFCStopOption.from(conditions), .same)
  }

  func testGivenSpecificNFCStopTrue_WhenGettingNFCStopOption_ThenReturnsSpecific() {
    var conditions = ProfileStopConditions()
    conditions.specificNFC = true
    XCTAssertEqual(NFCStopOption.from(conditions), .specific)
  }

  func testGivenSameAndAnyNFCTrue_WhenGettingNFCStopOption_ThenSameWins() {
    // same is more specific than any, matching canStop precedence
    var conditions = ProfileStopConditions()
    conditions.anyNFC = true
    conditions.sameNFC = true
    XCTAssertEqual(NFCStopOption.from(conditions), .same)
  }

  func testGivenSpecificAndSameNFCTrue_WhenGettingNFCStopOption_ThenSpecificWins() {
    // specific is highest priority, matching canStop precedence
    var conditions = ProfileStopConditions()
    conditions.sameNFC = true
    conditions.specificNFC = true
    XCTAssertEqual(NFCStopOption.from(conditions), .specific)
  }

  // MARK: - NFCStopOption apply to conditions

  func testGivenNFCStopOptionNone_WhenApplying_ThenClearsAllFlags() {
    var conditions = ProfileStopConditions()
    conditions.anyNFC = true
    NFCStopOption.none.apply(to: &conditions)
    XCTAssertFalse(conditions.anyNFC)
    XCTAssertFalse(conditions.sameNFC)
    XCTAssertFalse(conditions.specificNFC)
  }

  func testGivenNFCStopOptionAny_WhenApplying_ThenSetsAnyNFCTrue() {
    var conditions = ProfileStopConditions()
    NFCStopOption.any.apply(to: &conditions)
    XCTAssertTrue(conditions.anyNFC)
    XCTAssertFalse(conditions.sameNFC)
    XCTAssertFalse(conditions.specificNFC)
  }

  func testGivenNFCStopOptionSame_WhenApplying_ThenSetsSameNFCTrue() {
    var conditions = ProfileStopConditions()
    NFCStopOption.same.apply(to: &conditions)
    XCTAssertFalse(conditions.anyNFC)
    XCTAssertTrue(conditions.sameNFC)
    XCTAssertFalse(conditions.specificNFC)
  }

  func testGivenNFCStopOptionSpecific_WhenApplying_ThenSetsSpecificNFCTrue() {
    var conditions = ProfileStopConditions()
    NFCStopOption.specific.apply(to: &conditions)
    XCTAssertFalse(conditions.anyNFC)
    XCTAssertFalse(conditions.sameNFC)
    XCTAssertTrue(conditions.specificNFC)
  }

  // MARK: - QRStopOption from conditions

  func testGivenAllQRStopFlagsFalse_WhenGettingQRStopOption_ThenReturnsNone() {
    let conditions = ProfileStopConditions()
    XCTAssertEqual(QRStopOption.from(conditions), .none)
  }

  func testGivenAnyQRStopTrue_WhenGettingQRStopOption_ThenReturnsAny() {
    var conditions = ProfileStopConditions()
    conditions.anyQR = true
    XCTAssertEqual(QRStopOption.from(conditions), .any)
  }

  func testGivenSameQRTrue_WhenGettingQRStopOption_ThenReturnsSame() {
    var conditions = ProfileStopConditions()
    conditions.sameQR = true
    XCTAssertEqual(QRStopOption.from(conditions), .same)
  }

  func testGivenSpecificQRStopTrue_WhenGettingQRStopOption_ThenReturnsSpecific() {
    var conditions = ProfileStopConditions()
    conditions.specificQR = true
    XCTAssertEqual(QRStopOption.from(conditions), .specific)
  }

  func testGivenSameAndAnyQRTrue_WhenGettingQRStopOption_ThenSameWins() {
    // same is more specific than any, matching canStop precedence
    var conditions = ProfileStopConditions()
    conditions.anyQR = true
    conditions.sameQR = true
    XCTAssertEqual(QRStopOption.from(conditions), .same)
  }

  func testGivenSpecificAndSameQRTrue_WhenGettingQRStopOption_ThenSpecificWins() {
    // specific is highest priority, matching canStop precedence
    var conditions = ProfileStopConditions()
    conditions.sameQR = true
    conditions.specificQR = true
    XCTAssertEqual(QRStopOption.from(conditions), .specific)
  }

  // MARK: - QRStopOption apply to conditions

  func testGivenQRStopOptionNone_WhenApplying_ThenClearsAllFlags() {
    var conditions = ProfileStopConditions()
    conditions.anyQR = true
    QRStopOption.none.apply(to: &conditions)
    XCTAssertFalse(conditions.anyQR)
    XCTAssertFalse(conditions.sameQR)
    XCTAssertFalse(conditions.specificQR)
  }

  func testGivenQRStopOptionAny_WhenApplying_ThenSetsAnyQRTrue() {
    var conditions = ProfileStopConditions()
    QRStopOption.any.apply(to: &conditions)
    XCTAssertTrue(conditions.anyQR)
    XCTAssertFalse(conditions.sameQR)
    XCTAssertFalse(conditions.specificQR)
  }

  func testGivenQRStopOptionSame_WhenApplying_ThenSetsSameQRTrue() {
    var conditions = ProfileStopConditions()
    QRStopOption.same.apply(to: &conditions)
    XCTAssertFalse(conditions.anyQR)
    XCTAssertTrue(conditions.sameQR)
    XCTAssertFalse(conditions.specificQR)
  }

  func testGivenQRStopOptionSpecific_WhenApplying_ThenSetsSpecificQRTrue() {
    var conditions = ProfileStopConditions()
    QRStopOption.specific.apply(to: &conditions)
    XCTAssertFalse(conditions.anyQR)
    XCTAssertFalse(conditions.sameQR)
    XCTAssertTrue(conditions.specificQR)
  }

  // MARK: - NFCStopOption available options

  func testGivenNoNFCStart_WhenGettingAvailableNFCStopOptions_ThenExcludesSame() {
    let start = ProfileStartTriggers()
    let options = NFCStopOption.availableOptions(forStart: start)
    XCTAssertEqual(options, [.none, .any, .specific])
    XCTAssertFalse(options.contains(.same))
  }

  func testGivenAnyNFCStart_WhenGettingAvailableNFCStopOptions_ThenIncludesSame() {
    var start = ProfileStartTriggers()
    start.anyNFC = true
    let options = NFCStopOption.availableOptions(forStart: start)
    XCTAssertEqual(options, [.none, .any, .same, .specific])
  }

  func testGivenSpecificNFCStart_WhenGettingAvailableNFCStopOptions_ThenIncludesSame() {
    var start = ProfileStartTriggers()
    start.specificNFC = true
    let options = NFCStopOption.availableOptions(forStart: start)
    XCTAssertEqual(options, [.none, .any, .same, .specific])
  }

  // MARK: - QRStopOption available options

  func testGivenNoQRStart_WhenGettingAvailableQRStopOptions_ThenExcludesSame() {
    let start = ProfileStartTriggers()
    let options = QRStopOption.availableOptions(forStart: start)
    XCTAssertEqual(options, [.none, .any, .specific])
  }

  func testGivenAnyQRStart_WhenGettingAvailableQRStopOptions_ThenIncludesSame() {
    var start = ProfileStartTriggers()
    start.anyQR = true
    let options = QRStopOption.availableOptions(forStart: start)
    XCTAssertEqual(options, [.none, .any, .same, .specific])
  }

  func testGivenSpecificQRStart_WhenGettingAvailableQRStopOptions_ThenIncludesSame() {
    var start = ProfileStartTriggers()
    start.specificQR = true
    let options = QRStopOption.availableOptions(forStart: start)
    XCTAssertEqual(options, [.none, .any, .same, .specific])
  }

  // MARK: - Display labels

  func testGivenNFCStartOptions_WhenGettingLabels_ThenReturnsExpectedStrings() {
    XCTAssertEqual(NFCStartOption.none.label, "None")
    XCTAssertEqual(NFCStartOption.any.label, "Any tag")
    XCTAssertEqual(NFCStartOption.specific.label, "Specific tag")
  }

  func testGivenNFCStopOptions_WhenGettingLabels_ThenReturnsExpectedStrings() {
    XCTAssertEqual(NFCStopOption.none.label, "None")
    XCTAssertEqual(NFCStopOption.any.label, "Any tag")
    XCTAssertEqual(NFCStopOption.same.label, "Same tag")
    XCTAssertEqual(NFCStopOption.specific.label, "Specific tag")
  }

  func testGivenQRStartOptions_WhenGettingLabels_ThenReturnsExpectedStrings() {
    XCTAssertEqual(QRStartOption.none.label, "None")
    XCTAssertEqual(QRStartOption.any.label, "Any code")
    XCTAssertEqual(QRStartOption.specific.label, "Specific code")
  }

  func testGivenQRStopOptions_WhenGettingLabels_ThenReturnsExpectedStrings() {
    XCTAssertEqual(QRStopOption.none.label, "None")
    XCTAssertEqual(QRStopOption.any.label, "Any code")
    XCTAssertEqual(QRStopOption.same.label, "Same code")
    XCTAssertEqual(QRStopOption.specific.label, "Specific code")
  }
}
