import DeviceActivity
import Foundation
import XCTest

@testable import FamilyFoqos

@MainActor
final class DeviceActivityClassifierTests: XCTestCase {
  private let profileId = UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!

  func testGivenEveryRuntimeActivityKind_WhenClassifying_ThenReturnsTypeAndProfile() {
    // Keep this table aligned with TimerActivityUtil's exhaustive runtime dispatch switch.
    let cases = [
      (
        BreakDeadlineBackstopActivity.id,
        DeviceActivityName(
          rawValue: "\(BreakDeadlineBackstopActivity.id):\(profileId.uuidString)"),
        "Break Deadline Backstop"
      ),
      (
        BreakTimerActivity.id,
        DeviceActivityName(rawValue: "\(BreakTimerActivity.id):\(profileId.uuidString)"),
        "Break Timer"
      ),
      (
        OneMoreMinuteDeadlineBackstopActivity.id,
        DeviceActivityName(
          rawValue: "\(OneMoreMinuteDeadlineBackstopActivity.id):\(profileId.uuidString)"),
        "One More Minute Deadline Backstop"
      ),
      (
        OneMoreMinuteTimerActivity.id,
        DeviceActivityName(
          rawValue: "\(OneMoreMinuteTimerActivity.id):\(profileId.uuidString)"),
        "One More Minute Timer"
      ),
      (
        ScheduleTimerActivity.id,
        DeviceActivityName(rawValue: profileId.uuidString),
        "Schedule Timer"
      ),
      (
        StopScheduleTimerActivity.id,
        DeviceActivityName(
          rawValue: "\(StopScheduleTimerActivity.id):\(profileId.uuidString)"),
        "Stop Schedule Timer"
      ),
      (
        StrategyTimerActivity.id,
        DeviceActivityName(rawValue: "\(StrategyTimerActivity.id):\(profileId.uuidString)"),
        "Strategy Timer"
      ),
    ]

    XCTAssertEqual(Set(cases.map(\.0)).count, 7)
    for (_, activity, expectedType) in cases {
      let classification = DeviceActivityClassifier.classify(activity)

      XCTAssertNotEqual(classification.type, "Unknown")
      XCTAssertEqual(classification.type, expectedType)
      XCTAssertEqual(classification.profileId, profileId)
      XCTAssertTrue(classification.matches(profileId: profileId))
    }
  }

  func testGivenUnknownName_WhenClassifying_ThenReturnsUnknownWithoutProfile() {
    let activity = DeviceActivityName(rawValue: "OtherActivity:\(profileId.uuidString)")

    let classification = DeviceActivityClassifier.classify(activity)

    XCTAssertEqual(classification.type, "Unknown")
    XCTAssertNil(classification.profileId)
    XCTAssertFalse(classification.matches(profileId: profileId))
  }

  func testGivenKnownPrefixWithInvalidUUID_WhenClassifying_ThenKeepsTypeWithoutProfile() {
    let activity = DeviceActivityName(rawValue: "\(BreakTimerActivity.id):not-a-uuid")

    let classification = DeviceActivityClassifier.classify(activity)

    XCTAssertEqual(classification.type, "Break Timer")
    XCTAssertNil(classification.profileId)
    XCTAssertFalse(classification.matches(profileId: profileId))
  }

  func testGivenDifferentProfile_WhenMatching_ThenReturnsFalse() {
    let activity = DeviceActivityName(
      rawValue: "\(StrategyTimerActivity.id):\(profileId.uuidString)")
    let otherProfileId = UUID(uuidString: "8b688f50-28c9-49ae-938f-e54c43f74471")!

    let classification = DeviceActivityClassifier.classify(activity)

    XCTAssertFalse(classification.matches(profileId: otherProfileId))
  }
}
