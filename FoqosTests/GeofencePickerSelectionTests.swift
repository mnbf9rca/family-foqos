import XCTest

@testable import FamilyFoqos

final class GeofencePickerSelectionTests: XCTestCase {
  func testGivenNewLocationSaved_WhenApplyingAddResult_ThenLocationIsSelectedWithDefaultReference() {
    let locationId = UUID()

    let state = GeofencePicker.LocationSelectionState(
      selectedLocationIds: [],
      locationReferences: [:]
    )

    let updated = state.selectAddedLocation(locationId)

    XCTAssertTrue(updated.selectedLocationIds.contains(locationId))
    XCTAssertEqual(updated.locationReferences[locationId]?.savedLocationId, locationId)
    XCTAssertNil(updated.locationReferences[locationId]?.radiusOverrideMeters)
  }
}
