import FamilyControls
import XCTest

@testable import FamilyFoqos

final class FamilyActivityUtilDemoTests: XCTestCase {
  override func setUp() {
    ScreenshotDemoMode.overrideForTesting = nil
    ScreenshotDemoMode.scenarioOverrideForTesting = nil
    super.setUp()
  }

  override func tearDown() {
    ScreenshotDemoMode.overrideForTesting = nil
    super.tearDown()
  }

  func testGivenDemoMode_WhenCountingEmptySelection_ThenFakeCountReturned() {
    ScreenshotDemoMode.overrideForTesting = true
    let count = FamilyActivityUtil.countSelectedActivities(FamilyActivitySelection())
    XCTAssertEqual(count, 6)
    XCTAssertEqual(
      FamilyActivityUtil.getCountDisplayText(FamilyActivitySelection()), "6 items")
  }

  func testGivenNormalMode_WhenCountingEmptySelection_ThenZero() {
    XCTAssertEqual(
      FamilyActivityUtil.countSelectedActivities(FamilyActivitySelection()), 0)
  }
}
