import XCTest

@testable import FamilyFoqos

@MainActor
final class GeofencePickerSelectionTests: XCTestCase {
  func testGivenSavedLocationsExist_WhenCheckingAddAffordance_ThenAddStillAvailable() {
    XCTAssertTrue(GeofencePicker.shouldShowAddLocationAffordance(savedLocationCount: 0))
    XCTAssertTrue(GeofencePicker.shouldShowAddLocationAffordance(savedLocationCount: 2))
  }

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
