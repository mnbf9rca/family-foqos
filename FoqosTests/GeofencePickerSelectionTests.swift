import XCTest

@testable import FamilyFoqos

@MainActor
final class GeofencePickerSelectionTests: XCTestCase {
  func testGivenSavedLocationsExist_WhenCheckingAddAffordance_ThenAddStillAvailable() {
    XCTAssertTrue(GeofencePicker.shouldShowAddLocationAffordance(savedLocationCount: 0))
    XCTAssertTrue(GeofencePicker.shouldShowAddLocationAffordance(savedLocationCount: 2))
  }

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
