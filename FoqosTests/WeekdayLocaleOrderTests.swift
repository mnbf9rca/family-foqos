// FoqosTests/WeekdayLocaleOrderTests.swift
import XCTest

@testable import FamilyFoqos

final class WeekdayLocaleOrderTests: XCTestCase {

  func testGivenSundayFirstLocale_WhenOrdering_ThenSundayIsFirst() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.firstWeekday = 1  // Sunday
    let ordered = Weekday.localeOrdered(calendar: calendar)
    XCTAssertEqual(ordered.first, .sunday)
    XCTAssertEqual(ordered.last, .saturday)
    XCTAssertEqual(ordered.count, 7)
  }

  func testGivenMondayFirstLocale_WhenOrdering_ThenMondayIsFirst() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.firstWeekday = 2  // Monday
    let ordered = Weekday.localeOrdered(calendar: calendar)
    XCTAssertEqual(ordered.first, .monday)
    XCTAssertEqual(ordered.last, .sunday)
    XCTAssertEqual(ordered.count, 7)
  }

  func testGivenSaturdayFirstLocale_WhenOrdering_ThenSaturdayIsFirst() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.firstWeekday = 7  // Saturday
    let ordered = Weekday.localeOrdered(calendar: calendar)
    XCTAssertEqual(ordered.first, .saturday)
    XCTAssertEqual(ordered.last, .friday)
    XCTAssertEqual(ordered.count, 7)
  }

  func testGivenAnyLocale_WhenOrdering_ThenContainsAllDays() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.firstWeekday = 2
    let ordered = Weekday.localeOrdered(calendar: calendar)
    XCTAssertEqual(Set(ordered), Set(Weekday.allCases))
  }

  func testGivenMondayFirstLocale_WhenSortingSubset_ThenSortsByLocaleOrder() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.firstWeekday = 2  // Monday-first

    let days: [Weekday] = [.sunday, .wednesday, .monday]
    let sorted = days.localeSorted(calendar: calendar)
    // Monday-first order: Mon, Wed, Sun
    XCTAssertEqual(sorted, [.monday, .wednesday, .sunday])
  }

  func testGivenSundayFirstLocale_WhenSortingSubset_ThenSortsByLocaleOrder() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.firstWeekday = 1  // Sunday-first

    let days: [Weekday] = [.friday, .sunday, .tuesday]
    let sorted = days.localeSorted(calendar: calendar)
    // Sunday-first order: Sun, Tue, Fri
    XCTAssertEqual(sorted, [.sunday, .tuesday, .friday])
  }

  // MARK: - compactDaysText

  func testGivenAllDays_WhenGettingCompactText_ThenReturnsEveryDay() {
    let days = Weekday.allCases
    XCTAssertEqual(days.compactDaysText(), "Every day")
  }

  func testGivenWeekdaysOnly_WhenGettingCompactText_ThenReturnsWeekdays() {
    let days: [Weekday] = [.monday, .tuesday, .wednesday, .thursday, .friday]
    XCTAssertEqual(days.compactDaysText(), "Weekdays")
  }

  func testGivenWeekendsOnly_WhenGettingCompactText_ThenReturnsWeekends() {
    let days: [Weekday] = [.saturday, .sunday]
    XCTAssertEqual(days.compactDaysText(), "Weekends")
  }

  func testGivenDaySubset_WhenGettingCompactText_ThenReturnsShortLabels() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.firstWeekday = 2  // Monday-first
    let days: [Weekday] = [.sunday, .wednesday, .monday]
    XCTAssertEqual(days.compactDaysText(calendar: calendar), "Mo We Su")
  }
}
