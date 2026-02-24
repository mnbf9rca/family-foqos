// FoqosTests/ActiveWindowTests.swift
import XCTest

@testable import FamilyFoqos

final class ActiveWindowTests: XCTestCase {
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

  private func date(hour: Int, minute: Int, dayOffset: Int = 0) -> Date {
    var c = calendar.dateComponents([.year, .month, .day], from: referenceDate)
    c.hour = hour
    c.minute = minute
    c.second = 0
    let base = calendar.date(from: c)!
    return dayOffset == 0 ? base : calendar.date(byAdding: .day, value: dayOffset, to: base)!
  }

  private func makeSchedule(hour: Int, minute: Int) -> ProfileScheduleTime {
    ProfileScheduleTime(
      days: Weekday.allCases, hour: hour, minute: minute,
      updatedAt: .distantPast
    )
  }

  // MARK: - Start-only (no stop schedule)

  func testGivenStartOnlySchedulePastStart_WhenCheckingActiveWindow_ThenReturnsTodayStart() {
    let start = makeSchedule(hour: 10, minute: 0)
    let now = date(hour: 14, minute: 0)

    let result = start.activeWindowStart(on: now, stopSchedule: nil, calendar: calendar)
    XCTAssertNotNil(result)

    let c = calendar.dateComponents([.hour, .minute], from: result!)
    XCTAssertEqual(c.hour, 10)
    XCTAssertEqual(c.minute, 0)
  }

  func testGivenStartOnlyScheduleBeforeStart_WhenCheckingActiveWindow_ThenReturnsNil() {
    let start = makeSchedule(hour: 14, minute: 0)
    let now = date(hour: 9, minute: 0)

    XCTAssertNil(start.activeWindowStart(on: now, stopSchedule: nil, calendar: calendar))
  }

  // MARK: - Same-day (start < stop)

  func testGivenSameDayScheduleInsideWindow_WhenCheckingActiveWindow_ThenReturnsTodayStart() {
    let start = makeSchedule(hour: 10, minute: 0)
    let stop = makeSchedule(hour: 17, minute: 0)
    let now = date(hour: 14, minute: 0)

    let result = start.activeWindowStart(on: now, stopSchedule: stop, calendar: calendar)
    XCTAssertNotNil(result)

    let c = calendar.dateComponents([.hour, .minute], from: result!)
    XCTAssertEqual(c.hour, 10)
    XCTAssertEqual(c.minute, 0)
  }

  func testGivenSameDayScheduleAfterStop_WhenCheckingActiveWindow_ThenReturnsNil() {
    let start = makeSchedule(hour: 10, minute: 0)
    let stop = makeSchedule(hour: 17, minute: 0)
    let now = date(hour: 18, minute: 0)

    XCTAssertNil(start.activeWindowStart(on: now, stopSchedule: stop, calendar: calendar))
  }

  func testGivenSameDayScheduleBeforeStart_WhenCheckingActiveWindow_ThenReturnsNil() {
    let start = makeSchedule(hour: 10, minute: 0)
    let stop = makeSchedule(hour: 17, minute: 0)
    let now = date(hour: 9, minute: 0)

    XCTAssertNil(start.activeWindowStart(on: now, stopSchedule: stop, calendar: calendar))
  }

  // MARK: - Overnight (start >= stop)

  func testGivenOvernightScheduleAfterStart_WhenCheckingActiveWindow_ThenReturnsTodayStart() {
    let start = makeSchedule(hour: 22, minute: 0)
    let stop = makeSchedule(hour: 6, minute: 0)
    let now = date(hour: 23, minute: 0)

    let result = start.activeWindowStart(on: now, stopSchedule: stop, calendar: calendar)
    XCTAssertNotNil(result)

    let c = calendar.dateComponents([.hour, .minute], from: result!)
    XCTAssertEqual(c.hour, 22)
    XCTAssertEqual(c.minute, 0)
  }

  func testGivenOvernightScheduleEarlyMorning_WhenCheckingActiveWindow_ThenReturnsYesterdayStart() {
    let start = makeSchedule(hour: 22, minute: 0)
    let stop = makeSchedule(hour: 6, minute: 0)
    let now = date(hour: 3, minute: 0)

    let result = start.activeWindowStart(on: now, stopSchedule: stop, calendar: calendar)
    XCTAssertNotNil(result)

    // Should be yesterday at 22:00
    let expected = date(hour: 22, minute: 0, dayOffset: -1)
    let resultDay = calendar.component(.day, from: result!)
    let expectedDay = calendar.component(.day, from: expected)
    XCTAssertEqual(resultDay, expectedDay)

    let c = calendar.dateComponents([.hour, .minute], from: result!)
    XCTAssertEqual(c.hour, 22)
    XCTAssertEqual(c.minute, 0)
  }

  func testGivenOvernightScheduleBetweenWindows_WhenCheckingActiveWindow_ThenReturnsNil() {
    let start = makeSchedule(hour: 22, minute: 0)
    let stop = makeSchedule(hour: 6, minute: 0)
    let now = date(hour: 12, minute: 0)

    XCTAssertNil(start.activeWindowStart(on: now, stopSchedule: stop, calendar: calendar))
  }

  func testGivenOvernightScheduleExactlyAtStop_WhenCheckingActiveWindow_ThenReturnsNil() {
    let start = makeSchedule(hour: 22, minute: 0)
    let stop = makeSchedule(hour: 6, minute: 0)
    let now = date(hour: 6, minute: 0)

    XCTAssertNil(start.activeWindowStart(on: now, stopSchedule: stop, calendar: calendar))
  }
}
