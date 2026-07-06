import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class ProfileInsightsUtilTests: XCTestCase {
  private var container: ModelContainer!
  private var context: ModelContext!

  override func setUp() async throws {
    try await super.setUp()
    container = try TestModelContainer.create()
    context = container.mainContext
  }

  override func tearDown() async throws {
    container = nil
    context = nil
    try await super.tearDown()
  }

  private func makeProfileWithCompletedSession(now: Date) throws -> BlockedProfiles {
    let profile = BlockedProfiles(
      id: UUID(), name: "Insights", selectedActivity: .init(), blockingStrategyId: "manual")
    context.insert(profile)
    let session = BlockedProfileSession(
      tag: "s", blockedProfile: profile, startTime: now.addingTimeInterval(-3600))
    session.endTime = now.addingTimeInterval(-1800)
    context.insert(session)
    try context.save()
    return profile
  }

  func testGivenLiveProfileWithSession_WhenInit_ThenCountsCompletedSession() throws {
    let now = Date()
    let profile = try makeProfileWithCompletedSession(now: now)

    let util = ProfileInsightsUtil(profile: profile)

    XCTAssertEqual(util.metrics.totalCompletedSessions, 1)
  }

  func testGivenProfileDeletedAfterInit_WhenRefreshAndAggregate_ThenReturnsEmptyWithoutCrashing()
    throws
  {
    let now = Date()
    let profile = try makeProfileWithCompletedSession(now: now)
    let util = ProfileInsightsUtil(profile: profile)
    XCTAssertEqual(util.metrics.totalCompletedSessions, 1, "precondition: alive")

    // Profile is deleted (e.g. a remote CloudKit deletion) while the sheet retains `util`.
    context.delete(profile)

    // None of these may crash; all must return empty/zero.
    util.refresh()
    XCTAssertEqual(util.metrics.totalCompletedSessions, 0)
    XCTAssertEqual(util.metrics.totalFocusTime, 0)
    XCTAssertTrue(util.dailyAggregates(days: 14, endingOn: now).allSatisfy { $0.sessionsCount == 0 })
    XCTAssertTrue(
      util.hourlyAggregates(days: 14, endingOn: now).allSatisfy { $0.sessionsStarted == 0 })
    XCTAssertTrue(
      util.breakDailyAggregates(days: 14, endingOn: now).allSatisfy { $0.breaksCount == 0 })
    XCTAssertTrue(
      util.sessionEndHourlyAggregates(days: 14, endingOn: now).allSatisfy { $0.sessionsEnded == 0 })
  }

  func testGivenOneCascadeDeletedSession_WhenInit_ThenExcludesZombieSession() throws {
    let now = Date()
    let profile = BlockedProfiles(
      id: UUID(), name: "Insights", selectedActivity: .init(), blockingStrategyId: "manual")
    context.insert(profile)
    let live = BlockedProfileSession(
      tag: "live", blockedProfile: profile, startTime: now.addingTimeInterval(-3600))
    live.endTime = now.addingTimeInterval(-1800)
    let zombie = BlockedProfileSession(
      tag: "zombie", blockedProfile: profile, startTime: now.addingTimeInterval(-3600))
    zombie.endTime = now.addingTimeInterval(-1800)
    context.insert(live)
    context.insert(zombie)
    try context.save()

    context.delete(zombie)

    let util = ProfileInsightsUtil(profile: profile)
    XCTAssertEqual(util.metrics.totalCompletedSessions, 1)
  }
}
