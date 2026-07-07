import XCTest

@testable import FamilyFoqos

final class WrapAnchorIntervalTests: XCTestCase {
  private let cal = Calendar(identifier: .gregorian)

  private func date(_ h: Int, _ m: Int, _ s: Int) -> Date {
    var c = DateComponents()
    c.year = 2026
    c.month = 7
    c.day = 7
    c.hour = h
    c.minute = m
    c.second = s
    return cal.date(from: c)!
  }

  func testGivenSubMinuteOffsets_WhenBuildingWrapAnchor_ThenEndIsNeverEarlierThanDeadline() {
    for s in 0...59 {
      let deadline = date(12, 5, s)
      let now = date(12, 4, 30)
      let (start, end) = DeviceActivityCenterUtil.wrapAnchorInterval(
        endingAt: deadline, now: now, calendar: cal)
      let endMinuteOfDay = end.hour! * 60 + end.minute!
      let startMinuteOfDay = start.hour! * 60 + start.minute!
      let endAsDate = date(end.hour!, end.minute!, 0)
      XCTAssertGreaterThanOrEqual(
        endAsDate, date(12, 5, 0), "s=\(s): end must not precede the deadline minute")
      if s == 0 {
        XCTAssertEqual(endMinuteOfDay, 12 * 60 + 5, "exact boundary => no ceil")
      } else {
        XCTAssertEqual(endMinuteOfDay, 12 * 60 + 6, "sub-minute => ceil up")
      }
      XCTAssertEqual(startMinuteOfDay, (endMinuteOfDay + 1) % 1440)
    }
  }

  func testGivenDeadlineJustAfterMidnight_WhenBuildingWrapAnchor_ThenWrapsModulo1440() {
    let deadline = date(0, 3, 0)
    let (start, end) = DeviceActivityCenterUtil.wrapAnchorInterval(
      endingAt: deadline, now: date(0, 2, 30), calendar: cal)
    XCTAssertEqual(end.hour, 0)
    XCTAssertEqual(end.minute, 3)
    XCTAssertEqual(start.hour, 0)
    XCTAssertEqual(start.minute, 4)
  }
}
