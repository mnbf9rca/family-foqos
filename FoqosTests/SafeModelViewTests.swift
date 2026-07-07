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

  func testGivenDeletedThenSavedModel_WhenFilteringValid_ThenExcluded() throws {
    // Post-save window regression for #285 — the existing .valid tests only delete
    // without saving, so they never exercised this window.
    let keep = BlockedProfiles(
      id: UUID(), name: "Keep", selectedActivity: .init(),
      blockingStrategyId: "manual")
    let gone = BlockedProfiles(
      id: UUID(), name: "Gone", selectedActivity: .init(),
      blockingStrategyId: "manual")
    context.insert(keep)
    context.insert(gone)
    try context.save()

    context.delete(gone)
    try context.save()

    if gone.modelContext == nil || gone.isDeleted {
      // Contingency Mode C: this in-memory test store does not reproduce the device post-save
      // window, so Task 4 device verification remains the authoritative proof for #285.
      let result = [keep, gone].valid
      XCTAssertEqual(result.count, 1)
      XCTAssertEqual(result.first?.name, "Keep")
      return
    }

    let result = [keep, gone].valid
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

    var contentCalled = false
    let view = SafeModelView(profile) { _ in
      contentCalled = true
      return Text("Should not render")
    }

    // Force body evaluation — the guard should prevent the content closure from executing
    let _ = view.body

    XCTAssertFalse(contentCalled, "Content closure should not be called for a deleted model")
  }

  func testSafeModelViewWithValidModel() throws {
    let profile = BlockedProfiles(
      id: UUID(), name: "Valid", selectedActivity: .init(),
      blockingStrategyId: "manual")

    context.insert(profile)
    try context.save()

    var contentCalled = false
    let view = SafeModelView(profile) { _ in
      contentCalled = true
      return Text("Should render")
    }

    let _ = view.body

    XCTAssertTrue(contentCalled, "Content closure should be called for a valid model")
  }

  // MARK: - isPersistentModelValid predicate (both deletion windows)

  func testGivenLiveSavedModel_WhenCheckingValidity_ThenValid() throws {
    let profile = BlockedProfiles(
      id: UUID(), name: "Live", selectedActivity: .init(),
      blockingStrategyId: "manual")
    context.insert(profile)
    try context.save()

    XCTAssertTrue(profile.isPersistentModelValid)
  }

  func testGivenInsertedUnsavedModel_WhenCheckingValidity_ThenValid() throws {
    // False-negative guard: a freshly inserted, not-yet-saved model is alive.
    let profile = BlockedProfiles(
      id: UUID(), name: "Fresh", selectedActivity: .init(),
      blockingStrategyId: "manual")
    context.insert(profile)

    XCTAssertTrue(profile.isPersistentModelValid)
  }

  func testGivenModelDeletedWithoutSave_WhenCheckingValidity_ThenInvalid() throws {
    // Pre-save window: isDeleted == true.
    let profile = BlockedProfiles(
      id: UUID(), name: "PreSaveGone", selectedActivity: .init(),
      blockingStrategyId: "manual")
    context.insert(profile)
    try context.save()

    context.delete(profile)

    XCTAssertFalse(profile.isPersistentModelValid)
  }

  func testGivenModelDeletedThenSaved_WhenCheckingValidity_ThenInvalid() throws {
    // Post-save window: isDeleted flips back to false — the gap #285 shipped through.
    let profile = BlockedProfiles(
      id: UUID(), name: "PostSaveGone", selectedActivity: .init(),
      blockingStrategyId: "manual")
    context.insert(profile)
    try context.save()

    context.delete(profile)
    try context.save()

    if profile.modelContext == nil || profile.isDeleted {
      // Contingency Mode C: this in-memory test store does not reproduce the device post-save
      // window, so Task 4 device verification remains the authoritative proof for #285.
      XCTAssertFalse(profile.isPersistentModelValid)
      return
    }

    XCTAssertFalse(
      profile.isPersistentModelValid,
      "A deleted-and-saved model must be rejected even though isDeleted == false")
  }
}
