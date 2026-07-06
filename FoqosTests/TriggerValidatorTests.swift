// FoqosTests/TriggerValidatorTests.swift
import FoqosShared
import XCTest

@testable import FamilyFoqos

final class TriggerValidatorTests: XCTestCase {
  let validator = TriggerValidator()

  // MARK: - Stop Availability

  func testGivenAnyNFCStart_WhenCheckingSameNFCAvailable_ThenReturnsTrue() {
    var start = ProfileStartTriggers()
    start.anyNFC = true
    XCTAssertTrue(validator.isStopAvailable(.sameNFC, forStart: start))
  }

  func testGivenSpecificNFCStart_WhenCheckingSameNFCAvailable_ThenReturnsTrue() {
    var start = ProfileStartTriggers()
    start.specificNFC = true
    XCTAssertTrue(validator.isStopAvailable(.sameNFC, forStart: start))
  }

  func testGivenNoNFCStart_WhenCheckingSameNFCAvailable_ThenReturnsFalse() {
    var start = ProfileStartTriggers()
    start.manual = true
    XCTAssertFalse(validator.isStopAvailable(.sameNFC, forStart: start))
  }

  func testGivenAnyQRStart_WhenCheckingSameQRAvailable_ThenReturnsTrue() {
    var start = ProfileStartTriggers()
    start.anyQR = true
    XCTAssertTrue(validator.isStopAvailable(.sameQR, forStart: start))
  }

  func testGivenNoQRStart_WhenCheckingSameQRAvailable_ThenReturnsFalse() {
    var start = ProfileStartTriggers()
    start.manual = true
    XCTAssertFalse(validator.isStopAvailable(.sameQR, forStart: start))
  }

  func testGivenAnyStartTrigger_WhenCheckingManualStopAvailable_ThenReturnsTrue() {
    let start = ProfileStartTriggers()
    XCTAssertTrue(validator.isStopAvailable(.manual, forStart: start))
  }

  func testGivenAnyStartTrigger_WhenCheckingTimerStopAvailable_ThenReturnsTrue() {
    let start = ProfileStartTriggers()
    XCTAssertTrue(validator.isStopAvailable(.timer, forStart: start))
  }

  // MARK: - Unavailability Reasons

  func testGivenNoNFCStart_WhenGettingSameNFCReason_ThenMentionsNFC() {
    var start = ProfileStartTriggers()
    start.manual = true
    let reason = validator.unavailabilityReason(.sameNFC, forStart: start)
    XCTAssertNotNil(reason)
    XCTAssertTrue(reason!.contains("NFC"))
  }

  func testGivenNoQRStart_WhenGettingSameQRReason_ThenMentionsQR() {
    var start = ProfileStartTriggers()
    start.manual = true
    let reason = validator.unavailabilityReason(.sameQR, forStart: start)
    XCTAssertNotNil(reason)
    XCTAssertTrue(reason!.contains("QR"))
  }

  func testGivenNFCStartEnabled_WhenGettingSameNFCReason_ThenReturnsNil() {
    var start = ProfileStartTriggers()
    start.anyNFC = true
    XCTAssertNil(validator.unavailabilityReason(.sameNFC, forStart: start))
  }

  // MARK: - Auto-Fix

  func testGivenNoNFCStart_WhenAutoFixing_ThenRemovesSameNFC() {
    var start = ProfileStartTriggers()
    start.manual = true
    var stop = ProfileStopConditions()
    stop.sameNFC = true

    validator.autoFix(start: start, stop: &stop)

    XCTAssertFalse(stop.sameNFC)
  }

  func testGivenNoQRStart_WhenAutoFixing_ThenRemovesSameQR() {
    var start = ProfileStartTriggers()
    start.manual = true
    var stop = ProfileStopConditions()
    stop.sameQR = true

    validator.autoFix(start: start, stop: &stop)

    XCTAssertFalse(stop.sameQR)
  }

  func testGivenNFCStartEnabled_WhenAutoFixing_ThenPreservesSameNFC() {
    var start = ProfileStartTriggers()
    start.anyNFC = true
    var stop = ProfileStopConditions()
    stop.sameNFC = true

    validator.autoFix(start: start, stop: &stop)

    XCTAssertTrue(stop.sameNFC)
  }

  // MARK: - Validation Errors

  func testGivenNoStartTrigger_WhenValidating_ThenReturnsStartError() {
    let start = ProfileStartTriggers()
    var stop = ProfileStopConditions()
    stop.manual = true

    let errors = validator.validate(start: start, stop: stop)

    XCTAssertTrue(errors.contains { $0.contains("start trigger") })
  }

  func testGivenNoStopCondition_WhenValidating_ThenReturnsStopError() {
    var start = ProfileStartTriggers()
    start.manual = true
    let stop = ProfileStopConditions()

    let errors = validator.validate(start: start, stop: stop)

    XCTAssertTrue(errors.contains { $0.contains("stop condition") })
  }

  func testGivenValidStartAndStop_WhenValidating_ThenReturnsNoErrors() {
    var start = ProfileStartTriggers()
    start.manual = true
    var stop = ProfileStopConditions()
    stop.manual = true

    let errors = validator.validate(start: start, stop: stop)

    XCTAssertTrue(errors.isEmpty)
  }
}
