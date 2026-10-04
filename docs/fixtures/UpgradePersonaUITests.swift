import XCTest

// External runner only: never import the application or call its APIs.
@MainActor
final class UpgradePersonaUITests: XCTestCase {
  private let app = XCUIApplication(bundleIdentifier: "com.cynexia.family-foqos")
  private var libraryIndex = 1
  private var reportPhase = ""
  private var persona: String { ProcessInfo.processInfo.environment["UPGRADE_PERSONA"]! }

  override func setUpWithError() throws {
    continueAfterFailure = false
    guard let value = ProcessInfo.processInfo.environment["UPGRADE_PERSONA"], !value.isEmpty else {
      throw NSError(domain: "UpgradeRunner", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing persona"])
    }
  }

  @MainActor
  private func launch(_ phase: String, seed: Bool = false, diagnostics: Bool = true) {
    reportPhase = phase
    app.launchArguments = ["--upgrade-ui-check"]
    app.launchArguments += ["--upgrade-report-phase", phase, "--upgrade-report-generation", ProcessInfo.processInfo.environment["UPGRADE_GENERATION"]!]
    if seed {
      app.launchArguments += ["--upgrade-seed", persona, "--upgrade-store-token", ProcessInfo.processInfo.environment["UPGRADE_STORE_TOKEN"]!]
    } else if diagnostics {
      app.launchArguments += [
        "--upgrade-diagnostics", "--upgrade-report-phase", phase,
        "--upgrade-report-generation", ProcessInfo.processInfo.environment["UPGRADE_GENERATION"]!,
        "--upgrade-source-revision", ProcessInfo.processInfo.environment["UPGRADE_SOURCE_REVISION"]!,
      ]
    }
    app.launchArguments += ["--upgrade-scan-script", ProcessInfo.processInfo.environment["UPGRADE_SCANS"] ?? "wrong,correct,correct,correct"]
    app.launch()
    XCTAssertTrue(app.staticTexts[persona == "library" ? (phase == "relaunch" ? "RC Library 06" : "RC Library 01") : "RC \(persona)"].waitForExistence(timeout: 20))
    if !seed { waitForReport(after: 0) }
  }

  @MainActor
  private func screenshot(_ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = "\(persona).\(name)"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  @MainActor
  private func press(_ title: String) {
    let symbols = ["ellipsis", "plus", "plus.circle.fill", "xmark", "gearshape.fill"]
    let direct = app.buttons.matching(identifier: title)
    let matches =
      title.contains("Hold")
      ? app.staticTexts.matching(identifier: title)
      : symbols.contains(title) && !direct.firstMatch.exists
        ? app.buttons.containing(.image, identifier: title)
        : direct
    let button = matches.allElementsBoundByIndex.first { self.app.frame.contains($0.frame) && $0.isHittable } ?? matches.firstMatch
    XCTAssertTrue(button.waitForExistence(timeout: 10), "Missing button: \(title)\n\(app.debugDescription)")
    if title.contains("Hold") { button.press(forDuration: 1.5) } else { button.tap() }
  }

  @MainActor
  func testV1Setup() throws {
    launch("v1", seed: true)
    if persona == "library" { XCTAssertFalse(app.buttons["Stop"].exists) } else { XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 10)) }
    screenshot("v1-before-update")
    app.terminate()
  }

