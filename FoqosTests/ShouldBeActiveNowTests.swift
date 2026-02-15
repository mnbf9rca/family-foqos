// FoqosTests/ShouldBeActiveNowTests.swift
import XCTest

@testable import FamilyFoqos

final class ShouldBeActiveNowTests: XCTestCase {
  private let calendar = Calendar.current

  // Fixed reference: Monday 2026-06-15 (weekday 2 = Monday)
  private let referenceDate: Date = {
    var c = DateComponents()
    c.year = 2026
    c.month = 6
    c.day = 15
    c.hour = 12
    c.minute = 0
    c.second = 0
    return Calendar.current.date(from: c)!
  }()

  /// Monday's weekday value (2 in Apple's Calendar)
  private var referenceWeekday: Int { calendar.component(.weekday, from: referenceDate) }

  private func date(hour: Int, minute: Int, dayOffset: Int = 0) -> Date {
    var c = calendar.dateComponents([.year, .month, .day], from: referenceDate)
    c.hour = hour
    c.minute = minute
    c.second = 0
    let base = calendar.date(from: c)!
    return dayOffset == 0 ? base : calendar.date(byAdding: .day, value: dayOffset, to: base)!
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
    let now = date(hour: 14, minute: 0)

    XCTAssertTrue(
      start.shouldBeActiveNow(
        stopSchedule: nil, lastStoppedAt: nil, on: now, calendar: calendar)
    )
  }

  func testOutsideWindow_returnsFalse() {
    let start = makeSchedule(hour: 14, minute: 0)
    let now = date(hour: 9, minute: 0)

    XCTAssertFalse(
      start.shouldBeActiveNow(
        stopSchedule: nil, lastStoppedAt: nil, on: now, calendar: calendar)
    )
  }

  func testInWindow_suppressed_returnsFalse() {
    let start = makeSchedule(hour: 10, minute: 0)
    let now = date(hour: 14, minute: 0)
    let stoppedAt = date(hour: 12, minute: 0)

    XCTAssertFalse(
      start.shouldBeActiveNow(
        stopSchedule: nil, lastStoppedAt: stoppedAt, on: now, calendar: calendar)
    )
  }

  // MARK: - Age check

  func testTooNew_returnsFalse() {
    let now = date(hour: 14, minute: 0)
    let start = makeSchedule(hour: 10, minute: 0, updatedAt: now)

    XCTAssertFalse(
      start.shouldBeActiveNow(
        stopSchedule: nil, lastStoppedAt: nil, on: now, calendar: calendar)
    )
  }

  // MARK: - Day check

  func testNotScheduledDay_returnsFalse() {
    // Reference is Monday (weekday 2). Pick a day that is NOT Monday.
    let otherDay = Weekday.allCases.first { $0.rawValue != referenceWeekday }!
    let start = makeSchedule(hour: 10, minute: 0, days: [otherDay])
    let now = date(hour: 14, minute: 0)

    XCTAssertFalse(
      start.shouldBeActiveNow(
        stopSchedule: nil, lastStoppedAt: nil, on: now, calendar: calendar)
    )
  }

  // MARK: - Overnight

  func testOvernight_at2300_notSuppressed_returnsTrue() {
    let start = makeSchedule(hour: 22, minute: 0)
    let stop = makeSchedule(hour: 6, minute: 0)
    let now = date(hour: 23, minute: 0)

    XCTAssertTrue(
      start.shouldBeActiveNow(
        stopSchedule: stop, lastStoppedAt: nil, on: now, calendar: calendar)
    )
  }

  func testOvernight_at0300_notSuppressed_returnsTrue() {
    let start = makeSchedule(hour: 22, minute: 0)
    let stop = makeSchedule(hour: 6, minute: 0)
    let now = date(hour: 3, minute: 0)

    XCTAssertTrue(
      start.shouldBeActiveNow(
        stopSchedule: stop, lastStoppedAt: nil, on: now, calendar: calendar)
    )
  }

  func testOvernight_at0300_stoppedAt2230Yesterday_returnsFalse() {
    let start = makeSchedule(hour: 22, minute: 0)
    let stop = makeSchedule(hour: 6, minute: 0)
    let now = date(hour: 3, minute: 0)
    let stoppedAt = date(hour: 22, minute: 30, dayOffset: -1)

    XCTAssertFalse(
      start.shouldBeActiveNow(
        stopSchedule: stop, lastStoppedAt: stoppedAt, on: now, calendar: calendar)
    )
  }

  func testOvernight_betweenWindows_returnsFalse() {
    let start = makeSchedule(hour: 22, minute: 0)
    let stop = makeSchedule(hour: 6, minute: 0)
    let now = date(hour: 12, minute: 0)

    XCTAssertFalse(
      start.shouldBeActiveNow(
        stopSchedule: stop, lastStoppedAt: nil, on: now, calendar: calendar)
    )
  }

  // MARK: - Same-day with stop

  func testSameDay_insideWindow_returnsTrue() {
    let start = makeSchedule(hour: 10, minute: 0)
    let stop = makeSchedule(hour: 17, minute: 0)
    let now = date(hour: 14, minute: 0)

    XCTAssertTrue(
      start.shouldBeActiveNow(
        stopSchedule: stop, lastStoppedAt: nil, on: now, calendar: calendar)
    )
  }

  func testSameDay_afterStop_returnsFalse() {
    let start = makeSchedule(hour: 10, minute: 0)
    let stop = makeSchedule(hour: 17, minute: 0)
    let now = date(hour: 18, minute: 0)

    XCTAssertFalse(
      start.shouldBeActiveNow(
        stopSchedule: stop, lastStoppedAt: nil, on: now, calendar: calendar)
    )
  }

  // MARK: - Overnight day check (window started yesterday)

  func testOvernight_at0300_yesterdayNotScheduled_returnsFalse() {
    // Reference is Monday. Schedule only for Monday (not Sunday = yesterday).
    let mondayDay = Weekday(rawValue: referenceWeekday)!
    let start = makeSchedule(hour: 22, minute: 0, days: [mondayDay])
    let stop = makeSchedule(hour: 6, minute: 0)
    let now = date(hour: 3, minute: 0)

    // At 03:00, window started yesterday (Sunday). Sunday is NOT in schedule days.
    XCTAssertFalse(
      start.shouldBeActiveNow(
        stopSchedule: stop, lastStoppedAt: nil, on: now, calendar: calendar)
    )
  }
}
