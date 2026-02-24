// FoqosTests/ProfileScheduleTimeTests.swift
import XCTest

@testable import FamilyFoqos

final class ProfileScheduleTimeTests: XCTestCase {
  private let calendar = Calendar(identifier: .gregorian)

  // Fixed reference: Monday 2026-06-15 at noon (weekday 2 = Monday)
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

  func testGivenDaysNotEmpty_WhenCheckingIsActive_ThenReturnsTrue() {
    let schedule = ProfileScheduleTime(
      days: [.monday], hour: 9, minute: 0, updatedAt: .distantPast)
    XCTAssertTrue(schedule.isActive)
  }

  func testGivenDaysEmpty_WhenCheckingIsActive_ThenReturnsFalse() {
    let schedule = ProfileScheduleTime(
      days: [], hour: 9, minute: 0, updatedAt: .distantPast)
    XCTAssertFalse(schedule.isActive)
  }

  func testGivenTodayInDays_WhenCheckingIsTodayScheduled_ThenReturnsTrue() {
    // referenceDate is Monday
    let schedule = ProfileScheduleTime(
      days: [.monday], hour: 9, minute: 0, updatedAt: .distantPast
    )
    XCTAssertTrue(schedule.isTodayScheduled(now: referenceDate))
  }

  func testGivenTodayNotInDays_WhenCheckingIsTodayScheduled_ThenReturnsFalse() {
    // referenceDate is Monday, schedule for Tuesday
    let schedule = ProfileScheduleTime(
      days: [.tuesday], hour: 9, minute: 0, updatedAt: .distantPast
    )
    XCTAssertFalse(schedule.isTodayScheduled(now: referenceDate))
  }

  func testGivenDaysEmpty_WhenCheckingIsTodayScheduled_ThenReturnsFalse() {
    let schedule = ProfileScheduleTime(
      days: [], hour: 9, minute: 0, updatedAt: .distantPast
    )
    XCTAssertFalse(schedule.isTodayScheduled(now: referenceDate))
  }

  func testGivenUpdatedOverOneMinuteAgo_WhenCheckingOlderThanOneMinute_ThenReturnsTrue() {
    let now = referenceDate
    let schedule = ProfileScheduleTime(
      days: [.monday], hour: 9, minute: 0,
      updatedAt: now.addingTimeInterval(-61)
    )
    XCTAssertTrue(schedule.olderThanOneMinute(now: now))
  }

  func testGivenUpdatedExactlyOneMinuteAgo_WhenCheckingOlderThanOneMinute_ThenReturnsFalse() {
    let now = referenceDate
    let schedule = ProfileScheduleTime(
      days: [.monday], hour: 9, minute: 0,
      updatedAt: now.addingTimeInterval(-60)
    )
    XCTAssertFalse(schedule.olderThanOneMinute(now: now))
  }

  func testGivenJustUpdated_WhenCheckingOlderThanOneMinute_ThenReturnsFalse() {
    let now = referenceDate
    let schedule = ProfileScheduleTime(
      days: [.monday], hour: 9, minute: 0, updatedAt: now
    )
    XCTAssertFalse(schedule.olderThanOneMinute(now: now))
  }

  func testGivenMorningHour_WhenFormatting_ThenShowsAM() {
    let schedule = ProfileScheduleTime(
      days: [.monday], hour: 9, minute: 30, updatedAt: .distantPast
    )
    XCTAssertEqual(schedule.formattedTime, "9:30 AM")
  }

  func testGivenAfternoonHour_WhenFormatting_ThenShowsPM() {
    let schedule = ProfileScheduleTime(
      days: [.monday], hour: 14, minute: 5, updatedAt: .distantPast
    )
    XCTAssertEqual(schedule.formattedTime, "2:05 PM")
  }

  func testGivenNoonHour_WhenFormatting_ThenShowsTwelvePM() {
    let schedule = ProfileScheduleTime(
      days: [.monday], hour: 12, minute: 0, updatedAt: .distantPast
    )
    XCTAssertEqual(schedule.formattedTime, "12:00 PM")
  }

  func testGivenMidnightHour_WhenFormatting_ThenShowsTwelveAM() {
    let schedule = ProfileScheduleTime(
      days: [.monday], hour: 0, minute: 0, updatedAt: .distantPast
    )
    XCTAssertEqual(schedule.formattedTime, "12:00 AM")
  }

  // MARK: - nextScheduledStartTime tests

