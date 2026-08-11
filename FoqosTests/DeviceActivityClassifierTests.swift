import DeviceActivity
import Foundation
import XCTest

@testable import FamilyFoqos

@MainActor
final class DeviceActivityClassifierTests: XCTestCase {
  private let profileId = UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!

  func testGivenKnownPrefixedActivityNames_WhenClassifying_ThenReturnsTypeAndProfile() {
    let cases = [
      (BreakTimerActivity.id, "Break Timer"),
      (StopScheduleTimerActivity.id, "Stop Schedule Timer"),
      (ScheduleTimerActivity.id, "Schedule Timer"),
      (StrategyTimerActivity.id, "Strategy Timer"),
    ]

    for (activityId, expectedType) in cases {
      let activity = DeviceActivityName(rawValue: "\(activityId):\(profileId.uuidString)")

      let classification = DeviceActivityClassifier.classify(activity)

      XCTAssertEqual(classification.type, expectedType)
      XCTAssertEqual(classification.profileId, profileId)
      XCTAssertTrue(classification.matches(profileId: profileId))
    }
  }

  func testGivenLegacyBareUUID_WhenClassifying_ThenReturnsLegacyScheduleAndProfile() {
    let activity = DeviceActivityName(rawValue: profileId.uuidString)

    let classification = DeviceActivityClassifier.classify(activity)

    XCTAssertEqual(classification.type, "Schedule Timer (Legacy)")
    XCTAssertEqual(classification.profileId, profileId)
  }

  func testGivenUnknownName_WhenClassifying_ThenReturnsUnknownWithoutProfile() {
    let activity = DeviceActivityName(rawValue: "OtherActivity:\(profileId.uuidString)")

    let classification = DeviceActivityClassifier.classify(activity)

    XCTAssertEqual(classification.type, "Unknown")
    XCTAssertNil(classification.profileId)
    XCTAssertFalse(classification.matches(profileId: profileId))
  }

  func testGivenKnownPrefixWithInvalidUUID_WhenClassifying_ThenReturnsUnknown() {
    let activity = DeviceActivityName(rawValue: "\(BreakTimerActivity.id):not-a-uuid")

    let classification = DeviceActivityClassifier.classify(activity)

    XCTAssertEqual(classification.type, "Unknown")
    XCTAssertNil(classification.profileId)
  }

  func testGivenDifferentProfile_WhenMatching_ThenReturnsFalse() {
    let activity = DeviceActivityName(
      rawValue: "\(StrategyTimerActivity.id):\(profileId.uuidString)")
    let otherProfileId = UUID(uuidString: "8b688f50-28c9-49ae-938f-e54c43f74471")!

    let classification = DeviceActivityClassifier.classify(activity)

    XCTAssertFalse(classification.matches(profileId: otherProfileId))
  }
}
