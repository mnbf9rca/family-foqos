import XCTest

@testable import FamilyFoqos

@MainActor
final class GeofencePickerSelectionTests: XCTestCase {
  func testGivenNewLocationSaved_WhenSelectingLocation_ThenLocationIsSelectedWithDefaultReference() {
    let locationId = UUID()
    var selectedLocationIds: Set<UUID> = []
    var locationReferences: [UUID: ProfileLocationReference] = [:]

    GeofencePicker.selectLocation(
      locationId,
      selectedLocationIds: &selectedLocationIds,
      locationReferences: &locationReferences
    )

    XCTAssertTrue(selectedLocationIds.contains(locationId))
    XCTAssertEqual(locationReferences[locationId]?.savedLocationId, locationId)
    XCTAssertNil(locationReferences[locationId]?.radiusOverrideMeters)
  }
}
