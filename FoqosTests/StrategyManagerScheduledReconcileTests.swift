import XCTest

@testable import FamilyFoqos

final class StrategyManagerScheduledReconcileTests: XCTestCase {
  func testGivenActiveSessionForDifferentProfile_WhenScheduledCASResolves_ThenDoesNotReconcile() {
    let now = Date()
    let profileA = UUID()
    let profileB = UUID()
    let result = StrategyManager.shouldReconcileScheduledStartTime(
      activeProfileId: profileB,
      scheduledProfileId: profileA,
      localStartTime: now,
      remoteStartTime: now.addingTimeInterval(-3600))

    XCTAssertFalse(result, "A late CAS result for A must not overwrite B's startTime")
  }

  func testGivenActiveSessionForSameProfileWithDrift_WhenScheduledCASResolves_ThenReconciles() {
    let now = Date()
    let profileA = UUID()
    let result = StrategyManager.shouldReconcileScheduledStartTime(
      activeProfileId: profileA,
      scheduledProfileId: profileA,
      localStartTime: now,
      remoteStartTime: now.addingTimeInterval(-60))

    XCTAssertTrue(result, "Same-profile startTime drift must still reconcile")
  }

  func testGivenMatchingStartTimes_WhenScheduledCASResolves_ThenNoReconcile() {
    let now = Date()
    let profileA = UUID()

    XCTAssertFalse(
      StrategyManager.shouldReconcileScheduledStartTime(
        activeProfileId: profileA,
        scheduledProfileId: profileA,
        localStartTime: now,
        remoteStartTime: now))
  }
}
