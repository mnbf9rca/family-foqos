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
    return Calendar.current.date(from: components)!
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
}
