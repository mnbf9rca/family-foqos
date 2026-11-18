import XCTest

final class ProtectedStoreLaunchUITests: XCTestCase {
  @MainActor
  func testWaitsForUnlockThenShowsTheExistingProfile() {
    let fixture = UUID()
    let app = launch(fixture, mode: "seed")
    assertExistingProfile(in: app)
    app.terminate()

    launch(fixture, mode: "locked", in: app)
    XCTAssertTrue(app.staticTexts["Unlock Your Device"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.buttons["Settings"].exists)
    XCTAssertFalse(app.staticTexts["Stored before reboot"].exists)

    keepScreenshot("Waiting for unlock", in: app)
    app.buttons["Simulate Unlock"].tap()
    assertExistingProfile(in: app)
    XCTAssertFalse(app.staticTexts["Unlock Your Device"].exists)
    keepScreenshot("Existing profile after unlock", in: app)

    XCUIDevice.shared.press(.home)
    app.activate()
    assertExistingProfile(in: app)
  }

  @MainActor
  func testAvailableStoreErrorCanBeRetried() {
    let fixture = UUID()
    let app = launch(fixture, mode: "seed")
    assertExistingProfile(in: app)
    app.terminate()

    launch(fixture, mode: "fail", in: app)
    XCTAssertTrue(app.staticTexts["Couldn't Open Family Foqos"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.buttons["Settings"].exists)

    keepScreenshot("Recoverable store error", in: app)
    app.buttons["Try Again"].tap()
    assertExistingProfile(in: app)
    XCTAssertFalse(app.staticTexts["Couldn't Open Family Foqos"].exists)
  }

  @MainActor
  @discardableResult
  private func launch(
    _ fixture: UUID, mode: String, in app: XCUIApplication = XCUIApplication()
  ) -> XCUIApplication {
    app.launchArguments = [
      "--screenshot-demo",
      "-family_foqos_show_intro_screen", "NO",
      "-family_foqos_has_completed_onboarding", "YES",
    ]
    app.launchEnvironment = [
      "FOQOS_PROTECTED_LAUNCH_TEST_STORE": fixture.uuidString,
      "FOQOS_PROTECTED_LAUNCH_TEST_MODE": mode,
    ]
    app.launch()
    return app
  }

  @MainActor
  private func assertExistingProfile(in app: XCUIApplication) {
    let profile = app.staticTexts.matching(identifier: "Stored before reboot")
    XCTAssertTrue(profile.firstMatch.waitForExistence(timeout: 15))
    XCTAssertEqual(profile.count, 1)
    XCTAssertTrue(app.buttons["Settings"].exists)
  }

  @MainActor
  private func keepScreenshot(_ name: String, in app: XCUIApplication) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

}
