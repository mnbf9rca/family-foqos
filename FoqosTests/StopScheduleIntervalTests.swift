import XCTest

@testable import FamilyFoqos

final class StopScheduleIntervalTests: XCTestCase {

  func testGivenStopBeforeMidnightPlus15_WhenComputingInterval_ThenWindowIsHonorable() {
    let (start, end) = DeviceActivityCenterUtil.stopScheduleInterval(stopHour: 0, stopMinute: 10)
    // Anchor moves to 00:11 so the wrap window is ~1439 min, still ending at 00:10.
    XCTAssertEqual(end.hour, 0)
    XCTAssertEqual(end.minute, 10)
    XCTAssertEqual(start.hour, 0)
    XCTAssertEqual(start.minute, 11)
    XCTAssertFalse(start.hour == end.hour && start.minute == end.minute)
  }

  func testGivenStopAtExactlyMidnight_WhenComputingInterval_ThenNotZeroLength() {
    let (start, end) = DeviceActivityCenterUtil.stopScheduleInterval(stopHour: 0, stopMinute: 0)
    XCTAssertEqual(end.hour, 0)
    XCTAssertEqual(end.minute, 0)
    XCTAssertEqual(start.hour, 0)
    XCTAssertEqual(start.minute, 1)
    XCTAssertFalse(start.hour == end.hour && start.minute == end.minute)
  }

  func testGivenStopAt0015_WhenComputingInterval_ThenKeepsMidnightAnchor() {
    let (start, end) = DeviceActivityCenterUtil.stopScheduleInterval(stopHour: 0, stopMinute: 15)
    XCTAssertEqual(start.hour, 0)
    XCTAssertEqual(start.minute, 0)
    XCTAssertEqual(end.hour, 0)
    XCTAssertEqual(end.minute, 15)
  }

  func testGivenStopMidMorning_WhenComputingInterval_ThenKeepsMidnightAnchor() {
    let (start, end) = DeviceActivityCenterUtil.stopScheduleInterval(stopHour: 9, stopMinute: 0)
    XCTAssertEqual(start.hour, 0)
    XCTAssertEqual(start.minute, 0)
    XCTAssertEqual(end.hour, 9)
    XCTAssertEqual(end.minute, 0)
  }
}
