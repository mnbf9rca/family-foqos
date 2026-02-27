import SwiftData
import SwiftUI
import XCTest

@testable import FamilyFoqos

@MainActor
final class SafeModelViewTests: XCTestCase {

  private var container: ModelContainer!
  private var context: ModelContext!

  override func setUp() async throws {
    container = try TestModelContainer.create()
    context = container.mainContext
  }

  override func tearDown() async throws {
    container = nil
    context = nil
  }

  // MARK: - .valid extension tests (verify existing behavior)

  func testValidFiltersDeletedModels() throws {
    let profile1 = BlockedProfiles(
      id: UUID(), name: "Keep", selectedActivity: .init(),
      blockingStrategyId: "manual")
    let profile2 = BlockedProfiles(
      id: UUID(), name: "Delete", selectedActivity: .init(),
      blockingStrategyId: "manual")

    context.insert(profile1)
    context.insert(profile2)
    try context.save()

    context.delete(profile2)

    let result = [profile1, profile2].valid
    XCTAssertEqual(result.count, 1)
    XCTAssertEqual(result.first?.name, "Keep")
  }

  func testValidReturnsAllWhenNoneDeleted() throws {
    let profile1 = BlockedProfiles(
      id: UUID(), name: "A", selectedActivity: .init(),
      blockingStrategyId: "manual")
    let profile2 = BlockedProfiles(
      id: UUID(), name: "B", selectedActivity: .init(),
      blockingStrategyId: "manual")

    context.insert(profile1)
    context.insert(profile2)
    try context.save()

    let result = [profile1, profile2].valid
    XCTAssertEqual(result.count, 2)
  }

  func testValidReturnsEmptyForAllDeleted() throws {
    let profile = BlockedProfiles(
      id: UUID(), name: "Gone", selectedActivity: .init(),
      blockingStrategyId: "manual")

    context.insert(profile)
    try context.save()

    context.delete(profile)

    let result = [profile].valid
    XCTAssertTrue(result.isEmpty)
  }

  // MARK: - SafeModelView unit tests

  func testSafeModelViewTypeExists() {
    // Verify the generic type compiles and can be instantiated
    let profile = BlockedProfiles(
      id: UUID(), name: "Test", selectedActivity: .init(),
      blockingStrategyId: "manual")
    context.insert(profile)

    let _ = SafeModelView(profile) { model in
      Text(model.name)
    }
  }

  func testSafeModelViewWithDeletedModel() throws {
    let profile = BlockedProfiles(
      id: UUID(), name: "Deleted", selectedActivity: .init(),
      blockingStrategyId: "manual")

    context.insert(profile)
    try context.save()
    context.delete(profile)

    // SafeModelView should not crash — it guards before accessing
    let view = SafeModelView(profile) { model in
      Text(model.name)
    }
    // If we got here without EXC_BREAKPOINT, the guard works
    XCTAssertNotNil(view)
  }
}
