// FoqosTests/ProfileStopConditionsTests.swift
import XCTest

@testable import FamilyFoqos

final class ProfileStopConditionsTests: XCTestCase {

  func testGivenNewConditions_WhenCheckingDefaults_ThenAllFalse() {
    let conditions = ProfileStopConditions()
    XCTAssertFalse(conditions.manual)
    XCTAssertFalse(conditions.timer)
    XCTAssertFalse(conditions.anyNFC)
    XCTAssertFalse(conditions.specificNFC)
    XCTAssertFalse(conditions.sameNFC)
    XCTAssertFalse(conditions.anyQR)
    XCTAssertFalse(conditions.specificQR)
    XCTAssertFalse(conditions.sameQR)
    XCTAssertFalse(conditions.schedule)
    XCTAssertFalse(conditions.deepLink)
  }

  func testGivenEmptyConditions_WhenCheckingIsValid_ThenFalse() {
    let conditions = ProfileStopConditions()
    XCTAssertFalse(conditions.isValid)
  }

  func testGivenManualEnabled_WhenCheckingIsValid_ThenTrue() {
    var conditions = ProfileStopConditions()
    conditions.manual = true
    XCTAssertTrue(conditions.isValid)
  }

  func testGivenTimerEnabled_WhenCheckingIsValid_ThenTrue() {
    var conditions = ProfileStopConditions()
    conditions.timer = true
    XCTAssertTrue(conditions.isValid)
  }

  func testGivenConditionsWithMultipleFlags_WhenEncodingAndDecoding_ThenRoundTripsCorrectly() throws {
    var original = ProfileStopConditions()
    original.manual = true
    original.sameNFC = true
    original.timer = true

    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(ProfileStopConditions.self, from: data)

    XCTAssertEqual(original, decoded)
  }
}
