import XCTest

@testable import FamilyFoqos

@MainActor
final class SyncConflictManagerDivergenceTests: XCTestCase {

  override func tearDown() async throws {
    SyncConflictManager.shared.clearAll()
    try await super.tearDown()
  }

  func testGivenDivergence_WhenAdded_ThenBannerShownWithDedicatedCopy() {
    let manager = SyncConflictManager.shared
    manager.clearAll()
    manager.addDivergenceConflict(profileId: UUID(), profileName: "Homework")
    XCTAssertTrue(manager.showConflictBanner)
    XCTAssertTrue(manager.shouldShowDivergenceBanner)
    XCTAssertTrue(manager.divergenceMessage.contains("Homework"))
    XCTAssertFalse(
      manager.divergenceMessage.lowercased().contains("older app version"),
      "a same-version concurrent edit must NOT claim an app-version mismatch")
  }

  func testGivenDivergence_WhenCleared_ThenBannerHides() {
    let manager = SyncConflictManager.shared
    manager.clearAll()
    let id = UUID()
    manager.addDivergenceConflict(profileId: id, profileName: "Homework")
    manager.clearConflict(profileId: id)
    XCTAssertFalse(manager.showConflictBanner)
  }
}
