// FoqosTests/ProfileStopConditionsTests.swift
import XCTest

@testable import FamilyFoqos

final class ProfileStopConditionsTests: XCTestCase {

  func testDefaultConditionsAreAllFalse() {
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

  func testIsValidReturnsFalseWhenEmpty() {
    let conditions = ProfileStopConditions()
    XCTAssertFalse(conditions.isValid)
  }

  func testIsValidReturnsTrueWhenManualSet() {
    var conditions = ProfileStopConditions()
    conditions.manual = true
    XCTAssertTrue(conditions.isValid)
  }

  func testIsValidReturnsTrueWhenTimerSet() {
    var conditions = ProfileStopConditions()
    conditions.timer = true
    XCTAssertTrue(conditions.isValid)
  }

  func testCodableRoundTrip() throws {
    var original = ProfileStopConditions()
    original.manual = true
    original.sameNFC = true
    original.timer = true

    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(ProfileStopConditions.self, from: data)

    XCTAssertEqual(original, decoded)
  }
}
