// FoqosTests/ShouldBeActiveNowTests.swift
import XCTest

@testable import FamilyFoqos

final class ShouldBeActiveNowTests: XCTestCase {
  private let calendar = Calendar(identifier: .gregorian)

  // Fixed reference: Monday 2026-06-15 (weekday 2 = Monday)
  private let referenceDate: Date = {
    var c = DateComponents()
    c.year = 2026
    c.month = 6
    c.day = 15
    c.hour = 12
    c.minute = 0
    c.second = 0
    return Calendar(identifier: .gregorian).date(from: c)!
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

  func testGivenInWindowNotSuppressed_WhenCheckingActive_ThenReturnsTrue() {
    let start = makeSchedule(hour: 10, minute: 0)
    let now = date(hour: 14, minute: 0)

    XCTAssertTrue(
      start.shouldBeActiveNow(
        stopSchedule: nil, lastStoppedAt: nil, on: now, calendar: calendar)
    )
  }

  func testGivenOutsideWindow_WhenCheckingActive_ThenReturnsFalse() {
    let start = makeSchedule(hour: 14, minute: 0)
    let now = date(hour: 9, minute: 0)

    XCTAssertFalse(
      start.shouldBeActiveNow(
        stopSchedule: nil, lastStoppedAt: nil, on: now, calendar: calendar)
    )
  }

  func testGivenInWindowSuppressed_WhenCheckingActive_ThenReturnsFalse() {
    let start = makeSchedule(hour: 10, minute: 0)
    let now = date(hour: 14, minute: 0)
    let stoppedAt = date(hour: 12, minute: 0)

    XCTAssertFalse(
      start.shouldBeActiveNow(
        stopSchedule: nil, lastStoppedAt: stoppedAt, on: now, calendar: calendar)
    )
  }

  // MARK: - Age check

  func testGivenScheduleTooNew_WhenCheckingActive_ThenReturnsFalse() {
    let now = date(hour: 14, minute: 0)
    let start = makeSchedule(hour: 10, minute: 0, updatedAt: now)

    XCTAssertFalse(
      start.shouldBeActiveNow(
        stopSchedule: nil, lastStoppedAt: nil, on: now, calendar: calendar)
    )
  }

  // MARK: - Day check

  func testGivenNotScheduledDay_WhenCheckingActive_ThenReturnsFalse() {
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

  func testGivenOvernightAt2300NotSuppressed_WhenCheckingActive_ThenReturnsTrue() {
    let start = makeSchedule(hour: 22, minute: 0)
    let stop = makeSchedule(hour: 6, minute: 0)
    let now = date(hour: 23, minute: 0)

    XCTAssertTrue(
      start.shouldBeActiveNow(
        stopSchedule: stop, lastStoppedAt: nil, on: now, calendar: calendar)
    )
  }

  func testGivenOvernightAt0300NotSuppressed_WhenCheckingActive_ThenReturnsTrue() {
    let start = makeSchedule(hour: 22, minute: 0)
    let stop = makeSchedule(hour: 6, minute: 0)
    let now = date(hour: 3, minute: 0)

    XCTAssertTrue(
      start.shouldBeActiveNow(
        stopSchedule: stop, lastStoppedAt: nil, on: now, calendar: calendar)
    )
  }

  func testGivenOvernightAt0300StoppedYesterday_WhenCheckingActive_ThenReturnsFalse() {
    let start = makeSchedule(hour: 22, minute: 0)
    let stop = makeSchedule(hour: 6, minute: 0)
    let now = date(hour: 3, minute: 0)
    let stoppedAt = date(hour: 22, minute: 30, dayOffset: -1)

    XCTAssertFalse(
      start.shouldBeActiveNow(
        stopSchedule: stop, lastStoppedAt: stoppedAt, on: now, calendar: calendar)
    )
  }

  func testGivenOvernightBetweenWindows_WhenCheckingActive_ThenReturnsFalse() {
    let start = makeSchedule(hour: 22, minute: 0)
    let stop = makeSchedule(hour: 6, minute: 0)
    let now = date(hour: 12, minute: 0)

    XCTAssertFalse(
      start.shouldBeActiveNow(
        stopSchedule: stop, lastStoppedAt: nil, on: now, calendar: calendar)
    )
  }

  // MARK: - Same-day with stop

  func testGivenSameDayInsideWindow_WhenCheckingActive_ThenReturnsTrue() {
    let start = makeSchedule(hour: 10, minute: 0)
    let stop = makeSchedule(hour: 17, minute: 0)
    let now = date(hour: 14, minute: 0)

    XCTAssertTrue(
      start.shouldBeActiveNow(
        stopSchedule: stop, lastStoppedAt: nil, on: now, calendar: calendar)
    )
  }

  func testGivenSameDayAfterStop_WhenCheckingActive_ThenReturnsFalse() {
    let start = makeSchedule(hour: 10, minute: 0)
    let stop = makeSchedule(hour: 17, minute: 0)
    let now = date(hour: 18, minute: 0)

    XCTAssertFalse(
      start.shouldBeActiveNow(
        stopSchedule: stop, lastStoppedAt: nil, on: now, calendar: calendar)
    )
  }

  // MARK: - Overnight day check (window started yesterday)

  func testGivenOvernightAt0300YesterdayNotScheduled_WhenCheckingActive_ThenReturnsFalse() {
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
