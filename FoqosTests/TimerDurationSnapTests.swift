import XCTest

@testable import FamilyFoqos

@MainActor
final class TimerDurationSnapTests: XCTestCase {

  // Mirrors the production snapPoints after the 1440 entry is removed.
  private let snapPoints: [Double] = [15, 30, 45, 60, 90, 120, 180, 240, 360, 480, 720]
  private let maxMinutes: Double = 1439
  private let threshold: Double = 10

  func testGivenValueNearSnapPoint_WhenSnapping_ThenSnapsToIt() {
    let result = TimerDurationView.snappedDuration(
      for: 62, snapPoints: snapPoints, threshold: threshold, maxMinutes: maxMinutes)
    XCTAssertEqual(result, 60)
  }

  func testGivenValueFarFromAnySnapPoint_WhenSnapping_ThenReturnsValue() {
    let result = TimerDurationView.snappedDuration(
      for: 1000, snapPoints: snapPoints, threshold: threshold, maxMinutes: maxMinutes)
    XCTAssertEqual(result, 1000)
  }

  func testGivenValueAtMax_WhenSnapping_ThenNeverExceedsMax() {
    let result = TimerDurationView.snappedDuration(
      for: 1439, snapPoints: snapPoints, threshold: threshold, maxMinutes: maxMinutes)
    XCTAssertEqual(result, 1439)
  }

  func testGivenStraySnapPointAboveMax_WhenSnapping_ThenClampedToMax() {
    // Defense in depth: even with a bad snap point present, the result is capped.
    let result = TimerDurationView.snappedDuration(
      for: 1435, snapPoints: [720, 1440], threshold: threshold, maxMinutes: maxMinutes)
    XCTAssertEqual(result, 1439)
  }
}
