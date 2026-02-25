import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class UpdateProfileTests: XCTestCase {

  private var container: ModelContainer!
  private var context: ModelContext!
  private var testSuiteName: String!

  override func setUp() async throws {
    try await super.setUp()
    testSuiteName = "UpdateProfileTests-\(UUID().uuidString)"
    SharedData.configure(
      suite: UserDefaults(suiteName: testSuiteName)!
    )
    container = try TestModelContainer.create()
    context = container.mainContext
  }

  override func tearDown() async throws {
    UserDefaults().removePersistentDomain(forName: testSuiteName)
    try await super.tearDown()
  }

  // MARK: - Single field updates

  func testGivenProfile_WhenUpdatingName_ThenOnlyNameChanges() throws {
    let now = Date()
    let profile = BlockedProfiles(name: "Original")
    context.insert(profile)
    try context.save()

    let originalOrder = profile.order
    let originalEnableBreaks = profile.enableBreaks

    let updated = try BlockedProfiles.updateProfile(
      profile, in: context, now: now, name: "Renamed"
    )

    XCTAssertEqual(updated.name, "Renamed")
    XCTAssertEqual(updated.order, originalOrder)
    XCTAssertEqual(updated.enableBreaks, originalEnableBreaks)
    XCTAssertEqual(updated.updatedAt, now)
  }

  func testGivenProfile_WhenUpdatingEnableBreaks_ThenOnlyBreaksChange() throws {
    let now = Date()
    let profile = BlockedProfiles(name: "Test", enableBreaks: false)
    context.insert(profile)
    try context.save()

    let updated = try BlockedProfiles.updateProfile(
      profile, in: context, now: now, enableBreaks: true, breakTimeInMinutes: 10
    )

    XCTAssertEqual(updated.name, "Test")
    XCTAssertTrue(updated.enableBreaks)
    XCTAssertEqual(updated.breakTimeInMinutes, 10)
    XCTAssertEqual(updated.updatedAt, now)
  }

  // MARK: - Multiple field updates

  func testGivenProfile_WhenUpdatingMultipleFields_ThenAllApplied() throws {
    let now = Date()
    let profile = BlockedProfiles(name: "Original")
    context.insert(profile)
    try context.save()

    let updated = try BlockedProfiles.updateProfile(
      profile, in: context, now: now,
      name: "Updated",
      enableStrictMode: true,
      order: 5,
      disableBackgroundStops: true
    )

    XCTAssertEqual(updated.name, "Updated")
    XCTAssertTrue(updated.enableStrictMode)
    XCTAssertEqual(updated.order, 5)
    XCTAssertTrue(updated.disableBackgroundStops)
    XCTAssertEqual(updated.updatedAt, now)
  }

  // MARK: - Deterministic timestamp

  func testGivenProfile_WhenUpdatingWithInjectedNow_ThenUpdatedAtMatchesExactly() throws {
    let pinned = Date(timeIntervalSince1970: 1_000_000)
    let profile = BlockedProfiles(name: "Test")
    context.insert(profile)
    try context.save()

    let updated = try BlockedProfiles.updateProfile(
      profile, in: context, now: pinned, name: "Changed"
    )

    XCTAssertEqual(updated.updatedAt, pinned)
  }

  // MARK: - Persistence

  func testGivenProfile_WhenUpdated_ThenChangesPersistInContext() throws {
    let now = Date()
    let profile = BlockedProfiles(name: "Before")
    context.insert(profile)
    try context.save()

    let profileId = profile.id
    _ = try BlockedProfiles.updateProfile(
      profile, in: context, now: now, name: "After"
    )

    // Re-fetch from context to verify persistence
    let descriptor = FetchDescriptor<BlockedProfiles>(
      predicate: #Predicate { $0.id == profileId }
    )
    let fetched = try context.fetch(descriptor).first
    XCTAssertEqual(fetched?.name, "After")
  }
}
