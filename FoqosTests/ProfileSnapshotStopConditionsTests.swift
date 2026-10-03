import FoqosShared
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class ProfileSnapshotStopConditionsTests: XCTestCase {
  private var container: ModelContainer!
  private var context: ModelContext!

  override func setUp() async throws {
    try await super.setUp()
    container = try TestModelContainer.create()
    context = container.mainContext
  }

  // #206/#236/#261: the extension must see the profile's stop conditions on the snapshot.
  func testGivenProfileWithNFCOnlyStop_WhenBuildingSnapshot_ThenStopConditionsCarried() throws {
    let profile = BlockedProfiles(name: "NFC only")
    profile.stopConditions = ProfileStopConditions(manual: false, anyNFC: true)
    context.insert(profile)
    try context.save()

    let snapshot = BlockedProfiles.getSnapshot(for: profile)

    XCTAssertEqual(snapshot.stopConditions?.manual, false, "manual not allowed is visible to extension")
    XCTAssertEqual(snapshot.stopConditions?.anyNFC, true)
  }

  // Codable back-compat: an older snapshot without the field decodes to nil, not a crash.
  func testGivenSnapshotEncodedWithoutStopConditions_WhenDecoding_ThenNil() throws {
    // Build a snapshot, then simulate an "old" encoding by round-tripping through a dict
    // that omits stopConditions.
    let profile = BlockedProfiles(name: "Legacy")
    profile.stopConditions = ProfileStopConditions(manual: true)
    let snapshot = BlockedProfiles.getSnapshot(for: profile)
    var json =
      try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(snapshot)) as! [String: Any]
    json.removeValue(forKey: "stopConditions")
    let stripped = try JSONSerialization.data(withJSONObject: json)

    let decoded = try JSONDecoder().decode(SharedData.ProfileSnapshot.self, from: stripped)

    XCTAssertNil(decoded.stopConditions, "missing field decodes to nil (back-compat)")
  }
  func testSnapshotCarriesCanonicalSettings() throws {
    let now = Date()
    let profile = BlockedProfiles(name: "Timer", createdAt: now, updatedAt: now)
    profile.startTriggers = .init(manual: true)
    profile.stopConditions = .init(timer: true, nfc: .specific, qr: .same, timerDurationMinutes: 37, allowChangingTimerBeforeStart: true)
    profile.stopNFCTagIds = ["A0FF"]
    let encoded = try JSONEncoder().encode(BlockedProfiles.getSnapshot(for: profile))
    let decoded = try JSONDecoder().decode(SharedData.ProfileSnapshot.self, from: encoded)
    XCTAssertEqual(decoded.stopConditions, profile.stopConditions)
    XCTAssertFalse(profile.hasInvalidConditionSettings)
    profile.stopConditionsData = Data("malformed".utf8)
    XCTAssertTrue(profile.hasInvalidConditionSettings)
    let safe = try JSONDecoder().decode(SharedData.ProfileSnapshot.self, from: JSONEncoder().encode(BlockedProfiles.getSnapshot(for: profile)))
    XCTAssertEqual(safe.stopConditions, ProfileStopConditions())

    let other = BlockedProfiles(name: "Other", createdAt: now, updatedAt: now)
    other.stopConditions = .init(manual: true)
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    json["stopConditions"] = ["manual": false, "timer": false, "anyNFC": true, "specificNFC": true, "sameNFC": true, "anyQR": true, "specificQR": false, "sameQR": true, "schedule": false, "deepLink": false]
    let otherJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(BlockedProfiles.getSnapshot(for: other)))
    let dictionary = try JSONSerialization.data(withJSONObject: ["old": json, "other": otherJSON])
    let snapshots = try JSONDecoder().decode([String: SharedData.ProfileSnapshot].self, from: dictionary)
    XCTAssertEqual(snapshots.count, 2)
    XCTAssertEqual(snapshots["old"]?.stopConditions?.nfc, .specific)
    XCTAssertEqual(snapshots["old"]?.stopConditions?.qr, .same)
    XCTAssertEqual(snapshots["other"]?.stopConditions?.manual, true)
  }

}
