import FoqosShared
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

  @MainActor
  func testOldLinkStopNeverAuthorizesV2Completion() throws {
    let old = try JSONDecoder().decode(ProfileStopConditions.self, from: Data("{\"deepLink\":true}".utf8))
    XCTAssertFalse(old.isValid)
    XCTAssertFalse(
      StartStopActionResolver.canStop(
        with: .deepLink, conditions: old, sessionTag: nil,
        stopNFCTagIds: [], stopQRCodeIds: []
      ).allowed)
    XCTAssertTrue(
      StartStopActionResolver.canStop(
        with: .deepLink, conditions: old, sessionTag: nil,
        stopNFCTagIds: [], stopQRCodeIds: [], legacySession: true
      ).allowed)
    let combined = try JSONDecoder().decode(ProfileStopConditions.self, from: Data("{\"manual\":true,\"deepLink\":true}".utf8))
    XCTAssertTrue(combined.isValid)
    XCTAssertFalse(
      StartStopActionResolver.canStop(
        with: .deepLink, conditions: combined, sessionTag: nil,
        stopNFCTagIds: [], stopQRCodeIds: []
      ).allowed)
    XCTAssertTrue(
      StartStopActionResolver.canStop(
        with: .manual, conditions: combined, sessionTag: nil,
        stopNFCTagIds: [], stopQRCodeIds: []
      ).allowed)
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
  func testLegacyTripletsNormalizeIndependently() throws {
    let expected = ["none", "any", "same", "same", "specific", "specific", "specific", "specific"]
    for bits in 0..<8 {
      for modality in ["NFC", "QR"] {
        let flags: [String: Bool] = [
          "any\(modality)": bits & 1 != 0,
          "same\(modality)": bits & 2 != 0,
          "specific\(modality)": bits & 4 != 0,
        ]
        let data = try legacyFixture(flags)
        let decoded = try JSONDecoder().decode(ProfileStopConditions.self, from: data)
        let encoded = try JSONEncoder().encode(decoded)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(json[modality == "NFC" ? "nfc" : "qr"] as? String, expected[bits])
        XCTAssertEqual(json[modality == "NFC" ? "qr" : "nfc"] as? String, "none")
        for key in ["anyNFC", "sameNFC", "specificNFC", "anyQR", "sameQR", "specificQR"] {
          XCTAssertNil(json[key])
        }
      }
    }
  }

  func testCanonicalKindWinsAndMalformedKindThrows() throws {
    for modality in ["nfc", "qr"] {
      let legacy = modality == "nfc" ? "anyNFC" : "anyQR"
      let data = try legacyFixture([modality: "specific", legacy: true])
      let decoded = try JSONDecoder().decode(ProfileStopConditions.self, from: data)
      XCTAssertTrue(modality == "nfc" ? decoded.specificNFC : decoded.specificQR)
      XCTAssertFalse(modality == "nfc" ? decoded.anyNFC : decoded.anyQR)
      for value: Any in [NSNull(), "unknown", 42, true] {
        let bad = try legacyFixture([modality: value, legacy: true])
        XCTAssertThrowsError(try JSONDecoder().decode(ProfileStopConditions.self, from: bad))
      }
      for value: Any in ["true", NSNull(), 42] {
        let badFlag = try legacyFixture([legacy: value])
        XCTAssertThrowsError(try JSONDecoder().decode(ProfileStopConditions.self, from: badFlag))
      }
    }
  }

  func testTimerSettingsRoundTripWithoutDefault() throws {
    for minutes in [37, 1439, 0, -1, 1440] {
      for allow in [true, false] {
        let data = try legacyFixture([
          "timer": true, "timerDurationMinutes": minutes, "allowChangingTimerBeforeStart": allow,
        ])
        let decoded = try JSONDecoder().decode(ProfileStopConditions.self, from: data)
        let encoded = try JSONEncoder().encode(decoded)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(json["timerDurationMinutes"] as? Int, minutes)
        XCTAssertEqual(json["allowChangingTimerBeforeStart"] as? Bool, allow)
      }
    }
    let absent = try JSONDecoder().decode(ProfileStopConditions.self, from: Data("{}".utf8))
    let absentJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(absent)) as? [String: Any])
    XCTAssertNil(absentJSON["timerDurationMinutes"])
    XCTAssertEqual(absentJSON["allowChangingTimerBeforeStart"] as? Bool, false)
    for raw in ["{\"timerDurationMinutes\":37.5}", "{\"timerDurationMinutes\":\"37\"}"] {
      XCTAssertThrowsError(try JSONDecoder().decode(ProfileStopConditions.self, from: Data(raw.utf8)))
    }
  }

  private func legacyFixture(_ fields: [String: Any]) throws -> Data {
    var json: [String: Any] = [
      "manual": false, "timer": false, "anyNFC": false, "specificNFC": false,
      "sameNFC": false, "anyQR": false, "specificQR": false, "sameQR": false,
      "schedule": false, "deepLink": false,
    ]
    json.merge(fields) { _, incoming in incoming }
    return try JSONSerialization.data(withJSONObject: json)
  }

}
