import XCTest

@testable import FamilyFoqos

@MainActor
final class ScreenshotDemoScheduleTests: XCTestCase {
  override func setUp() {
    ScreenshotDemoMode.overrideForTesting = nil
    ScreenshotDemoMode.scenarioOverrideForTesting = nil
    super.setUp()
  }

  override func tearDown() {
    ScreenshotDemoMode.overrideForTesting = nil
    ScreenshotDemoMode.scenarioOverrideForTesting = nil
    super.tearDown()
  }

  func testGivenDemoMode_WhenScheduledActivityIsMissing_ThenOutOfSyncIsSuppressed() {
    let profile = scheduledProfile()
    ScreenshotDemoMode.overrideForTesting = true

    XCTAssertFalse(profile.scheduleIsOutOfSync)
  }

  func testGivenNormalMode_WhenScheduledActivityIsMissing_ThenOutOfSyncRemainsVisible() {
    let profile = scheduledProfile()

    XCTAssertTrue(profile.scheduleIsOutOfSync)
  }

  private func scheduledProfile() -> BlockedProfiles {
    let profile = BlockedProfiles(name: "Scheduled")
    profile.startTriggers = ProfileStartTriggers(schedule: true)
    profile.startSchedule = ProfileScheduleTime(
      days: [.monday], hour: 9, minute: 0, updatedAt: Date(timeIntervalSince1970: 0))
    return profile
  }
}