  @MainActor
  func testV2FirstLaunch() throws {
    launch("first-launch")
    if persona == "library" { XCTAssertFalse(app.buttons["Stop"].exists) } else { XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 10)) }
    screenshot("first-launch")
    if persona == "library" { selectLibraryProfile(24) }
    press("ellipsis")
    press("Stats for Nerds")
    XCTAssertTrue(app.staticTexts["Total Sessions"].waitForExistence(timeout: 10))
    assertAdjacentValue("Total Sessions", expected: "1")  // Stats counts completed sessions; the active V1 session remains open.
    screenshot("retained-history")
    press("Close")
    if persona == "library" { selectLibraryProfile(1) }
    foreground()
    XCTAssertTrue(app.staticTexts[persona == "library" ? "RC Library 01" : "RC \(persona)"].waitForExistence(timeout: 10))
    screenshot("foreground")
    if persona == "emergency" {
      press("Emergency")
      XCTAssertTrue(app.staticTexts["Unblocks remaining"].waitForExistence(timeout: 10))
      assertAdjacentValue("Unblocks remaining", expected: "1")
      press("gearshape.fill")
      let period = app.buttons["2 weeks"]
      XCTAssertTrue(period.waitForExistence(timeout: 10))
      XCTAssertTrue(period.images["checkmark"].exists, "Two weeks must remain the selected period")
      screenshot("retained-emergency-period")
    }
    attachReportCount()
    app.terminate()
  }

  @MainActor
  func testV2Journey() throws {
    launch("journey")
    if persona == "library" {
      try libraryJourney()
    } else {
      if persona == "break" {
        XCTAssertTrue(app.staticTexts["Hold to Stop Break"].waitForExistence(timeout: 10))
        screenshot("retained-break")
        foreground()
        XCTAssertTrue(app.staticTexts["Hold to Stop Break"].exists)
        press("Hold to Stop Break")
        XCTAssertFalse(app.staticTexts["Hold to Stop Break"].exists)
        XCTAssertFalse(app.staticTexts["Hold to Start Break"].exists, "A used break must not offer a fresh allowance")
      }
      if ["nfc", "qr", "manual-nfc", "manual-qr"].contains(persona) {
        stopWithScan(wrong: true)
      } else if ["nfc-timer", "qr-timer"].contains(persona) {
        stopWithScan(wrong: false)
      } else if persona == "emergency" {
        emergencyUnblock(expectedRemaining: 1)
      } else {
        press("Stop")
      }
      assertIdle()
      if persona == "schedule" {
        foreground()
        assertIdle()  // Explicit stop suppresses this occurrence; no background restart.
      }
      inspectSettings(save: persona == "parent", unlock: false)
      startFocus()
      XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 10))
      XCTAssertFalse(app.staticTexts["Enter Lock Code"].exists)
      if ["nfc-timer", "qr-timer", "shortcut-timer"].contains(persona) {
        assertCountdown(minutes: 37)
      }
      screenshot("restarted")
      foreground()  // Capture the accepted origin before normal Stop clears it.
      if ["nfc", "qr", "manual-nfc", "manual-qr", "nfc-timer", "qr-timer"].contains(persona) {
        stopWithScan(wrong: ["manual-nfc", "manual-qr"].contains(persona))
      } else if persona == "shortcut-timer" {
        emergencyUnblock(expectedRemaining: 3)
      } else {
        press("Stop")
      }
      assertIdle()
      if persona == "child" { try childEditingJourney() }
    }
    dismissRatingPrompt()
    screenshot("journey")
    foreground()
    attachReportCount()
    app.terminate()
  }

  private func foreground() {
    let previous = reportCount()
    XCUIDevice.shared.press(.home)
    let background = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        self.app.state == .runningBackground || self.app.state == .runningBackgroundSuspended
      }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [background], timeout: 10), .completed)
    app.activate()
    waitForReport(after: previous)
  }

  private func reportCount() -> Int {
    let marker = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "upgrade-report-\(reportPhase)-")).firstMatch
    XCTAssertTrue(marker.waitForExistence(timeout: 10), "Report completion marker is absent")
    return Int(marker.identifier.split(separator: "-").last!)!
  }

  private func waitForReport(after count: Int) {
    let completed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.reportCount() > count }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: 10), .completed, "Fresh diagnostic write did not complete")
    let identifier = "upgrade-report-\(reportPhase)-\(reportCount())"
    XCTAssertTrue(app.descendants(matching: .any)[identifier].waitForExistence(timeout: 10))
  }

  private func attachReportCount() {
    let attachment = XCTAttachment(string: String(reportCount()))
    attachment.name = "upgrade-report-count-\(reportPhase)-\(reportCount())"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private func assertIdle() {
    XCTAssertFalse(app.buttons["Stop"].exists, "A focus session unexpectedly remains active")
    XCTAssertTrue(app.staticTexts["Hold to Start"].waitForExistence(timeout: 10))
  }

  private func dismissRatingPrompt() {
    let later = app.buttons["Not Now"]
    if later.waitForExistence(timeout: 2) {
      screenshot("rating-prompt")
      later.tap()  // A normal StoreKit request, never an error or action refusal.
    }
    XCTAssertTrue(app.staticTexts["Hold to Start"].isHittable)
  }

  private func completeQRScan() {
    if persona.contains("qr") {
      let text = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "You're running in the simulator")).firstMatch
      XCTAssertTrue(text.waitForExistence(timeout: 10))
      text.tap()  // CodeScanner's own simulator callback, through the real presented scanner.
    }
  }

  private func stopWithScan(wrong: Bool) {
    press("Stop")
    if app.buttons["Scan NFC Tag"].exists { press("Scan NFC Tag") }
    if app.buttons["Scan QR Code"].exists { press("Scan QR Code") }
    completeQRScan()
    if wrong {
      XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 10), "Wrong scan must be refused")
      screenshot("wrong-scan-refused")
      XCTAssertTrue(app.buttons["Stop"].exists)
      press("OK")  // Dismiss the verified, expected refusal through its actual UI.
      press("Stop")
      if app.buttons["Scan NFC Tag"].exists { press("Scan NFC Tag") }
      if app.buttons["Scan QR Code"].exists { press("Scan QR Code") }
      completeQRScan()
    }
    assertIdle()
  }

  private func startFocus() {
    press("Hold to Start")
    if app.buttons["Start Now"].exists { press("Start Now") }
    if app.buttons["Scan NFC Tag"].exists { press("Scan NFC Tag") }
    if app.buttons["Scan QR Code"].exists { press("Scan QR Code") }
    completeQRScan()
    if app.staticTexts["Timer Settings"].exists {
      XCTAssertTrue(app.staticTexts["37m"].exists, "Interactive timer must retain its saved duration")
      screenshot("saved-timer-duration")
      press("Set Duration")
    }
  }

  private func assertCountdown(minutes: Int) {
    let timer = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9]{2}:[0-9]{2}:[0-9]{2}")).firstMatch
    XCTAssertTrue(timer.waitForExistence(timeout: 10))
    let before = timer.label
    let values = before.split(separator: ":").compactMap { Int($0) }
    XCTAssertEqual(values.count, 3)
    let seconds = values[0] * 3600 + values[1] * 60 + values[2]
    XCTAssertGreaterThan(seconds, (minutes - 2) * 60)
    XCTAssertLessThanOrEqual(seconds, minutes * 60)
    let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in timer.label != before }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 8), .completed, "Countdown did not decrease")
    let after = timer.label.split(separator: ":").compactMap { Int($0) }
    XCTAssertEqual(after.count, 3)
    XCTAssertLessThan(after[0] * 3600 + after[1] * 60 + after[2], seconds)
    screenshot("countdown-decreased")
    foreground()
    XCTAssertTrue(timer.waitForExistence(timeout: 10))
  }

  private func emergencyUnblock(expectedRemaining: Int) {
    press("Emergency")
    XCTAssertTrue(app.staticTexts["Unblocks remaining"].waitForExistence(timeout: 10))
    assertAdjacentValue("Unblocks remaining", expected: String(expectedRemaining))
    screenshot("emergency-allowance")
    let unblock = app.buttons["Emergency Unblock"]
    XCTAssertTrue(unblock.exists)
    for _ in 0..<3 { unblock.tap() }
    press("Emergency Unblock")
    XCTAssertFalse(app.alerts.firstMatch.exists, "Emergency unblock must succeed without a hidden failure")
    // The production action dismisses the sheet on successful completion.
    XCTAssertTrue(app.staticTexts["Hold to Start"].waitForExistence(timeout: 10))
    assertIdle()
  }

  private func scrollTo(_ element: XCUIElement, up: Bool = true) {
    for _ in 0..<16 {
      if element.exists && element.isHittable { return }
      if up { app.swipeUp() } else { app.swipeDown() }
    }
    XCTAssertTrue(element.exists && element.isHittable, "Element not reachable: \(element)\n\(app.debugDescription)")
  }

  private func openEditor(_ name: String? = nil) {
    press("Manage")
    selectProfileRow(name ?? "RC \(persona)")
    XCTAssertTrue(app.textFields["Profile Name"].waitForExistence(timeout: 10))
  }

  private func selectProfileRow(_ label: String) {
    XCTAssertTrue(app.navigationBars["Profiles"].waitForExistence(timeout: 10))
    let list = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.tables.firstMatch
    let profile = list.descendants(matching: .any).matching(
      NSPredicate(format: "label == %@ OR label BEGINSWITH %@", label, label + ", ")
    ).firstMatch
    scrollTo(profile)
    profile.tap()
  }

  private func inspectSettings(save: Bool, unlock: Bool, name: String? = nil) {
    openEditor(name)
    if unlock {
      press("Unlock")
      enterCode("2468")
    }
    XCTAssertEqual(app.textFields["Profile Name"].value as? String, name ?? "RC \(persona)")
    if persona == "parent" { XCTAssertFalse(app.buttons["Unlock"].exists) }
    scrollTo(app.staticTexts["Start by..."])
    scrollTo(app.staticTexts["Continue until..."])
    XCTAssertTrue(app.staticTexts["Continue until..."].exists)
    screenshot("converted-settings")
    if ["manual-nfc", "manual-qr"].contains(persona) {
      XCTAssertTrue(app.staticTexts["Specific"].exists)
    }
    if persona == "schedule" {
      let schedules = app.switches.matching(identifier: "Schedule")
      XCTAssertEqual(schedules.count, 2)
      XCTAssertEqual(schedules.element(boundBy: 0).value as? String, "1")
      XCTAssertEqual(schedules.element(boundBy: 1).value as? String, "1")
      let configure = app.buttons["Configure"].firstMatch
      scrollTo(configure)
      configure.tap()
      let expected = (0..<7).map { DateFormatter().weekdaySymbols[(Calendar.current.firstWeekday - 1 + $0) % 7] }
      let frames = expected.map { day -> CGFloat in
        let row = app.buttons[day]
        XCTAssertTrue(row.exists)
        return row.frame.minY
      }
      XCTAssertEqual(frames, frames.sorted(), "Weekdays must follow this simulator's locale")
      screenshot("schedule-locale-order")
      press("Cancel")
    }
    let domains = app.staticTexts["1 domain selected"]
    scrollTo(domains, up: false)
    XCTAssertTrue(domains.exists)
    let breakDuration = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Break Duration")).firstMatch
    scrollTo(breakDuration)
    XCTAssertTrue(breakDuration.label.contains("30 minutes") || (breakDuration.value as? String) == "30 minutes")
    let reminder = app.cells.containing(.staticText, identifier: "Reminder message").textFields.firstMatch
    scrollTo(reminder)
    XCTAssertEqual(reminder.value as? String, "RC retained reminder")
    screenshot("retained-reminder-break-settings")
    if save { press("Update") } else { press("Cancel") }
    closeProfiles()
  }

  private func closeProfiles() {
    press("xmark")
    XCTAssertTrue(app.buttons["Manage"].waitForExistence(timeout: 10))
  }

  private func selectLibraryProfile(_ index: Int) {
    let title = app.staticTexts[String(format: "RC Library %02d", index)]
    scrollTo(app.buttons["Manage"])
    let carousel = app.scrollViews.element(boundBy: 1)
    for _ in 0..<24 {
      if title.exists && title.frame.minX >= 0 && title.frame.maxX <= app.frame.maxX && title.isHittable {
        libraryIndex = index
        return
      }
      if index < libraryIndex { carousel.swipeRight() } else { carousel.swipeLeft() }
    }
    XCTFail("Library profile could not be selected: \(index)")
  }

  private func enterCode(_ value: String) {
    XCTAssertTrue(app.staticTexts["Enter Lock Code"].waitForExistence(timeout: 10))
    for digit in value { press(String(digit)) }
  }

  private func assertAdjacentValue(_ label: String, expected: String) {
    let matches = app.staticTexts.matching(identifier: label)
    XCTAssertTrue(matches.firstMatch.waitForExistence(timeout: 10))
    guard let title = matches.allElementsBoundByIndex.first(where: { self.app.frame.contains($0.frame) && $0.isHittable }) else {
      XCTFail("No visible count label: \(label)")
      return
    }
    let frame = title.frame
    let adjacent = app.staticTexts.matching(identifier: expected).allElementsBoundByIndex.filter {
      abs($0.frame.minX - frame.minX) < 2 && $0.frame.minY >= frame.maxY && $0.frame.minY - frame.maxY < 25
    }
    XCTAssertFalse(adjacent.isEmpty, "Wrong adjacent value for \(label): expected \(expected)\n\(app.debugDescription)")
  }

  private func childEditingJourney() throws {
    // Normal Stop/start/Stop has already completed before entering any edit code.
    openEditor()
    XCTAssertFalse(app.textFields["Profile Name"].isEnabled)
    press("Unlock")
    XCTAssertTrue(app.staticTexts["Enter Lock Code"].waitForExistence(timeout: 10))
    screenshot("child-edit-verification")
    press("Cancel")
    XCTAssertFalse(app.textFields["Profile Name"].isEnabled)
    press("Profile Actions")
    press("Delete Profile")
    XCTAssertTrue(app.staticTexts["Enter Lock Code"].waitForExistence(timeout: 10))
    screenshot("child-delete-verification")
    press("Cancel")
    XCTAssertTrue(app.textFields["Profile Name"].exists)
    press("Unlock")
    enterCode("0000")
    XCTAssertTrue(app.staticTexts["Incorrect code. Please try again."].waitForExistence(timeout: 10))
    screenshot("child-wrong-code")
    press("Cancel")
    XCTAssertFalse(app.textFields["Profile Name"].isEnabled)
    press("Unlock")
    enterCode("2468")
    XCTAssertTrue(app.textFields["Profile Name"].isEnabled)
    press("Update")
    closeProfiles()
    inspectSettings(save: false, unlock: false)  // The original locked flag stays persisted; edit lease may remain this launch.
    press("Manage")
    // The existing list's plus button opens the production creation form.
    press("plus")
    XCTAssertTrue(app.textFields["Profile Name"].waitForExistence(timeout: 10))
    app.textFields["Profile Name"].tap()
    app.textFields["Profile Name"].typeText("RC Child Created")
    scrollTo(app.buttons["Select Domains to Restrict"])
    press("Select Domains to Restrict")
    let domain = app.textFields.firstMatch
    XCTAssertTrue(domain.waitForExistence(timeout: 10))
    domain.tap()
    domain.typeText("example.org")
    press("plus.circle.fill")
    XCTAssertTrue(app.staticTexts["example.org"].waitForExistence(timeout: 10))
    press("Done")
    press("Create")
    selectProfileRow("RC Child Created")
    XCTAssertFalse(app.buttons["Unlock"].exists)
    press("Cancel")
    selectProfileRow("RC child")
    press("Profile Actions")
    press("Duplicate Profile")
    XCTAssertTrue(app.alerts["Duplicate Profile"].waitForExistence(timeout: 10))
    app.alerts["Duplicate Profile"].buttons["Create"].tap()
    press("Cancel")
    selectProfileRow("RC child Copy")
    XCTAssertFalse(app.buttons["Unlock"].exists)
    screenshot("child-created-duplicated-unlocked")
    press("Cancel")
    closeProfiles()
  }

  private func libraryJourney() throws {
    assertIdle()
    inspectSettings(save: true, unlock: false, name: "RC Library 01")
    inspectSettings(save: false, unlock: false, name: "RC Library 01")
    inspectSettings(save: true, unlock: false, name: "RC Library 24")
    inspectSettings(save: false, unlock: false, name: "RC Library 24")
    press("Settings")
    scrollTo(app.staticTexts["Saved Locations"])
    app.staticTexts["Saved Locations"].tap()
    XCTAssertTrue(app.staticTexts["RC Study"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "500")).firstMatch.exists)
    screenshot("saved-location")
    app.staticTexts["RC Study"].tap()
    XCTAssertTrue(app.staticTexts["51.5054, -0.0235"].waitForExistence(timeout: 10))
    screenshot("saved-location-coordinates")
    press("Cancel")
    press("Close")
    press("Close")
    openEditor("RC Library 23")
    scrollTo(app.staticTexts["RC Study"])
    XCTAssertTrue(app.staticTexts["RC Study"].exists)
    screenshot("location-reference")
    press("Cancel")
    closeProfiles()
    selectLibraryProfile(1)
    startFocus()
    XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 10))
    foreground()
    press("Stop")
    assertIdle()
    // Selecting a profile through the library makes its editor available, then the carousel is selected by a real swipe.
    selectLibraryProfile(6)
    press("Hold to Start")
    let text = "Please edit this profile before starting. Its start and stop settings need updating."
    XCTAssertTrue(app.alerts.staticTexts[text].waitForExistence(timeout: 10))
    screenshot("invalid-timer-refused")
    press("OK")
    assertIdle()
    openEditor("RC Library 06")
    scrollTo(app.buttons["Configure"].firstMatch)
    press("Configure")
    XCTAssertTrue(app.staticTexts["Timer Settings"].waitForExistence(timeout: 10))
    press("Set Duration")  // Normal editor repair, saved default duration 60 minutes.
    press("Update")
    closeProfiles()
    openEditor("RC Library 06")
    scrollTo(app.staticTexts["1h"])
    XCTAssertTrue(app.staticTexts["1h"].exists)
    screenshot("repaired-timer-settings")
    press("Cancel")
    closeProfiles()
    selectLibraryProfile(6)
    startFocus()
    assertCountdown(minutes: 60)
    emergencyUnblock(expectedRemaining: 3)
  }

  @MainActor
  func testV2DiagnosticsOptOut() throws {
    app.launchArguments = []
    app.launch()
    XCTAssertEqual(app.state, .runningForeground)
    screenshot("diagnostics-opt-out")
    app.terminate()
  }

  @MainActor
  func testV2Relaunch() throws {
    launch("relaunch")
    XCTAssertTrue(app.staticTexts["Hold to Start"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.buttons["Stop"].exists)
    if persona == "emergency" {
      press("Emergency")
      XCTAssertTrue(app.staticTexts["Unblocks remaining"].waitForExistence(timeout: 10))
      assertAdjacentValue("Unblocks remaining", expected: "0")
      screenshot("zero-emergency-after-relaunch")
    }
    screenshot("relaunch")
    attachReportCount()
    app.terminate()
  }
}
