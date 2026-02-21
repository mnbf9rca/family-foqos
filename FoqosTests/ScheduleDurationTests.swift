import XCTest

@testable import FamilyFoqos

final class ScheduleDurationTests: XCTestCase {

  private func makeSchedule(
    startHour: Int, startMinute: Int, endHour: Int, endMinute: Int
  ) -> BlockedProfileSchedule {
    BlockedProfileSchedule(
      days: [.monday],
      startHour: startHour,
      startMinute: startMinute,
      endHour: endHour,
      endMinute: endMinute
    )
  }

  func testGivenSameDaySchedule_WhenCalculatingDuration_ThenReturnsPositiveSeconds() {
    let schedule = makeSchedule(startHour: 9, startMinute: 0, endHour: 17, endMinute: 0)
    XCTAssertEqual(schedule.totalDurationInSeconds, 28800)  // 8 hours
  }

  func testGivenOvernightSchedule_WhenCalculatingDuration_ThenReturnsPositiveSeconds() {
    let schedule = makeSchedule(startHour: 22, startMinute: 0, endHour: 6, endMinute: 0)
    XCTAssertEqual(schedule.totalDurationInSeconds, 28800)  // 8 hours
  }

  func testGivenOvernightWithMinutes_WhenCalculatingDuration_ThenReturnsPositiveSeconds() {
    let schedule = makeSchedule(startHour: 23, startMinute: 30, endHour: 6, endMinute: 30)
    XCTAssertEqual(schedule.totalDurationInSeconds, 25200)  // 7 hours
  }

  func testGivenMidnightToMidnight_WhenCalculatingDuration_ThenReturnsZero() {
    let schedule = makeSchedule(startHour: 0, startMinute: 0, endHour: 0, endMinute: 0)
    XCTAssertEqual(schedule.totalDurationInSeconds, 0)
  }
}