  func testGivenDailyScheduleBeforeStartTime_WhenGettingNextStart_ThenReturnsToday() {
    // Schedule for every day at 23:00, "now" is 10:00 (before 23:00)
    let schedule = ProfileScheduleTime(
      days: Weekday.allCases,
      hour: 23,
      minute: 0,
      updatedAt: .distantPast
    )

    let morning = date(hour: 10, minute: 0)

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

  func testGivenDailyScheduleAfterStartTime_WhenGettingNextStart_ThenReturnsTomorrow() {
    let schedule = ProfileScheduleTime(
      days: Weekday.allCases,
      hour: 14,
      minute: 0,
      updatedAt: .distantPast
    )

    // "now" is 15:00 (after 14:00)
    let afternoon = date(hour: 15, minute: 0)

    let result = schedule.nextScheduledStartTime(after: afternoon, calendar: calendar)
    XCTAssertNotNil(result)

    // Should be tomorrow at 14:00
    let tomorrow = date(hour: 14, minute: 0, dayOffset: 1)
    let resultComponents = calendar.dateComponents(
      [.year, .month, .day, .hour, .minute], from: result!)
    let tomorrowComponents = calendar.dateComponents([.year, .month, .day], from: tomorrow)
    XCTAssertEqual(resultComponents.year, tomorrowComponents.year)
    XCTAssertEqual(resultComponents.month, tomorrowComponents.month)
    XCTAssertEqual(resultComponents.day, tomorrowComponents.day)
    XCTAssertEqual(resultComponents.hour, 14)
    XCTAssertEqual(resultComponents.minute, 0)
  }

  func testGivenWeekdaySchedule_WhenGettingNextStart_ThenSkipsNonScheduledDays() {
    // referenceDate is Monday. Use dayOffset: +2 to get Wednesday at 15:00
    let wednesday = date(hour: 15, minute: 0, dayOffset: 2)

    // Schedule only on Fridays at 14:00
    let schedule = ProfileScheduleTime(
      days: [.friday],
      hour: 14,
      minute: 0,
      updatedAt: .distantPast
    )

    let result = schedule.nextScheduledStartTime(after: wednesday, calendar: calendar)
    XCTAssertNotNil(result)

    // Should be this Friday at 14:00 (2 days after Wednesday)
    let resultComponents = calendar.dateComponents([.weekday, .hour, .minute], from: result!)
    XCTAssertEqual(resultComponents.weekday, Weekday.friday.rawValue)  // 6
    XCTAssertEqual(resultComponents.hour, 14)
    XCTAssertEqual(resultComponents.minute, 0)
  }

  func testGivenEmptyDays_WhenGettingNextStart_ThenReturnsNil() {
    let schedule = ProfileScheduleTime(
      days: [],
      hour: 14,
      minute: 0,
      updatedAt: .distantPast
    )
    XCTAssertNil(schedule.nextScheduledStartTime(after: referenceDate))
  }

  func testGivenExactlyAtStartTime_WhenGettingNextStart_ThenReturnsTomorrow() {
    let schedule = ProfileScheduleTime(
      days: Weekday.allCases,
      hour: 14,
      minute: 0,
      updatedAt: .distantPast
    )

    // Set "now" to exactly 14:00
    let exact = date(hour: 14, minute: 0)

    let result = schedule.nextScheduledStartTime(after: exact, calendar: calendar)
    XCTAssertNotNil(result)

    // At exactly the start time, we're "not before" it, so next is tomorrow
    let tomorrow = date(hour: 14, minute: 0, dayOffset: 1)
    let resultDay = calendar.component(.day, from: result!)
    let tomorrowDay = calendar.component(.day, from: tomorrow)
    XCTAssertEqual(resultDay, tomorrowDay)
  }

  func testGivenDSTSpringForwardGap_WhenGettingNextStart_ThenDoesNotCrash() {
    // US Eastern: March 9, 2025 at 2:00 AM clocks jump to 3:00 AM
    // So 2:30 AM doesn't exist on that day
    var easternCalendar = Calendar(identifier: .gregorian)
    easternCalendar.timeZone = TimeZone(identifier: "America/New_York")!

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
    let beforeGap = easternCalendar.date(from: components)!

    // Should NOT crash — should return nil or skip to next valid day
    let result = schedule.nextScheduledStartTime(after: beforeGap, calendar: easternCalendar)
    // Result could be nil (gap day skipped) or the next valid occurrence — either is fine
    // The key assertion: we didn't crash
    if let result = result {
      // If it returns a date, it should NOT be March 9 at 2:30 (that doesn't exist)
      let resultComponents = easternCalendar.dateComponents([.month, .day, .hour], from: result)
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

  func testGivenDailySchedule_WhenGettingStartTimeForToday_ThenReturnsCorrectTime() {
    let now = referenceDate
    let schedule = ProfileScheduleTime(
      days: Weekday.allCases, hour: 14, minute: 30, updatedAt: .distantPast
    )

    let result = schedule.scheduledStartTime(on: now, calendar: calendar)
    XCTAssertNotNil(result)

    let components = calendar.dateComponents([.hour, .minute, .second], from: result!)
    XCTAssertEqual(components.hour, 14)
    XCTAssertEqual(components.minute, 30)
    XCTAssertEqual(components.second, 0)
  }

  func testGivenSpecificDate_WhenGettingStartTime_ThenPreservesDateComponents() {
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

  func testGivenSchedule_WhenEncodingAndDecoding_ThenPreservesValues() throws {
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
