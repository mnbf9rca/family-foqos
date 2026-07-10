import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class ProfileScheduleRowDataTests: XCTestCase {
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

  func testGivenLegacyScheduleProfile_WhenCardData_ThenScheduleFlagsMatchModel() throws {
    let now = Date()
    let profile = BlockedProfiles(
      name: "Sched", blockingStrategyId: NFCBlockingStrategy.id,
      schedule: .init(
        days: [.monday, .friday], startHour: 9, startMinute: 0,
        endHour: 17, endMinute: 0, updatedAt: now))
    context.insert(profile)

    let data = profile.cardData

    XCTAssertEqual(data.schedule?.isActive, profile.schedule?.isActive)
    XCTAssertEqual(data.scheduleIsOutOfSync, profile.scheduleIsOutOfSync)
    XCTAssertEqual(data.profileSchemaVersion, profile.profileSchemaVersion)
    XCTAssertEqual(data.blockingStrategyId, profile.blockingStrategyId)
  }
}
