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

  func testGivenV2ScheduleProfile_WhenCardData_ThenStartStopTriggerAndScheduleFieldsMatchModel() throws {
    let now = Date()
    let profile = BlockedProfiles(name: "SchedV2", blockingStrategyId: NFCBlockingStrategy.id)
    var startTriggers = ProfileStartTriggers()
    startTriggers.schedule = true
    var stopConditions = ProfileStopConditions(manual: true)
    stopConditions.timer = true
    let beforeStartSchedule = ProfileScheduleTime(
      days: [.monday, .friday],
      hour: 9, minute: 0,
      updatedAt: now
    )
    let beforeStopSchedule = ProfileScheduleTime(
      days: [.saturday, .sunday],
      hour: 17, minute: 30,
      updatedAt: now
    )
    profile.startTriggers = startTriggers
    profile.stopConditions = stopConditions
    profile.startSchedule = beforeStartSchedule
    profile.stopSchedule = beforeStopSchedule
    context.insert(profile)

    let before = profile.cardData
    XCTAssertEqual(before.startTriggers, startTriggers)
    XCTAssertEqual(before.stopConditions, stopConditions)
    XCTAssertEqual(before.startSchedule, beforeStartSchedule)
    XCTAssertEqual(before.stopSchedule, beforeStopSchedule)

    var afterStartTriggers = startTriggers
    afterStartTriggers.schedule = false
    profile.startTriggers = afterStartTriggers

    var afterStopConditions = stopConditions
    afterStopConditions.schedule = true
    profile.stopConditions = afterStopConditions

    let afterStartSchedule = ProfileScheduleTime(
      days: [.tuesday, .thursday],
      hour: 14, minute: 45,
      updatedAt: now
    )
    let afterStopSchedule = ProfileScheduleTime(
      days: [.wednesday, .saturday],
      hour: 23, minute: 15,
      updatedAt: now
    )
    profile.startSchedule = afterStartSchedule
    profile.stopSchedule = afterStopSchedule

    let after = profile.cardData
    XCTAssertEqual(before.startTriggers, startTriggers)
    XCTAssertEqual(before.stopConditions, stopConditions)
    XCTAssertEqual(before.startSchedule, beforeStartSchedule)
    XCTAssertEqual(before.stopSchedule, beforeStopSchedule)

    XCTAssertEqual(after.startTriggers, afterStartTriggers)
    XCTAssertEqual(after.stopConditions, afterStopConditions)
    XCTAssertEqual(after.startSchedule, afterStartSchedule)
    XCTAssertEqual(after.stopSchedule, afterStopSchedule)
  }
}
