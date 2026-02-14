// FoqosTests/ScheduleSuppressionTests.swift
import XCTest

@testable import FamilyFoqos

final class ScheduleSuppressionTests: XCTestCase {
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

  // MARK: - shouldSuppressStart tests

  /// Manual stop then re-registration: stopped at 10:05, DA fires at 10:06.
  /// Today's start (10:00) <= stoppedAt (10:05) → suppress.
  func testGivenStoppedAfterStart_WhenDAFires_ThenSuppresses() {
    let now = today(hour: 10, minute: 6)
    let stoppedAt = today(hour: 10, minute: 5)
    let schedule = ProfileScheduleTime(
      days: Weekday.allCases, hour: 10, minute: 0, updatedAt: Date()
    )

    XCTAssertTrue(
      schedule.shouldSuppressStart(lastStoppedAt: stoppedAt, on: now, calendar: calendar)
    )
  }

  /// Next day fires normally: stopped yesterday at 10:05, fires today at 10:00.
  /// Today's 10:00 > yesterday's 10:05 (full Date comparison) → don't suppress.
  func testGivenStoppedYesterday_WhenDAFiresToday_ThenDoesNotSuppress() {
    let now = today(hour: 10, minute: 0)
    let stoppedAt = yesterday(hour: 10, minute: 5)
    let schedule = ProfileScheduleTime(
      days: Weekday.allCases, hour: 10, minute: 0, updatedAt: Date()
    )

    XCTAssertFalse(
      schedule.shouldSuppressStart(lastStoppedAt: stoppedAt, on: now, calendar: calendar)
    )
  }

  /// Edit schedule to earlier time: stopped at 10:05, edit start to 09:50.
  /// Today's 09:50 <= 10:05 → suppress.
  func testGivenStoppedAfterEditedEarlierStart_WhenDAFires_ThenSuppresses() {
    let now = today(hour: 9, minute: 51)
    let stoppedAt = today(hour: 10, minute: 5)
    let schedule = ProfileScheduleTime(
      days: Weekday.allCases, hour: 9, minute: 50, updatedAt: Date()
    )

    XCTAssertTrue(
      schedule.shouldSuppressStart(lastStoppedAt: stoppedAt, on: now, calendar: calendar)
    )
  }

  /// Edit schedule to future time: stopped at 10:05, edit start to 14:00.
  /// Today's 14:00 > 10:05 → fire.
  func testGivenStoppedBeforeFutureStart_WhenDAFires_ThenDoesNotSuppress() {
    let now = today(hour: 14, minute: 0)
    let stoppedAt = today(hour: 10, minute: 5)
    let schedule = ProfileScheduleTime(
      days: Weekday.allCases, hour: 14, minute: 0, updatedAt: Date()
    )

    XCTAssertFalse(
      schedule.shouldSuppressStart(lastStoppedAt: stoppedAt, on: now, calendar: calendar)
    )
  }

  /// No previous stop: scheduleLastStoppedAt is nil → don't suppress.
  func testGivenNeverStopped_WhenDAFires_ThenDoesNotSuppress() {
    let now = today(hour: 10, minute: 0)
    let schedule = ProfileScheduleTime(
      days: Weekday.allCases, hour: 10, minute: 0, updatedAt: Date()
    )

    XCTAssertFalse(
      schedule.shouldSuppressStart(lastStoppedAt: nil, on: now, calendar: calendar)
    )
  }

  /// Stopped exactly at start time: 10:00 <= 10:00 → suppress.
  func testGivenStoppedAtExactStartTime_WhenDAFires_ThenSuppresses() {
    let now = today(hour: 10, minute: 1)
    let stoppedAt = today(hour: 10, minute: 0)
    let schedule = ProfileScheduleTime(
      days: Weekday.allCases, hour: 10, minute: 0, updatedAt: Date()
    )

    XCTAssertTrue(
      schedule.shouldSuppressStart(lastStoppedAt: stoppedAt, on: now, calendar: calendar)
    )
  }
}
