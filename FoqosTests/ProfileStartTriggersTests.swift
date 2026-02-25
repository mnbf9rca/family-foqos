// FoqosTests/ProfileStartTriggersTests.swift
import XCTest

@testable import FamilyFoqos

final class ProfileStartTriggersTests: XCTestCase {

  func testGivenNewTriggers_WhenCheckingDefaults_ThenAllFalse() {
    let triggers = ProfileStartTriggers()
    XCTAssertFalse(triggers.manual)
    XCTAssertFalse(triggers.anyNFC)
    XCTAssertFalse(triggers.specificNFC)
    XCTAssertFalse(triggers.anyQR)
    XCTAssertFalse(triggers.specificQR)
    XCTAssertFalse(triggers.schedule)
    XCTAssertFalse(triggers.deepLink)
  }

  func testGivenAnyNFCTrue_WhenCheckingHasNFC_ThenReturnsTrue() {
    var triggers = ProfileStartTriggers()
    triggers.anyNFC = true
    XCTAssertTrue(triggers.hasNFC)
  }

  func testGivenSpecificNFCTrue_WhenCheckingHasNFC_ThenReturnsTrue() {
    var triggers = ProfileStartTriggers()
    triggers.specificNFC = true
    XCTAssertTrue(triggers.hasNFC)
  }

  func testGivenAnyQRTrue_WhenCheckingHasQR_ThenReturnsTrue() {
    var triggers = ProfileStartTriggers()
    triggers.anyQR = true
    XCTAssertTrue(triggers.hasQR)
  }

  func testGivenSpecificQRTrue_WhenCheckingHasQR_ThenReturnsTrue() {
    var triggers = ProfileStartTriggers()
    triggers.specificQR = true
    XCTAssertTrue(triggers.hasQR)
  }

  func testGivenNoTriggersSet_WhenCheckingIsValid_ThenReturnsFalse() {
    let triggers = ProfileStartTriggers()
    XCTAssertFalse(triggers.isValid)
  }

  func testGivenManualTriggerSet_WhenCheckingIsValid_ThenReturnsTrue() {
    var triggers = ProfileStartTriggers()
    triggers.manual = true
    XCTAssertTrue(triggers.isValid)
  }

  func testGivenTriggersWithValues_WhenEncodingAndDecoding_ThenRoundTrips() throws {
    var original = ProfileStartTriggers()
    original.manual = true
    original.anyNFC = true
    original.schedule = true

    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(ProfileStartTriggers.self, from: data)

    XCTAssertEqual(original, decoded)
  }
}
