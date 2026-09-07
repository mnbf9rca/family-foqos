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
    XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 15))
    sleep(3)
    snapshot("01-home-active")
  }

  @MainActor
  func testProfileTriggersScreenshot() throws {
    let app = launch(scenario: "profile-editor")
    XCTAssertTrue(app.buttons["Select Apps to Restrict"].waitForExistence(timeout: 15))
    let startHeader = app.staticTexts["Start by..."]
    let stopHeader = app.staticTexts["Continue until..."]
    for _ in 0..<8 {
      if startHeader.isHittable && startHeader.frame.minY < 230 { break }
      app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        .press(
          forDuration: 0.1,
          thenDragTo:
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)))
    }
    XCTAssertTrue(startHeader.isHittable)
    XCTAssertTrue(stopHeader.isHittable)
    snapshot("02-profile-triggers")
  }

  @MainActor
  func testChildLockedScreenshot() throws {
    let app = launch(scenario: "child-locked")
    XCTAssertTrue(app.staticTexts["Locked Profiles"].waitForExistence(timeout: 15))
    XCTAssertTrue(app.staticTexts["Lock code active"].exists)
    XCTAssertFalse(app.alerts.firstMatch.exists)
    snapshot("03-child-locked")
  }

  @MainActor
  func testParentDashboardScreenshot() throws {
    let app = launch(scenario: "parent-dashboard")
    XCTAssertTrue(app.staticTexts["Lock Code Set"].waitForExistence(timeout: 15))
    sleep(1)
    snapshot("04-parent-dashboard")
  }
}
