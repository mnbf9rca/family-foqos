import XCTest

@testable import FamilyFoqos

final class BreakDurationCalculableTests: XCTestCase {

  // Simple concrete type for testing the protocol default
  private struct TestBreakData: BreakDurationCalculable {
    var breakStartTime: Date?
    var breakEndTime: Date?
  }

  func testGivenNoBreak_WhenCalculating_ThenReturnsZero() {
    let data = TestBreakData(breakStartTime: nil, breakEndTime: nil)
    XCTAssertEqual(data.calculateBreakDuration(), 0)
  }

  func testGivenActiveBreak_WhenCalculating_ThenReturnsZero() {
    let data = TestBreakData(
      breakStartTime: Date(),
      breakEndTime: nil
    )
    XCTAssertEqual(data.calculateBreakDuration(), 0)
  }

  func testGivenCompletedBreak_WhenCalculating_ThenReturnsDuration() {
    let start = Date()
    let end = start.addingTimeInterval(600)  // 10 minutes
    let data = TestBreakData(
      breakStartTime: start,
      breakEndTime: end
    )
    XCTAssertEqual(data.calculateBreakDuration(), 600, accuracy: 0.001)
  }

  func testGivenOnlyBreakEnd_WhenCalculating_ThenReturnsZero() {
    let data = TestBreakData(
      breakStartTime: nil,
      breakEndTime: Date()
    )
    XCTAssertEqual(data.calculateBreakDuration(), 0)
  }
}
