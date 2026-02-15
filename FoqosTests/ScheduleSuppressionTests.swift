// FoqosTests/ScheduleSuppressionTests.swift
import XCTest

@testable import FamilyFoqos

/// Tests the suppression behavior within shouldBeActiveNow:
/// when a user manually stops a scheduled session, the same window should not restart.
final class ScheduleSuppressionTests: XCTestCase {
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

  // MARK: - Suppression through shouldBeActiveNow

  /// Manual stop then re-registration: stopped at 10:05, DA fires at 10:06.
  /// Window started at 10:00 which is <= stoppedAt (10:05) -> suppressed.
  func testGivenStoppedAfterStart_WhenDAFires_ThenSuppresses() {
    let now = date(hour: 10, minute: 6)
    let stoppedAt = date(hour: 10, minute: 5)
    let schedule = makeSchedule(hour: 10, minute: 0)

    XCTAssertFalse(
      schedule.shouldBeActiveNow(
        stopSchedule: nil, lastStoppedAt: stoppedAt, on: now, calendar: calendar)
    )
  }

  /// Next day fires normally: stopped yesterday at 10:05, fires today at 10:00.
  /// Today's window started at 10:00 today which is > yesterday's stoppedAt -> fires.
  func testGivenStoppedYesterday_WhenDAFiresToday_ThenDoesNotSuppress() {
    let now = date(hour: 10, minute: 0)
    let stoppedAt = date(hour: 10, minute: 5, dayOffset: -1)
    let schedule = makeSchedule(hour: 10, minute: 0)

    XCTAssertTrue(
      schedule.shouldBeActiveNow(
        stopSchedule: nil, lastStoppedAt: stoppedAt, on: now, calendar: calendar)
    )
  }

  /// Edit schedule to earlier time: stopped at 10:05, edit start to 09:50.
  /// Window started at 09:50 which is <= stoppedAt (10:05) -> suppressed.
  func testGivenStoppedAfterEditedEarlierStart_WhenDAFires_ThenSuppresses() {
    let now = date(hour: 9, minute: 51)
    let stoppedAt = date(hour: 10, minute: 5)
    let schedule = makeSchedule(hour: 9, minute: 50)

    XCTAssertFalse(
      schedule.shouldBeActiveNow(
        stopSchedule: nil, lastStoppedAt: stoppedAt, on: now, calendar: calendar)
    )
  }

  /// Edit schedule to future time: stopped at 10:05, edit start to 14:00.
  /// Window started at 14:00 which is > stoppedAt (10:05) -> fires.
  func testGivenStoppedBeforeFutureStart_WhenDAFires_ThenDoesNotSuppress() {
    let now = date(hour: 14, minute: 0)
    let stoppedAt = date(hour: 10, minute: 5)
    let schedule = makeSchedule(hour: 14, minute: 0)

    XCTAssertTrue(
      schedule.shouldBeActiveNow(
        stopSchedule: nil, lastStoppedAt: stoppedAt, on: now, calendar: calendar)
    )
  }

  /// No previous stop: scheduleLastStoppedAt is nil -> don't suppress.
  func testGivenNeverStopped_WhenDAFires_ThenDoesNotSuppress() {
    let now = date(hour: 10, minute: 0)
    let schedule = makeSchedule(hour: 10, minute: 0)

    XCTAssertTrue(
      schedule.shouldBeActiveNow(
        stopSchedule: nil, lastStoppedAt: nil, on: now, calendar: calendar)
    )
  }

  /// Stopped exactly at start time: window at 10:00 <= stoppedAt 10:00 -> suppressed.
  func testGivenStoppedAtExactStartTime_WhenDAFires_ThenSuppresses() {
    let now = date(hour: 10, minute: 1)
    let stoppedAt = date(hour: 10, minute: 0)
    let schedule = makeSchedule(hour: 10, minute: 0)

    XCTAssertFalse(
      schedule.shouldBeActiveNow(
        stopSchedule: nil, lastStoppedAt: stoppedAt, on: now, calendar: calendar)
    )
  }

  // MARK: - Overnight suppression

  /// Stopped at 22:30 yesterday, now 03:00 today. Overnight window started yesterday at 22:00.
  /// Window start (yesterday 22:00) <= stoppedAt (yesterday 22:30) -> suppressed.
  func testOvernight_stoppedYesterday_earlyMorningToday_suppresses() {
    let now = date(hour: 3, minute: 0)
    let stoppedAt = date(hour: 22, minute: 30, dayOffset: -1)
    let start = makeSchedule(hour: 22, minute: 0)
    let stop = makeSchedule(hour: 6, minute: 0)

    XCTAssertFalse(
      start.shouldBeActiveNow(
        stopSchedule: stop, lastStoppedAt: stoppedAt, on: now, calendar: calendar)
    )
  }

  /// Overnight: not stopped, at 03:00. Window started yesterday at 22:00. Should be active.
  func testOvernight_notStopped_earlyMorningToday_isActive() {
    let now = date(hour: 3, minute: 0)
    let start = makeSchedule(hour: 22, minute: 0)
    let stop = makeSchedule(hour: 6, minute: 0)

    XCTAssertTrue(
      start.shouldBeActiveNow(
        stopSchedule: stop, lastStoppedAt: nil, on: now, calendar: calendar)
    )
  }
}
