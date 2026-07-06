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
}
