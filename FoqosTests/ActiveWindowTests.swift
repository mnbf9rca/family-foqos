// FoqosTests/ActiveWindowTests.swift
import XCTest

@testable import FamilyFoqos

final class ActiveWindowTests: XCTestCase {
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

  private func makeSchedule(hour: Int, minute: Int) -> ProfileScheduleTime {
    ProfileScheduleTime(
      days: Weekday.allCases, hour: hour, minute: minute,
      updatedAt: Date().addingTimeInterval(-120)
    )
  }

  // MARK: - Start-only (no stop schedule)

  func testStartOnly_pastStart_returnsToday() {
    let start = makeSchedule(hour: 10, minute: 0)
    let now = today(hour: 14, minute: 0)

    let result = start.activeWindowStart(on: now, stopSchedule: nil, calendar: calendar)
    XCTAssertNotNil(result)

    let c = calendar.dateComponents([.hour, .minute], from: result!)
    XCTAssertEqual(c.hour, 10)
    XCTAssertEqual(c.minute, 0)
  }

  func testStartOnly_beforeStart_returnsNil() {
    let start = makeSchedule(hour: 14, minute: 0)
    let now = today(hour: 9, minute: 0)

    XCTAssertNil(start.activeWindowStart(on: now, stopSchedule: nil, calendar: calendar))
  }

  // MARK: - Same-day (start < stop)

  func testSameDay_insideWindow_returnsTodayStart() {
    let start = makeSchedule(hour: 10, minute: 0)
    let stop = makeSchedule(hour: 17, minute: 0)
    let now = today(hour: 14, minute: 0)

    let result = start.activeWindowStart(on: now, stopSchedule: stop, calendar: calendar)
    XCTAssertNotNil(result)

    let c = calendar.dateComponents([.hour, .minute], from: result!)
    XCTAssertEqual(c.hour, 10)
    XCTAssertEqual(c.minute, 0)
  }

  func testSameDay_afterStop_returnsNil() {
    let start = makeSchedule(hour: 10, minute: 0)
    let stop = makeSchedule(hour: 17, minute: 0)
    let now = today(hour: 18, minute: 0)

    XCTAssertNil(start.activeWindowStart(on: now, stopSchedule: stop, calendar: calendar))
  }

  func testSameDay_beforeStart_returnsNil() {
    let start = makeSchedule(hour: 10, minute: 0)
    let stop = makeSchedule(hour: 17, minute: 0)
    let now = today(hour: 9, minute: 0)

    XCTAssertNil(start.activeWindowStart(on: now, stopSchedule: stop, calendar: calendar))
  }

  // MARK: - Overnight (start >= stop)

  func testOvernight_afterStart_returnsTodayStart() {
    let start = makeSchedule(hour: 22, minute: 0)
    let stop = makeSchedule(hour: 6, minute: 0)
    let now = today(hour: 23, minute: 0)

    let result = start.activeWindowStart(on: now, stopSchedule: stop, calendar: calendar)
    XCTAssertNotNil(result)

    let c = calendar.dateComponents([.hour, .minute], from: result!)
    XCTAssertEqual(c.hour, 22)
    XCTAssertEqual(c.minute, 0)
  }

  func testOvernight_earlyMorning_returnsYesterdayStart() {
    let start = makeSchedule(hour: 22, minute: 0)
    let stop = makeSchedule(hour: 6, minute: 0)
    let now = today(hour: 3, minute: 0)

    let result = start.activeWindowStart(on: now, stopSchedule: stop, calendar: calendar)
    XCTAssertNotNil(result)

    // Should be yesterday at 22:00
    let expected = yesterday(hour: 22, minute: 0)
    let resultDay = calendar.component(.day, from: result!)
    let expectedDay = calendar.component(.day, from: expected)
    XCTAssertEqual(resultDay, expectedDay)

    let c = calendar.dateComponents([.hour, .minute], from: result!)
    XCTAssertEqual(c.hour, 22)
    XCTAssertEqual(c.minute, 0)
  }

  func testOvernight_betweenWindows_returnsNil() {
    let start = makeSchedule(hour: 22, minute: 0)
    let stop = makeSchedule(hour: 6, minute: 0)
    let now = today(hour: 12, minute: 0)

    XCTAssertNil(start.activeWindowStart(on: now, stopSchedule: stop, calendar: calendar))
  }

  func testOvernight_exactlyAtStop_returnsNil() {
    let start = makeSchedule(hour: 22, minute: 0)
    let stop = makeSchedule(hour: 6, minute: 0)
    let now = today(hour: 6, minute: 0)

    XCTAssertNil(start.activeWindowStart(on: now, stopSchedule: stop, calendar: calendar))
  }
}
