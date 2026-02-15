// FoqosTests/ShouldBeActiveNowTests.swift
import XCTest

@testable import FamilyFoqos

final class ShouldBeActiveNowTests: XCTestCase {
  private let calendar = Calendar.current

  /// Helper: build a date for today at the given hour:minute
  private func today(hour: Int, minute: Int) -> Date {
    let now = Date()
    var c = calendar.dateComponents([.year, .month, .day], from: now)
    c.hour = hour
    c.minute = minute
    c.second = 0
    return calendar.date(from: c)!
  }

  /// Helper: build a date for yesterday at the given hour:minute
  private func yesterday(hour: Int, minute: Int) -> Date {
    calendar.date(byAdding: .day, value: -1, to: today(hour: hour, minute: minute))!
  }

  private func makeSchedule(
    hour: Int, minute: Int, days: [Weekday] = Weekday.allCases,
    updatedAt: Date? = nil
  ) -> ProfileScheduleTime {
    ProfileScheduleTime(
      days: days, hour: hour, minute: minute,
      updatedAt: updatedAt ?? .distantPast
    )
  }

  // MARK: - Basic window checks

  func testInWindow_notSuppressed_returnsTrue() {
    let start = makeSchedule(hour: 10, minute: 0)
    let now = today(hour: 14, minute: 0)

    XCTAssertTrue(
      start.shouldBeActiveNow(
        stopSchedule: nil, lastStoppedAt: nil, on: now, calendar: calendar)
    )
  }

  func testOutsideWindow_returnsFalse() {
    let start = makeSchedule(hour: 14, minute: 0)
    let now = today(hour: 9, minute: 0)

    XCTAssertFalse(
      start.shouldBeActiveNow(
        stopSchedule: nil, lastStoppedAt: nil, on: now, calendar: calendar)
    )
  }

  func testInWindow_suppressed_returnsFalse() {
    let start = makeSchedule(hour: 10, minute: 0)
    let now = today(hour: 14, minute: 0)
    let stoppedAt = today(hour: 12, minute: 0)

    XCTAssertFalse(
      start.shouldBeActiveNow(
        stopSchedule: nil, lastStoppedAt: stoppedAt, on: now, calendar: calendar)
    )
  }

  // MARK: - Age check

  func testTooNew_returnsFalse() {
    let now = today(hour: 14, minute: 0)
    let start = makeSchedule(hour: 10, minute: 0, updatedAt: now)

    XCTAssertFalse(
      start.shouldBeActiveNow(
        stopSchedule: nil, lastStoppedAt: nil, on: now, calendar: calendar)
    )
  }

  // MARK: - Day check

  func testNotScheduledDay_returnsFalse() {
    // Build a schedule only for a day that is NOT today
    let todayWeekday = calendar.component(.weekday, from: Date())
    let otherDay = Weekday.allCases.first { $0.rawValue != todayWeekday }!
    let start = makeSchedule(hour: 10, minute: 0, days: [otherDay])
    let now = today(hour: 14, minute: 0)

    XCTAssertFalse(
      start.shouldBeActiveNow(
        stopSchedule: nil, lastStoppedAt: nil, on: now, calendar: calendar)
    )
  }

  // MARK: - Overnight

  func testOvernight_at2300_notSuppressed_returnsTrue() {
    let start = makeSchedule(hour: 22, minute: 0)
    let stop = makeSchedule(hour: 6, minute: 0)
    let now = today(hour: 23, minute: 0)

    XCTAssertTrue(
      start.shouldBeActiveNow(
        stopSchedule: stop, lastStoppedAt: nil, on: now, calendar: calendar)
    )
  }

  func testOvernight_at0300_notSuppressed_returnsTrue() {
    let start = makeSchedule(hour: 22, minute: 0)
    let stop = makeSchedule(hour: 6, minute: 0)
    let now = today(hour: 3, minute: 0)

    XCTAssertTrue(
      start.shouldBeActiveNow(
        stopSchedule: stop, lastStoppedAt: nil, on: now, calendar: calendar)
    )
  }

  func testOvernight_at0300_stoppedAt2230Yesterday_returnsFalse() {
    let start = makeSchedule(hour: 22, minute: 0)
    let stop = makeSchedule(hour: 6, minute: 0)
    let now = today(hour: 3, minute: 0)
    let stoppedAt = yesterday(hour: 22, minute: 30)

    XCTAssertFalse(
      start.shouldBeActiveNow(
        stopSchedule: stop, lastStoppedAt: stoppedAt, on: now, calendar: calendar)
    )
  }

  func testOvernight_betweenWindows_returnsFalse() {
    let start = makeSchedule(hour: 22, minute: 0)
    let stop = makeSchedule(hour: 6, minute: 0)
    let now = today(hour: 12, minute: 0)

    XCTAssertFalse(
      start.shouldBeActiveNow(
        stopSchedule: stop, lastStoppedAt: nil, on: now, calendar: calendar)
    )
  }

  // MARK: - Same-day with stop

  func testSameDay_insideWindow_returnsTrue() {
    let start = makeSchedule(hour: 10, minute: 0)
    let stop = makeSchedule(hour: 17, minute: 0)
    let now = today(hour: 14, minute: 0)

    XCTAssertTrue(
      start.shouldBeActiveNow(
        stopSchedule: stop, lastStoppedAt: nil, on: now, calendar: calendar)
    )
  }

  func testSameDay_afterStop_returnsFalse() {
    let start = makeSchedule(hour: 10, minute: 0)
    let stop = makeSchedule(hour: 17, minute: 0)
    let now = today(hour: 18, minute: 0)

    XCTAssertFalse(
      start.shouldBeActiveNow(
        stopSchedule: stop, lastStoppedAt: nil, on: now, calendar: calendar)
    )
  }

  // MARK: - Overnight day check (window started yesterday)

  func testOvernight_at0300_yesterdayNotScheduled_returnsFalse() {
    // Schedule only for a day that is today (not yesterday)
    let todayWeekday = calendar.component(.weekday, from: Date())
    let todayDay = Weekday(rawValue: todayWeekday)!
    let start = makeSchedule(hour: 22, minute: 0, days: [todayDay])
    let stop = makeSchedule(hour: 6, minute: 0)
    let now = today(hour: 3, minute: 0)

    // At 03:00, window started yesterday. Yesterday is NOT in schedule days.
    XCTAssertFalse(
      start.shouldBeActiveNow(
        stopSchedule: stop, lastStoppedAt: nil, on: now, calendar: calendar)
    )
  }
}
