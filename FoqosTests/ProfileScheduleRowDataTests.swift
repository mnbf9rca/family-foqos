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

  func testIndependentRecurrencesIgnoreRetainedLegacySchedule() throws {
    let now = Date()
    let profile = BlockedProfiles(name: "Independent", blockingStrategyId: NFCTimerBlockingStrategy.id)
    profile.startTriggers = ProfileStartTriggers(schedule: true)
    profile.stopConditions = ProfileStopConditions(timer: true, schedule: true, timerDurationMinutes: 45)
    profile.startSchedule = .init(days: [.monday], hour: 9, minute: 0, updatedAt: now)
    profile.stopSchedule = .init(days: [.friday], hour: 17, minute: 0, updatedAt: now)
    profile.schedule = .init(days: [.sunday], startHour: 1, startMinute: 0, endHour: 2, endMinute: 0, updatedAt: now)
    profile.strategyData = StrategyTimerData.toData(from: StrategyTimerData(durationInMinutes: 90))
    context.insert(profile)

    let row = ProfileScheduleRow(data: profile.cardData, isActive: false)
    XCTAssertEqual(row.scheduleLines, ["Start: Mo 9:00 AM", "Stop: Fr 5:00 PM"])
    XCTAssertEqual(row.timerDurationMinutes, 45)
    XCTAssertNil(row.countdownInterval(now: now))
  }

  func testDisabledV2SchedulesNeverReviveLegacyOrMergeDays() throws {
    let now = Date()
    let profile = BlockedProfiles(name: "Disabled", blockingStrategyId: NFCBlockingStrategy.id)
    profile.startTriggers = ProfileStartTriggers(manual: true)
    profile.stopConditions = ProfileStopConditions(manual: true, schedule: true)
    profile.startSchedule = .init(days: [.monday], hour: 9, minute: 0, updatedAt: now)
    profile.stopSchedule = .init(days: [.friday], hour: 17, minute: 0, updatedAt: now)
    profile.schedule = .init(days: [.sunday], startHour: 1, startMinute: 0, endHour: 2, endMinute: 0, updatedAt: now)
    context.insert(profile)
    XCTAssertEqual(ProfileScheduleRow(data: profile.cardData, isActive: false).scheduleLines, ["Stop: Fr 5:00 PM"])

    profile.stopConditions = ProfileStopConditions(manual: true)
    XCTAssertTrue(ProfileScheduleRow(data: profile.cardData, isActive: false).scheduleLines.isEmpty)
  }

  func testActiveTimerUsesAcceptedDeadlineAndClampsAfterExpiry() throws {
    let now = Date()
    let profile = BlockedProfiles(name: "Adjusted", blockingStrategyId: NFCBlockingStrategy.id)
    profile.startTriggers = ProfileStartTriggers(manual: true)
    profile.stopConditions = ProfileStopConditions(timer: true, timerDurationMinutes: 90)
    context.insert(profile)
    let session = BlockedProfileSession(tag: "manual", blockedProfile: profile, startTime: now)
    let deadline = now.addingTimeInterval(30 * 60)
    session.timerEndTime = deadline
    context.insert(session)

    let row = ProfileScheduleRow(data: profile.cardData, isActive: true)
    XCTAssertEqual(row.countdownInterval(now: now), now...deadline)
    XCTAssertEqual(row.countdownInterval(now: deadline.addingTimeInterval(60)), deadline...deadline)
    XCTAssertNil(row.timerDurationMinutes)
    XCTAssertNil(ProfileScheduleRow(data: profile.cardData, isActive: false).countdownInterval(now: now))
  }

  func testActiveSessionWithoutDeadlineNeverSuggestsConfiguredCountdown() throws {
    let now = Date()
    let profile = BlockedProfiles(name: "No countdown", blockingStrategyId: NFCTimerBlockingStrategy.id)
    profile.stopConditions = ProfileStopConditions(manual: true, timer: true, timerDurationMinutes: 90)
    profile.strategyData = StrategyTimerData.toData(from: StrategyTimerData(durationInMinutes: 60))
    context.insert(profile)
    let row = ProfileScheduleRow(data: profile.cardData, isActive: true)
    XCTAssertNil(row.countdownInterval(now: now))
    XCTAssertNil(row.timerDurationMinutes)
  }

  func testMissingOrInvalidDurationIsInertWithoutLegacyFallback() throws {
    let profile = BlockedProfiles(name: "Inert", blockingStrategyId: NFCTimerBlockingStrategy.id)
    profile.strategyData = StrategyTimerData.toData(from: StrategyTimerData(durationInMinutes: 60))
    context.insert(profile)
    for duration in [nil, 0, 14, 1440] as [Int?] {
      profile.stopConditions = ProfileStopConditions(manual: true, timer: true, timerDurationMinutes: duration)
      XCTAssertNil(ProfileScheduleRow(data: profile.cardData, isActive: false).timerDurationMinutes)
    }
  }

  func testGenuinelyUnmigratedProfileKeepsLegacyScheduleAndDuration() throws {
    let now = Date()
    let profile = BlockedProfiles(name: "V1", blockingStrategyId: NFCTimerBlockingStrategy.id)
    profile.profileSchemaVersion = 1
    profile.strategyData = StrategyTimerData.toData(from: StrategyTimerData(durationInMinutes: 60))
    profile.schedule = .init(days: [.monday], startHour: 9, startMinute: 0, endHour: 17, endMinute: 0, updatedAt: now)
    context.insert(profile)
    let row = ProfileScheduleRow(data: profile.cardData, isActive: false)
    XCTAssertEqual(row.scheduleLines, ["Mo", "9:00 AM - 5:00 PM"])
    XCTAssertEqual(row.timerDurationMinutes, 60)
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
