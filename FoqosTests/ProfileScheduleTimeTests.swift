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
