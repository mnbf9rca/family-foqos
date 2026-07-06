import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class BlockedSessionsHabitTrackerTests: XCTestCase {
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

  func testGivenDeletedSession_WhenSessionsForDate_ThenExcludesZombieWithoutCrashing() throws {
    let now = Date()
    let calendar = Calendar.current
    let dayStart = calendar.startOfDay(for: now)
    let profile = BlockedProfiles(
      id: UUID(), name: "P", selectedActivity: .init(), blockingStrategyId: "manual")
    context.insert(profile)
    // Anchor to startOfDay(now) with a fixed endTime so overlap is time-of-day-independent
    // (a `now - 3600` completed session would not overlap today between 00:00 and 01:00).
    let live = BlockedProfileSession(
      tag: "live", blockedProfile: profile, startTime: dayStart.addingTimeInterval(3600))
    live.endTime = dayStart.addingTimeInterval(3600 + 1800)
    let zombie = BlockedProfileSession(
      tag: "zombie", blockedProfile: profile, startTime: dayStart.addingTimeInterval(3600))
    zombie.endTime = dayStart.addingTimeInterval(3600 + 1800)
    context.insert(live)
    context.insert(zombie)
    try context.save()

    context.delete(zombie)

    // Derived from the (now partly-zombie) array — must filter the zombie and not crash on it.
    let result = BlockedSessionsHabitTracker.sessionsForDate(now, in: [live, zombie], now: now)

    XCTAssertEqual(result.count, 1)
    XCTAssertEqual(result.first?.tag, "live")
  }

  func testGivenSessionsOverlappingDate_WhenSessionsForDate_ThenReturnsSortedByDayDurationDescending()
    throws
  {
    let now = Date()
    let calendar = Calendar.current
    let dayStart = calendar.startOfDay(for: now)
    let profile = BlockedProfiles(
      id: UUID(), name: "P", selectedActivity: .init(), blockingStrategyId: "manual")
    context.insert(profile)

    // Short session: 30 min, inside the day.
    let short = BlockedProfileSession(
      tag: "short", blockedProfile: profile, startTime: dayStart.addingTimeInterval(3600))
    short.endTime = dayStart.addingTimeInterval(3600 + 1800)
    // Long session: 2 h, inside the day.
    let long = BlockedProfileSession(
      tag: "long", blockedProfile: profile, startTime: dayStart.addingTimeInterval(7200))
    long.endTime = dayStart.addingTimeInterval(7200 + 7200)
    // Multi-day session: 25h total, but only 10 min overlap with the selected day.
    let multiDaySmallOverlap = BlockedProfileSession(
      tag: "multi-day-small-overlap", blockedProfile: profile,
      startTime: dayStart.addingTimeInterval(-24 * 3600))
    multiDaySmallOverlap.endTime = dayStart.addingTimeInterval(600)
    // Other-day session: excluded.
    let other = BlockedProfileSession(
      tag: "other", blockedProfile: profile,
      startTime: dayStart.addingTimeInterval(-2 * 86400))
    other.endTime = dayStart.addingTimeInterval(-2 * 86400 + 1800)
    context.insert(short)
    context.insert(long)
    context.insert(multiDaySmallOverlap)
    context.insert(other)
    try context.save()

    let result = BlockedSessionsHabitTracker.sessionsForDate(
      now, in: [multiDaySmallOverlap, short, long, other], now: now)

    XCTAssertEqual(result.map { $0.tag }, ["long", "short", "multi-day-small-overlap"])
  }

  func testGivenActiveSessionStartedToday_WhenSessionsForDate_ThenIncludedUsingInjectedNow() throws {
    let now = Date()
    let profile = BlockedProfiles(
      id: UUID(), name: "P", selectedActivity: .init(), blockingStrategyId: "manual")
    context.insert(profile)
    // Active session (endTime nil) started one hour ago — overlaps today only via injected `now`.
    let active = BlockedProfileSession(
      tag: "active", blockedProfile: profile, startTime: now.addingTimeInterval(-3600))
    context.insert(active)
    try context.save()

    let result = BlockedSessionsHabitTracker.sessionsForDate(now, in: [active], now: now)

    XCTAssertEqual(result.map { $0.tag }, ["active"])
  }
}
