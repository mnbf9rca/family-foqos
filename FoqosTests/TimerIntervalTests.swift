import XCTest

@testable import FamilyFoqos

final class TimerIntervalTests: XCTestCase {

  // MARK: - Helper

  /// Build a deterministic Date at the given hour:minute on a fixed reference day.
  /// Uses a hardcoded date to avoid midnight/DST boundary issues with `Date()`.
  private func referenceDateAt(hour: Int, minute: Int) -> Date {
    var components = DateComponents()
    components.year = 2025
    components.month = 6
    components.day = 15
    components.hour = hour
    components.minute = minute
    components.second = 0
    return Calendar(identifier: .gregorian).date(from: components)!
  }

  // MARK: - Same-day timer

  func testGivenAfternoonTime_WhenTimerEndsSameDay_ThenIntervalMatchesTimerWindow() {
    let now = referenceDateAt(hour: 14, minute: 30)  // 2:30 PM
    let (start, end) = DeviceActivityCenterUtil.getTimeIntervalStartAndEnd(
      from: 60, now: now
    )

    XCTAssertEqual(start.hour, 14)
    XCTAssertEqual(start.minute, 30)
    XCTAssertEqual(end.hour, 15)
    XCTAssertEqual(end.minute, 30)
  }

  // MARK: - Cross-midnight timer

  func testGivenLateNightTime_WhenTimerCrossesMidnight_ThenIntervalWrapsCorrectly() {
    let now = referenceDateAt(hour: 23, minute: 30)  // 11:30 PM
    let (start, end) = DeviceActivityCenterUtil.getTimeIntervalStartAndEnd(
      from: 120, now: now
    )

    // 23:30 + 120min = 01:30 next day
    XCTAssertEqual(start.hour, 23)
    XCTAssertEqual(start.minute, 30)
    XCTAssertEqual(end.hour, 1)
    XCTAssertEqual(end.minute, 30)
  }

  // MARK: - Exactly-midnight edge case

  func testGivenTimeOneHourBeforeMidnight_WhenTimerEndsExactlyAtMidnight_ThenEndIsZeroStartIsNow() {
    let now = referenceDateAt(hour: 23, minute: 0)  // 11:00 PM
    let (start, end) = DeviceActivityCenterUtil.getTimeIntervalStartAndEnd(
      from: 60, now: now
    )

    // 23:00 + 60min = 00:00 — start and end are distinct
    XCTAssertEqual(start.hour, 23)
    XCTAssertEqual(start.minute, 0)
    XCTAssertEqual(end.hour, 0)
    XCTAssertEqual(end.minute, 0)
  }

  // MARK: - Short timer, no crossing

  func testGivenMorningTime_WhenShortTimer_ThenIntervalMatchesTimerWindow() {
    let now = referenceDateAt(hour: 9, minute: 15)
    let (start, end) = DeviceActivityCenterUtil.getTimeIntervalStartAndEnd(
      from: 15, now: now
    )

    XCTAssertEqual(start.hour, 9)
    XCTAssertEqual(start.minute, 15)
    XCTAssertEqual(end.hour, 9)
    XCTAssertEqual(end.minute, 30)
  }

  // MARK: - #212 upper-bound clamp (24h zero-length collapse guard)

  func testGiven1440Minutes_WhenComputingInterval_ThenClampedToNonZeroWindow() {
    let now = referenceDateAt(hour: 8, minute: 0)
    let (start, end) = DeviceActivityCenterUtil.getTimeIntervalStartAndEnd(from: 1440, now: now)
    // 24h would collapse to 08:00–08:00; clamp to 1439 → ends 07:59.
    XCTAssertEqual(start.hour, 8)
    XCTAssertEqual(start.minute, 0)
    XCTAssertEqual(end.hour, 7)
    XCTAssertEqual(end.minute, 59)
    XCTAssertFalse(
      start.hour == end.hour && start.minute == end.minute,
      "Interval must never be zero-length"
    )
  }

  func testGiven1439Minutes_WhenComputingInterval_ThenEndIsOneMinuteBeforeStart() {
    let now = referenceDateAt(hour: 8, minute: 0)
    let (start, end) = DeviceActivityCenterUtil.getTimeIntervalStartAndEnd(from: 1439, now: now)
    XCTAssertEqual(start.hour, 8)
    XCTAssertEqual(start.minute, 0)
    XCTAssertEqual(end.hour, 7)
    XCTAssertEqual(end.minute, 59)
  }

  func testGivenMultipleOfDay_WhenComputingInterval_ThenClampedNonZero() {
    let now = referenceDateAt(hour: 8, minute: 0)
    let (start, end) = DeviceActivityCenterUtil.getTimeIntervalStartAndEnd(from: 2880, now: now)
    XCTAssertFalse(start.hour == end.hour && start.minute == end.minute)
    XCTAssertEqual(end.hour, 7)
    XCTAssertEqual(end.minute, 59)
  }
}
