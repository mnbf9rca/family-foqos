import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class SavedLocationActionRefetchTests: XCTestCase {
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

  func testGivenLocationDeletedAndSaved_WhenResolvingEditTap_ThenReturnsNilNoSheetPath()
    throws
  {
    let location = SavedLocation(name: "Home", latitude: 0, longitude: 0)
    context.insert(location)
    try context.save()
    let locationId = location.id

    context.delete(location)
    try context.save()

    let target = try SavedLocationsView.editTarget(
      locationId: locationId,
      in: context,
      mode: .individual,
      canVerifyCode: false
    )

    XCTAssertNil(target)
  }

  func testGivenPendingEditLocationDeleted_WhenLockCodeSucceeds_ThenRefetchReturnsNilNoSheetPath()
    throws
  {
    let location = SavedLocation(
      name: "Locked",
      latitude: 0,
      longitude: 0,
      isLocked: true
    )
    context.insert(location)
    try context.save()
    let locationId = location.id

    let target = try XCTUnwrap(
      SavedLocationsView.editTarget(
        locationId: locationId,
        in: context,
        mode: .child,
        canVerifyCode: true
      )
    )
    XCTAssertTrue(target.requiresLockCode)

    context.delete(location)
    try context.save()

    let pendingLocation = try SavedLocationsView.validSavedLocation(
      locationId: locationId,
      in: context
    )

    XCTAssertNil(pendingLocation)
  }
}
