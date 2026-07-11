import XCTest

@testable import FamilyFoqos

@MainActor
final class ScheduleOutOfSyncBannerStateTests: XCTestCase {
  func testGivenWarningVisible_WhenReconcileNotificationRefreshSeesActivityPresent_ThenWarningClears() {
    let profile = BlockedProfiles(name: "Scheduled")
    var state = ScheduleOutOfSyncBannerState(isVisible: true)

    state.refreshAfterScheduleReconcile(profile: profile, isOutOfSync: { _ in false })

    XCTAssertFalse(state.isVisible)
  }
}
