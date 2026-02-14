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
    let now = Date()
    let calendar = Calendar.current
    let today = calendar.component(.weekday, from: now)
    let weekday = Weekday(rawValue: today)!

    let schedule = ProfileScheduleTime(
      days: [weekday], hour: 9, minute: 0, updatedAt: now
    )
    XCTAssertTrue(schedule.isTodayScheduled(now: now))
  }

  func testIsTodayScheduled_whenTodayNotInDays_returnsFalse() {
    let now = Date()
    let calendar = Calendar.current
    let today = calendar.component(.weekday, from: now)
    let otherDay = Weekday.allCases.first { $0.rawValue != today }!

    let schedule = ProfileScheduleTime(
      days: [otherDay], hour: 9, minute: 0, updatedAt: now
    )
    XCTAssertFalse(schedule.isTodayScheduled(now: now))
  }

  func testIsTodayScheduled_whenDaysEmpty_returnsFalse() {
    let schedule = ProfileScheduleTime(
      days: [], hour: 9, minute: 0, updatedAt: Date()
    )
    XCTAssertFalse(schedule.isTodayScheduled())
  }

  func testOlderThanOneMinute_whenOld_returnsTrue() {
    let now = Date()
    let schedule = ProfileScheduleTime(
      days: [.monday], hour: 9, minute: 0,
      updatedAt: now.addingTimeInterval(-61)
    )
    XCTAssertTrue(schedule.olderThanOneMinute(now: now))
  }

  func testOlderThanOneMinute_whenExactlyOneMinute_returnsFalse() {
    let now = Date()
    let schedule = ProfileScheduleTime(
      days: [.monday], hour: 9, minute: 0,
      updatedAt: now.addingTimeInterval(-60)
    )
    XCTAssertFalse(schedule.olderThanOneMinute(now: now))
  }

  func testOlderThanOneMinute_whenRecent_returnsFalse() {
    let now = Date()
    let schedule = ProfileScheduleTime(
      days: [.monday], hour: 9, minute: 0, updatedAt: now
    )
    XCTAssertFalse(schedule.olderThanOneMinute(now: now))
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

  // MARK: - nextScheduledStartTime tests

  func testNextScheduledStartTime_dailySchedule_beforeStartTime_returnsToday() {
    let now = Date()
    let calendar = Calendar.current

    // Build a schedule for "every day at 23:00"
    let schedule = ProfileScheduleTime(
      days: Weekday.allCases,
      hour: 23,
      minute: 0,
      updatedAt: now
    )

    // Set "now" to today at 10:00 (before 23:00)
    var components = calendar.dateComponents([.year, .month, .day], from: now)
    components.hour = 10
    components.minute = 0
    components.second = 0
    let morning = calendar.date(from: components)!

    let result = schedule.nextScheduledStartTime(after: morning, calendar: calendar)
    XCTAssertNotNil(result)

    // Should be today at 23:00
    let resultComponents = calendar.dateComponents(
      [.year, .month, .day, .hour, .minute], from: result!)
    let morningComponents = calendar.dateComponents([.year, .month, .day], from: morning)
    XCTAssertEqual(resultComponents.year, morningComponents.year)
    XCTAssertEqual(resultComponents.month, morningComponents.month)
    XCTAssertEqual(resultComponents.day, morningComponents.day)
    XCTAssertEqual(resultComponents.hour, 23)
    XCTAssertEqual(resultComponents.minute, 0)
  }

  func testNextScheduledStartTime_dailySchedule_afterStartTime_returnsTomorrow() {
    let now = Date()
    let calendar = Calendar.current

    let schedule = ProfileScheduleTime(
      days: Weekday.allCases,
      hour: 14,
      minute: 0,
      updatedAt: now
    )

    // Set "now" to today at 15:00 (after 14:00)
    var components = calendar.dateComponents([.year, .month, .day], from: now)
    components.hour = 15
    components.minute = 0
    components.second = 0
    let afternoon = calendar.date(from: components)!

    let result = schedule.nextScheduledStartTime(after: afternoon, calendar: calendar)
    XCTAssertNotNil(result)

    // Should be tomorrow at 14:00
    let tomorrow = calendar.date(byAdding: .day, value: 1, to: afternoon)!
    let resultComponents = calendar.dateComponents(
      [.year, .month, .day, .hour, .minute], from: result!)
    let tomorrowComponents = calendar.dateComponents([.year, .month, .day], from: tomorrow)
    XCTAssertEqual(resultComponents.year, tomorrowComponents.year)
    XCTAssertEqual(resultComponents.month, tomorrowComponents.month)
    XCTAssertEqual(resultComponents.day, tomorrowComponents.day)
    XCTAssertEqual(resultComponents.hour, 14)
    XCTAssertEqual(resultComponents.minute, 0)
  }

  func testNextScheduledStartTime_weekdaySchedule_skipsNonScheduledDays() {
    let now = Date()
    let calendar = Calendar.current

    // Build a date that is a known Wednesday at 15:00
    var wednesdayComponents = calendar.dateComponents(
      [.yearForWeekOfYear, .weekOfYear], from: now)
    wednesdayComponents.weekday = Weekday.wednesday.rawValue  // 4
    wednesdayComponents.hour = 15
    wednesdayComponents.minute = 0
    wednesdayComponents.second = 0
    let wednesday = calendar.date(from: wednesdayComponents)!

    // Schedule only on Fridays at 14:00
    let schedule = ProfileScheduleTime(
      days: [.friday],
      hour: 14,
      minute: 0,
      updatedAt: now
    )

    let result = schedule.nextScheduledStartTime(after: wednesday, calendar: calendar)
    XCTAssertNotNil(result)

    // Should be this Friday at 14:00 (2 days later)
    let resultComponents = calendar.dateComponents([.weekday, .hour, .minute], from: result!)
    XCTAssertEqual(resultComponents.weekday, Weekday.friday.rawValue)  // 6
    XCTAssertEqual(resultComponents.hour, 14)
    XCTAssertEqual(resultComponents.minute, 0)
  }

  func testNextScheduledStartTime_emptyDays_returnsNil() {
    let schedule = ProfileScheduleTime(
      days: [],
      hour: 14,
      minute: 0,
      updatedAt: Date()
    )
    XCTAssertNil(schedule.nextScheduledStartTime(after: Date()))
  }

  func testNextScheduledStartTime_exactlyAtStartTime_returnsTomorrow() {
    let now = Date()
    let calendar = Calendar.current

    let schedule = ProfileScheduleTime(
      days: Weekday.allCases,
      hour: 14,
      minute: 0,
      updatedAt: now
    )

    // Set "now" to exactly 14:00
    var components = calendar.dateComponents([.year, .month, .day], from: now)
    components.hour = 14
    components.minute = 0
    components.second = 0
    let exact = calendar.date(from: components)!

    let result = schedule.nextScheduledStartTime(after: exact, calendar: calendar)
    XCTAssertNotNil(result)

    // At exactly the start time, we're "not before" it, so next is tomorrow
    let tomorrow = calendar.date(byAdding: .day, value: 1, to: exact)!
    let resultDay = calendar.component(.day, from: result!)
    let tomorrowDay = calendar.component(.day, from: tomorrow)
    XCTAssertEqual(resultDay, tomorrowDay)
  }

  func testNextScheduledStartTime_dstSpringForwardGap_returnsNilInsteadOfCrashing() {
    // US Eastern: March 9, 2025 at 2:00 AM clocks jump to 3:00 AM
    // So 2:30 AM doesn't exist on that day
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!

    // Schedule at 2:30 AM daily
    let schedule = ProfileScheduleTime(
      days: Weekday.allCases,
      hour: 2,
      minute: 30,
      updatedAt: Date(timeIntervalSince1970: 0)
    )

    // "now" is March 9, 2025 at 1:00 AM EST (before the gap)
    var components = DateComponents()
    components.year = 2025
    components.month = 3
    components.day = 9
    components.hour = 1
    components.minute = 0
    components.second = 0
    let beforeGap = calendar.date(from: components)!

    // Should NOT crash — should return nil or skip to next valid day
    let result = schedule.nextScheduledStartTime(after: beforeGap, calendar: calendar)
    // Result could be nil (gap day skipped) or the next valid occurrence — either is fine
    // The key assertion: we didn't crash
    if let result = result {
      // If it returns a date, it should NOT be March 9 at 2:30 (that doesn't exist)
      let resultComponents = calendar.dateComponents([.month, .day, .hour], from: result)
      let isGapDay = resultComponents.month == 3 && resultComponents.day == 9
      if isGapDay {
        // If it picked March 9, the hour should have been adjusted (not 2:30)
        XCTAssertNotEqual(
          resultComponents.hour, 2,
          "Should not return a time in the DST gap")
      }
    }
  }

  // MARK: - scheduledStartTime(on:) tests

  func testScheduledStartTime_returnsCorrectTimeForToday() {
    let now = Date()
    let calendar = Calendar.current
    let schedule = ProfileScheduleTime(
      days: Weekday.allCases, hour: 14, minute: 30, updatedAt: now
    )

    let result = schedule.scheduledStartTime(on: now, calendar: calendar)
    XCTAssertNotNil(result)

    let components = calendar.dateComponents([.hour, .minute, .second], from: result!)
    XCTAssertEqual(components.hour, 14)
    XCTAssertEqual(components.minute, 30)
    XCTAssertEqual(components.second, 0)
  }

  func testScheduledStartTime_preservesDateComponents() {
    let calendar = Calendar.current
    var dateComponents = DateComponents()
    dateComponents.year = 2026
    dateComponents.month = 2
    dateComponents.day = 14
    dateComponents.hour = 8
    dateComponents.minute = 0
    let specificDate = calendar.date(from: dateComponents)!

    let schedule = ProfileScheduleTime(
      days: Weekday.allCases, hour: 10, minute: 0, updatedAt: specificDate
    )

    let result = schedule.scheduledStartTime(on: specificDate, calendar: calendar)
    XCTAssertNotNil(result)

    let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: result!)
    XCTAssertEqual(c.year, 2026)
    XCTAssertEqual(c.month, 2)
    XCTAssertEqual(c.day, 14)
    XCTAssertEqual(c.hour, 10)
    XCTAssertEqual(c.minute, 0)
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
