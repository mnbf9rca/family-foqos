// FoqosTests/ProfileScheduleTimeTests.swift
import XCTest

@testable import FamilyFoqos

final class ProfileScheduleTimeTests: XCTestCase {

  func testIsActiveWhenDaysNotEmpty() {
    let schedule = ProfileScheduleTime(days: [.monday], hour: 9, minute: 0, updatedAt: Date())
    XCTAssertTrue(schedule.isActive)
  }

  func testIsNotActiveWhenDaysEmpty() {
    let schedule = ProfileScheduleTime(days: [], hour: 9, minute: 0, updatedAt: Date())
    XCTAssertFalse(schedule.isActive)
  }

  func testIsTodayScheduled_whenTodayInDays_returnsTrue() {
    let calendar = Calendar.current
    let today = calendar.component(.weekday, from: Date())
    let weekday = Weekday(rawValue: today)!

    let schedule = ProfileScheduleTime(
      days: [weekday], hour: 9, minute: 0, updatedAt: Date()
    )
    XCTAssertTrue(schedule.isTodayScheduled())
  }

  func testIsTodayScheduled_whenTodayNotInDays_returnsFalse() {
    let calendar = Calendar.current
    let today = calendar.component(.weekday, from: Date())
    let otherDay = Weekday.allCases.first { $0.rawValue != today }!

    let schedule = ProfileScheduleTime(
      days: [otherDay], hour: 9, minute: 0, updatedAt: Date()
    )
    XCTAssertFalse(schedule.isTodayScheduled())
  }

  func testIsTodayScheduled_whenDaysEmpty_returnsFalse() {
    let schedule = ProfileScheduleTime(
      days: [], hour: 9, minute: 0, updatedAt: Date()
    )
    XCTAssertFalse(schedule.isTodayScheduled())
  }

  func testOlderThan15Minutes_whenOld_returnsTrue() {
    let schedule = ProfileScheduleTime(
      days: [.monday], hour: 9, minute: 0,
      updatedAt: Date().addingTimeInterval(-16 * 60)
    )
    XCTAssertTrue(schedule.olderThan15Minutes())
  }

  func testOlderThan15Minutes_whenRecent_returnsFalse() {
    let schedule = ProfileScheduleTime(
      days: [.monday], hour: 9, minute: 0, updatedAt: Date()
    )
    XCTAssertFalse(schedule.olderThan15Minutes())
  }

  func testFormattedTime_am() {
    let schedule = ProfileScheduleTime(
      days: [.monday], hour: 9, minute: 30, updatedAt: Date()
    )
    XCTAssertEqual(schedule.formattedTime, "9:30 AM")
  }

  func testFormattedTime_pm() {
    let schedule = ProfileScheduleTime(
      days: [.monday], hour: 14, minute: 5, updatedAt: Date()
    )
    XCTAssertEqual(schedule.formattedTime, "2:05 PM")
  }

  func testFormattedTime_noon() {
    let schedule = ProfileScheduleTime(
      days: [.monday], hour: 12, minute: 0, updatedAt: Date()
    )
    XCTAssertEqual(schedule.formattedTime, "12:00 PM")
  }

  func testFormattedTime_midnight() {
    let schedule = ProfileScheduleTime(
      days: [.monday], hour: 0, minute: 0, updatedAt: Date()
    )
    XCTAssertEqual(schedule.formattedTime, "12:00 AM")
  }

  func testCodableRoundTrip() throws {
    let original = ProfileScheduleTime(
      days: [.monday, .wednesday, .friday],
      hour: 14,
      minute: 30,
      updatedAt: Date(timeIntervalSince1970: 1_000_000)
    )

    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(ProfileScheduleTime.self, from: data)

    XCTAssertEqual(original.days, decoded.days)
    XCTAssertEqual(original.hour, decoded.hour)
    XCTAssertEqual(original.minute, decoded.minute)
  }
}
