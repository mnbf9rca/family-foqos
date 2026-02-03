// FoqosTests/TriggerValidatorTests.swift
import XCTest

@testable import FamilyFoqos

final class TriggerValidatorTests: XCTestCase {
  var validator: TriggerValidator!

  override func setUp() {
    super.setUp()
    validator = TriggerValidator()
  }

  // MARK: - Stop Availability

  func testSameNFCAvailableWhenAnyNFCStart() {
    var start = ProfileStartTriggers()
    start.anyNFC = true
    XCTAssertTrue(validator.isStopAvailable(.sameNFC, forStart: start))
  }

  func testSameNFCAvailableWhenSpecificNFCStart() {
    var start = ProfileStartTriggers()
    start.specificNFC = true
    XCTAssertTrue(validator.isStopAvailable(.sameNFC, forStart: start))
  }

  func testSameNFCNotAvailableWhenNoNFCStart() {
    var start = ProfileStartTriggers()
    start.manual = true
    XCTAssertFalse(validator.isStopAvailable(.sameNFC, forStart: start))
  }

  func testSameQRAvailableWhenAnyQRStart() {
    var start = ProfileStartTriggers()
    start.anyQR = true
    XCTAssertTrue(validator.isStopAvailable(.sameQR, forStart: start))
  }

  func testSameQRNotAvailableWhenNoQRStart() {
    var start = ProfileStartTriggers()
    start.manual = true
    XCTAssertFalse(validator.isStopAvailable(.sameQR, forStart: start))
  }

  func testManualStopAlwaysAvailable() {
    let start = ProfileStartTriggers()
    XCTAssertTrue(validator.isStopAvailable(.manual, forStart: start))
  }

  func testTimerStopAlwaysAvailable() {
    let start = ProfileStartTriggers()
    XCTAssertTrue(validator.isStopAvailable(.timer, forStart: start))
  }

  // MARK: - Unavailability Reasons

  func testSameNFCUnavailabilityReason() {
    var start = ProfileStartTriggers()
    start.manual = true
    let reason = validator.unavailabilityReason(.sameNFC, forStart: start)
    XCTAssertNotNil(reason)
    XCTAssertTrue(reason!.contains("NFC"))
  }

  func testSameQRUnavailabilityReason() {
    var start = ProfileStartTriggers()
    start.manual = true
    let reason = validator.unavailabilityReason(.sameQR, forStart: start)
    XCTAssertNotNil(reason)
    XCTAssertTrue(reason!.contains("QR"))
  }

  func testNoReasonWhenAvailable() {
    var start = ProfileStartTriggers()
    start.anyNFC = true
    XCTAssertNil(validator.unavailabilityReason(.sameNFC, forStart: start))
  }

  // MARK: - Auto-Fix

  func testAutoFixRemovesSameNFCWhenNoNFCStart() {
    var start = ProfileStartTriggers()
    start.manual = true
    var stop = ProfileStopConditions()
    stop.sameNFC = true

    validator.autoFix(start: start, stop: &stop)

    XCTAssertFalse(stop.sameNFC)
  }

  func testAutoFixRemovesSameQRWhenNoQRStart() {
    var start = ProfileStartTriggers()
    start.manual = true
    var stop = ProfileStopConditions()
    stop.sameQR = true

    validator.autoFix(start: start, stop: &stop)

    XCTAssertFalse(stop.sameQR)
  }

  func testAutoFixPreservesSameNFCWhenNFCStart() {
    var start = ProfileStartTriggers()
    start.anyNFC = true
    var stop = ProfileStopConditions()
    stop.sameNFC = true

    validator.autoFix(start: start, stop: &stop)

    XCTAssertTrue(stop.sameNFC)
  }

  // MARK: - Validation Errors

  func testValidateReturnsErrorWhenNoStartTrigger() {
    let start = ProfileStartTriggers()
    var stop = ProfileStopConditions()
    stop.manual = true

    let errors = validator.validate(start: start, stop: stop)

    XCTAssertTrue(errors.contains { $0.contains("start trigger") })
  }

  func testValidateReturnsErrorWhenNoStopCondition() {
    var start = ProfileStartTriggers()
    start.manual = true
    let stop = ProfileStopConditions()

    let errors = validator.validate(start: start, stop: stop)

    XCTAssertTrue(errors.contains { $0.contains("stop condition") })
  }

  func testValidateReturnsNoErrorsWhenValid() {
    var start = ProfileStartTriggers()
    start.manual = true
    var stop = ProfileStopConditions()
    stop.manual = true

    let errors = validator.validate(start: start, stop: stop)

    XCTAssertTrue(errors.isEmpty)
  }
}
