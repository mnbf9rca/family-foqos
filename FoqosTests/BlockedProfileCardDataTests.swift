import FamilyControls
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class BlockedProfileCardDataTests: XCTestCase {
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

  func testGivenProfile_WhenCardData_ThenMapsScalarAndDerivedFields() throws {
    let profile = BlockedProfiles(
      id: UUID(), name: "Work", selectedActivity: FamilyActivitySelection(),
      blockingStrategyId: NFCBlockingStrategy.id, enableLiveActivity: true,
      reminderTimeInSeconds: 3600
    )
    context.insert(profile)

    let data = profile.cardData

    XCTAssertEqual(data.id, profile.id)
    XCTAssertEqual(data.name, "Work")
    XCTAssertTrue(data.enableLiveActivity)
    XCTAssertTrue(data.hasReminders)
    XCTAssertEqual(data.blockingStrategyId, NFCBlockingStrategy.id)
    XCTAssertEqual(data.sessionCount, 0)
    XCTAssertEqual(data.domainsCount, 0)
    XCTAssertFalse(data.isNewerSchemaVersion)
    XCTAssertEqual(data.profileSchemaVersion, BlockedProfiles.currentSchemaVersion)
  }

  func testGivenModelMutated_WhenCardDataRebuilt_ThenReflectsChange() throws {
    let profile = BlockedProfiles(
      id: UUID(), name: "Before", selectedActivity: FamilyActivitySelection())
    context.insert(profile)

    let before = profile.cardData
    XCTAssertEqual(before.name, "Before")

    profile.name = "After"
    let after = profile.cardData

    XCTAssertEqual(after.name, "After")
    XCTAssertEqual(before.name, "Before")
  }

  func testGivenCardDataThenModelDeletedAndSaved_ThenValuesStillReadableNoTrap() throws {
    let profile = BlockedProfiles(
      id: UUID(), name: "Gaming", selectedActivity: FamilyActivitySelection(),
      blockingStrategyId: QRCodeBlockingStrategy.id
    )
    context.insert(profile)
    try context.save()

    let data = profile.cardData

    context.delete(profile)
    try context.save()

    XCTAssertFalse(profile.isPersistentModelValid)
    XCTAssertEqual(data.name, "Gaming")
    XCTAssertEqual(data.blockingStrategyId, QRCodeBlockingStrategy.id)
  }
}
