// FoqosTests/WeekdayLocaleOrderTests.swift
import XCTest

@testable import FamilyFoqos

final class WeekdayLocaleOrderTests: XCTestCase {

  func testLocaleOrdered_sundayFirst_returnsSundayFirst() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.firstWeekday = 1  // Sunday
    let ordered = Weekday.localeOrdered(calendar: calendar)
    XCTAssertEqual(ordered.first, .sunday)
    XCTAssertEqual(ordered.last, .saturday)
    XCTAssertEqual(ordered.count, 7)
  }

  func testLocaleOrdered_mondayFirst_returnsMondayFirst() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.firstWeekday = 2  // Monday
    let ordered = Weekday.localeOrdered(calendar: calendar)
    XCTAssertEqual(ordered.first, .monday)
    XCTAssertEqual(ordered.last, .sunday)
    XCTAssertEqual(ordered.count, 7)
  }

  func testLocaleOrdered_saturdayFirst_returnsSaturdayFirst() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.firstWeekday = 7  // Saturday
    let ordered = Weekday.localeOrdered(calendar: calendar)
    XCTAssertEqual(ordered.first, .saturday)
    XCTAssertEqual(ordered.last, .friday)
    XCTAssertEqual(ordered.count, 7)
  }

  func testLocaleOrdered_containsAllDays() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.firstWeekday = 2
    let ordered = Weekday.localeOrdered(calendar: calendar)
    XCTAssertEqual(Set(ordered), Set(Weekday.allCases))
  }

  func testLocaleSorted_sortsSubsetByLocaleOrder() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.firstWeekday = 2  // Monday-first

    let days: [Weekday] = [.sunday, .wednesday, .monday]
    let sorted = days.localeSorted(calendar: calendar)
    // Monday-first order: Mon, Wed, Sun
    XCTAssertEqual(sorted, [.monday, .wednesday, .sunday])
  }

  func testLocaleSorted_sundayFirst_sortsSubsetByLocaleOrder() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.firstWeekday = 1  // Sunday-first

    let days: [Weekday] = [.friday, .sunday, .tuesday]
    let sorted = days.localeSorted(calendar: calendar)
    // Sunday-first order: Sun, Tue, Fri
    XCTAssertEqual(sorted, [.sunday, .tuesday, .friday])
  }
}
