import XCTest

@testable import FamilyFoqos

final class ScreenshotDemoModeTests: XCTestCase {
  override func tearDown() {
    ScreenshotDemoMode.overrideForTesting = nil
    super.tearDown()
  }

  // Tripwire (spec containment guarantee): demo mode must be OFF in a normal test run.
  // If this ever fails, the activation path has widened — that is a release blocker.
  func testGivenNormalTestRun_WhenCheckingDemoMode_ThenInactive() {
    XCTAssertFalse(ScreenshotDemoMode.isActive)
    XCTAssertNil(ScreenshotDemoMode.scenario)
  }

  func testGivenOverrideActive_WhenCheckingIsActive_ThenActive() {
    ScreenshotDemoMode.overrideForTesting = true
    XCTAssertTrue(ScreenshotDemoMode.isActive)
  }

  func testGivenScenarioRawValues_WhenParsing_ThenAllThreeResolve() {
    XCTAssertEqual(ScreenshotDemoScenario(rawValue: "home-active"), .homeActive)
    XCTAssertEqual(ScreenshotDemoScenario(rawValue: "profile-editor"), .profileEditor)
    XCTAssertEqual(ScreenshotDemoScenario(rawValue: "parent-dashboard"), .parentDashboard)
  }
}
