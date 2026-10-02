import CoreLocation
import XCTest

final class ScreenshotTests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  @MainActor
  private func launch(scenario: String, largestText: Bool = false) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["--screenshot-demo", "--demo-scenario", scenario]
    if largestText {
      app.launchArguments += [
        "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
      ]
    }
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
    let toolbarBottom = app.navigationBars.firstMatch.frame.maxY
    for _ in 0..<16 {
      if startHeader.isHittable && stopHeader.isHittable
        && startHeader.frame.minY >= toolbarBottom
        && startHeader.frame.minY <= toolbarBottom + 32
        && stopHeader.frame.maxY <= app.frame.maxY
      {
        break
      }
      let distance =
        startHeader.exists
        ? min(200, max(-200, startHeader.frame.minY - (toolbarBottom + 16))) : 180
      let origin = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
      origin
        .press(
          forDuration: 0.1,
          thenDragTo: origin.withOffset(CGVector(dx: 0, dy: -distance)),
          withVelocity: .slow,
          thenHoldForDuration: 0.2)
    }
    XCTAssertTrue(startHeader.isHittable)
    XCTAssertTrue(stopHeader.isHittable)
    XCTAssertGreaterThanOrEqual(startHeader.frame.minY, app.navigationBars.firstMatch.frame.maxY)
    XCTAssertLessThanOrEqual(stopHeader.frame.maxY, app.frame.maxY)
    snapshot("02-profile-triggers")
  }

  @MainActor
  func testHomeControlsHavePurposeLabels() throws {
    let app = launch(scenario: "parent-dashboard")
    XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 15))
    app.buttons["Cancel"].tap()
    XCTAssertTrue(app.buttons["Family Controls"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["Support"].exists)
    XCTAssertTrue(app.buttons["Settings"].exists)
  }

  @MainActor
  func testHoldControlsHaveButtonSemantics() throws {
    let app = launch(scenario: "profile-editor")
    XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 15))
    app.buttons["Cancel"].tap()
    XCTAssertTrue(app.buttons["Hold to Start"].waitForExistence(timeout: 5))
    app.terminate()

    let activeApp = launch(scenario: "home-active")
    XCTAssertTrue(activeApp.buttons["Stop"].waitForExistence(timeout: 15))
    XCTAssertTrue(activeApp.buttons["Hold to Start Break"].exists)
  }

  @MainActor
  func testHomeLargestTextDoesNotOverlapControls() throws {
    continueAfterFailure = true
    let app = launch(scenario: "home-active", largestText: true)
    let title = app.staticTexts["Family Foqos"]
    XCTAssertTrue(title.waitForExistence(timeout: 15))
    let support = app.buttons["Support"]
    XCTAssertTrue(support.exists)
    XCTAssertLessThanOrEqual(title.frame.maxY, support.frame.minY)
    XCTAssertLessThanOrEqual(title.frame.maxX, app.frame.maxX)

    let activity = app.staticTexts["4 Week Activity"]
    let hide = app.buttons["Hide"]
    XCTAssertTrue(activity.exists)
    XCTAssertTrue(hide.exists)
    XCTAssertLessThanOrEqual(activity.frame.maxY, hide.frame.minY)
    let visibleBounds = app.scrollViews.firstMatch.frame.intersection(app.frame)
    XCTAssertGreaterThanOrEqual(hide.frame.minX, visibleBounds.minX)
    XCTAssertLessThanOrEqual(hide.frame.maxX, visibleBounds.maxX)

    let labels = ["<1h", "1-3h", "3-5h", ">5h"].map { app.staticTexts[$0] }
    for label in labels {
      XCTAssertTrue(label.exists)
      XCTAssertGreaterThanOrEqual(label.frame.minX, visibleBounds.minX)
      XCTAssertLessThanOrEqual(label.frame.maxX, visibleBounds.maxX)
    }
    for (previous, next) in zip(labels, labels.dropFirst()) {
      XCTAssertLessThanOrEqual(previous.frame.maxY, next.frame.minY)
    }
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

  @MainActor
  func testLocationRestrictionsScreenshot() throws {
    let app = launch(scenario: "location-restrictions")
    let previousLocation = XCUIDevice.shared.location
    defer { XCUIDevice.shared.location = previousLocation }
    let work = CLLocation(latitude: 51.5054, longitude: -0.0235)
    XCUIDevice.shared.location = XCUILocation(location: work)
    XCTAssertTrue(app.staticTexts["Restriction Type"].waitForExistence(timeout: 15))
    XCTAssertTrue(app.staticTexts["Preview"].waitForExistence(timeout: 15))
    sleep(3)
    let coordinate = try XCTUnwrap(XCUIDevice.shared.location).location.coordinate
    XCTAssertEqual(coordinate.latitude, 51.5054, accuracy: 0.000001)
    XCTAssertEqual(coordinate.longitude, -0.0235, accuracy: 0.000001)
    XCTAssertFalse(app.alerts.firstMatch.exists)
    snapshot("05-location-restrictions")
  }
}
