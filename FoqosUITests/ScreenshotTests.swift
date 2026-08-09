import XCTest

final class ScreenshotTests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  @MainActor
  private func launch(scenario: String) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["--screenshot-demo", "--demo-scenario", scenario]
    setupSnapshot(app)
    app.launch()
    return app
  }

  @MainActor
  func testHomeActiveScreenshot() throws {
    let app = launch(scenario: "home-active")
    XCTAssertTrue(app.staticTexts["Homework"].waitForExistence(timeout: 15))
    sleep(3)
    snapshot("01-home-active")
  }

  @MainActor
  func testProfileEditorScreenshot() throws {
    let app = launch(scenario: "profile-editor")
    XCTAssertTrue(app.buttons["Select Apps to Restrict"].waitForExistence(timeout: 15))
    sleep(1)
    snapshot("02-profile-editor")
  }

  @MainActor
  func testParentDashboardScreenshot() throws {
    let app = launch(scenario: "parent-dashboard")
    XCTAssertTrue(app.staticTexts["Lock Code Set"].waitForExistence(timeout: 15))
    sleep(1)
    snapshot("03-parent-dashboard")
  }
}
