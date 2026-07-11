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

  func testGivenHomeCardWarningVisible_WhenReconcileRefreshSeesActivityPresent_ThenCardWarningClears() {
    let profile = BlockedProfiles(name: "Scheduled")
    var state = ScheduleOutOfSyncCardState(visibilityByProfileId: [profile.id: true])

    state.refreshAfterScheduleReconcile(profiles: [profile], isOutOfSync: { _ in false })
    let data = profile.cardData(scheduleIsOutOfSync: state.isOutOfSync(for: profile))

    XCTAssertFalse(data.scheduleIsOutOfSync)
  }
}
