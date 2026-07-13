import FamilyControls
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class TwinViewSnapshotTests: XCTestCase {
  private var container: ModelContainer!
  private var context: ModelContext!

  override func setUp() async throws {
    try await super.setUp()
    container = try TestModelContainer.create()
    context = container.mainContext
  }

  override func tearDown() async throws {
    context = nil
    container = nil
    try await super.tearDown()
  }

  func testGivenProfile_WhenProfileRowData_ThenMapsFields() throws {
    let now = Date()
    let profile = BlockedProfiles(
      name: "School",
      selectedActivity: FamilyActivitySelection(),
      createdAt: now,
      updatedAt: now
    )
    context.insert(profile)

    let data = profile.profileRowData

    XCTAssertEqual(data.id, profile.id)
    XCTAssertEqual(data.name, "School")
    XCTAssertEqual(data.updatedAt, now)
    XCTAssertEqual(data.selectedItemsCount, 0)
  }

  func testGivenProfileRowDataThenModelDeletedAndSaved_ThenValuesStillReadableNoTrap() throws {
    let profile = BlockedProfiles(name: "School", selectedActivity: FamilyActivitySelection())
    context.insert(profile)
    try context.save()

    let data = profile.profileRowData

    context.delete(profile)
    try context.save()

    XCTAssertFalse(profile.isPersistentModelValid)
    XCTAssertEqual(data.name, "School")
  }
}
