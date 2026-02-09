// FoqosTests/ProfileStartTriggersTests.swift
import XCTest

@testable import FamilyFoqos

final class ProfileStartTriggersTests: XCTestCase {

  func testDefaultTriggersAreAllFalse() {
    let triggers = ProfileStartTriggers()
    XCTAssertFalse(triggers.manual)
    XCTAssertFalse(triggers.anyNFC)
    XCTAssertFalse(triggers.specificNFC)
    XCTAssertFalse(triggers.anyQR)
    XCTAssertFalse(triggers.specificQR)
    XCTAssertFalse(triggers.schedule)
    XCTAssertFalse(triggers.deepLink)
  }

  func testHasNFCReturnsTrueForAnyNFC() {
    var triggers = ProfileStartTriggers()
    triggers.anyNFC = true
    XCTAssertTrue(triggers.hasNFC)
  }

  func testHasNFCReturnsTrueForSpecificNFC() {
    var triggers = ProfileStartTriggers()
    triggers.specificNFC = true
    XCTAssertTrue(triggers.hasNFC)
  }

  func testHasQRReturnsTrueForAnyQR() {
    var triggers = ProfileStartTriggers()
    triggers.anyQR = true
    XCTAssertTrue(triggers.hasQR)
  }

  func testHasQRReturnsTrueForSpecificQR() {
    var triggers = ProfileStartTriggers()
    triggers.specificQR = true
    XCTAssertTrue(triggers.hasQR)
  }

  func testIsValidReturnsFalseWhenEmpty() {
    let triggers = ProfileStartTriggers()
    XCTAssertFalse(triggers.isValid)
  }

  func testIsValidReturnsTrueWhenManualSet() {
    var triggers = ProfileStartTriggers()
    triggers.manual = true
    XCTAssertTrue(triggers.isValid)
  }

  func testCodableRoundTrip() throws {
    var original = ProfileStartTriggers()
    original.manual = true
    original.anyNFC = true
    original.schedule = true

    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(ProfileStartTriggers.self, from: data)

    XCTAssertEqual(original, decoded)
  }
}
