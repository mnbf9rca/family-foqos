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
    XCTAssertTrue(app.staticTexts[persona == "library" ? "RC Library 01" : "RC \(persona)"].waitForExistence(timeout: 20))
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
    if title == "Stop" || title == "Hold to Start" { dismissRatingPrompt(checkIdle: false) }
  }

  @MainActor
  private func openStats() {
    let rows = app.buttons.matching(identifier: "Stats for Nerds")
    let deadline = Date().addingTimeInterval(2)
    var previousFrame: CGRect?
    var settledRow: XCUIElement?
    while Date() < deadline {
      let visible = rows.allElementsBoundByIndex.filter { self.app.frame.contains($0.frame) && $0.isHittable }
      if visible.count == 1 {
        let frame = visible[0].frame
        if frame == previousFrame {
          settledRow = visible[0]
          break
        }
        previousFrame = frame
      } else {
        previousFrame = nil
      }
      Thread.sleep(forTimeInterval: 0.1)
    }
    guard let settledRow else {
      XCTFail("Stats menu row did not settle within 2 seconds\n\(app.debugDescription)")
      return
    }
    settledRow.tap()
    let sheet = app.navigationBars["Stats for Nerds"]
    if !sheet.waitForExistence(timeout: 2) {
      let remaining = rows.allElementsBoundByIndex.filter { self.app.frame.contains($0.frame) && $0.isHittable }
      guard remaining.count <= 1 else {
        XCTFail("Stats menu row is ambiguous\n\(app.debugDescription)")
        return
      }
      if let row = remaining.first {
        screenshot("stats-menu-retry")
        let evidence = XCTAttachment(string: "One Stats retry: sheet absent; exactly one visible, hittable menu row remains.")
        evidence.name = "stats-menu-retry-1"
        evidence.lifetime = .keepAlways
        add(evidence)
        row.tap()
      }
    }
    XCTAssertTrue(sheet.waitForExistence(timeout: 10), "Stats sheet did not open after its bounded menu interaction")
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
    openStats()
    let statistics = app.scrollViews.containing(.staticText, identifier: "Total Focus Time")
    XCTAssertTrue(statistics.firstMatch.waitForExistence(timeout: 10))
    XCTAssertEqual(statistics.count, 1, "History must resolve to exactly one Stats scroll view")
    assertAdjacentValue("Total Sessions", expected: "1", within: statistics.firstMatch)  // Completed history only.
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
        stopWithScan(wrong: true, legacy: true)
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

  private func dismissRatingPrompt(checkIdle: Bool = true) {
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    let inApp = app.buttons["Not Now"]
    let later = inApp.waitForExistence(timeout: 2) ? inApp : springboard.buttons["Not Now"]
    let title = "Enjoying Family Foqos?"
    if later.exists {
      let owner = inApp.exists ? app : springboard
      let reviewTitle = owner.staticTexts[title]
      XCTAssertTrue(reviewTitle.waitForExistence(timeout: 2), "Not Now does not belong to the StoreKit review prompt")
      guard reviewTitle.exists else { return }
      screenshot("rating-prompt")
      later.tap()  // A normal StoreKit request, never an error or action refusal.
    } else {
      XCTAssertFalse(app.staticTexts[title].exists || springboard.staticTexts[title].exists, "StoreKit prompt has no Not Now control")
    }
    if checkIdle {
      let ready = XCTNSPredicateExpectation(
        predicate: NSPredicate { _, _ in
          self.app.staticTexts.matching(identifier: "Hold to Start").allElementsBoundByIndex.contains {
            self.app.frame.contains($0.frame) && $0.isHittable
          }
        }, object: nil)
      XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed, "Visible Home start control is not usable")
    }
  }

  private func completeQRScan() {
    if persona.contains("qr") {
      let text = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "You're running in the simulator")).firstMatch
      XCTAssertTrue(text.waitForExistence(timeout: 10))
      text.tap()  // CodeScanner's own simulator callback, through the real presented scanner.
    }
  }

  private func stopWithScan(wrong: Bool, legacy: Bool = false) {
    press("Stop")
    if wrong && !legacy {
      completeQRScan()  // The first wrong scan opens the real V2 confirmation sheet.
      let cancel = app.buttons["Cancel"]
      XCTAssertTrue(cancel.waitForExistence(timeout: 10), "Specific stop must require scan confirmation")
      if persona == "manual-nfc" {
        XCTAssertTrue(app.buttons["Scan NFC Tag"].waitForExistence(timeout: 10))
      } else {
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "You're running in the simulator")).firstMatch.waitForExistence(timeout: 10))
      }
      XCTAssertTrue(app.buttons["Stop"].exists, "A wrong scan must keep the session active")
      XCTAssertFalse(
        app.staticTexts.matching(identifier: "Hold to Start").allElementsBoundByIndex.contains {
          self.app.frame.contains($0.frame) && $0.isHittable
        }, "Idle Home must remain inaccessible")
      screenshot("specific-stop-confirmation")
      if persona == "manual-nfc" { press("Scan NFC Tag") } else { completeQRScan() }
      let message = persona == "manual-nfc" ? "That NFC tag doesn’t match. Scan the required tag." : "That QR code doesn’t match. Scan the required code."
      XCTAssertTrue(app.staticTexts[message].waitForExistence(timeout: 10), "Wrong confirmation scan must show its inline refusal")
      XCTAssertTrue(cancel.exists)
      XCTAssertTrue(app.buttons["Stop"].exists)
      screenshot("specific-stop-wrong-refused")
      if persona == "manual-nfc" { press("Scan NFC Tag") } else { completeQRScan() }
      XCTAssertTrue(cancel.waitForNonExistence(timeout: 10), "Correct scan must dismiss confirmation")
      assertIdle()
      return
    }
    if app.buttons["Scan NFC Tag"].exists { press("Scan NFC Tag") }
    if app.buttons["Scan QR Code"].exists { press("Scan QR Code") }
    completeQRScan()
    if wrong {
      let item = persona.contains("qr") ? "QR code" : "NFC tag"
      let message =
        legacy
        ? persona.hasPrefix("manual-")
          ? "This \(item) is not allowed to unblock this profile. Physical unblock setting is on for this profile"
          : persona == "nfc" ? "You must scan the original tag to stop focus" : "You must scan the original QR code to stop focus"
        : "That \(item) doesn’t match. Scan the required \(persona.contains("qr") ? "code" : "tag")."
      let refusal = app.alerts.containing(.staticText, identifier: message).firstMatch
      XCTAssertTrue(refusal.waitForExistence(timeout: 10), "Wrong scan must show its actual refusal")
      screenshot("wrong-scan-refused")
      XCTAssertTrue(app.buttons["Stop"].exists)
      refusal.buttons["OK"].tap()
      press("Stop")
      if app.buttons["Scan NFC Tag"].exists { press("Scan NFC Tag") }
      if app.buttons["Scan QR Code"].exists { press("Scan QR Code") }
      completeQRScan()
    }
    assertIdle()
  }

  private func startFocus(timerMinutes: Int = 37) {
    press("Hold to Start")
    if app.buttons["Start Now"].exists { press("Start Now") }
    if app.buttons["Scan NFC Tag"].exists { press("Scan NFC Tag") }
    if app.buttons["Scan QR Code"].exists { press("Scan QR Code") }
    if persona == "qr" { completeQRScan() }
    if app.staticTexts["Timer Settings"].exists {
      let duration = timerMinutes == 60 ? "1h" : "\(timerMinutes)m"
      XCTAssertTrue(app.staticTexts[duration].exists, "Interactive timer must retain its saved duration")
      screenshot("saved-timer-duration")
      press("Set Duration")
    }
  }

  private func assertCountdown(minutes: Int) {
    // These 37/60-minute timers show M:SS or MM:SS; the separate elapsed clock shows HH:MM:SS.
    let timer = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "^[0-9]{1,2}:[0-9]{2}$")).firstMatch
    XCTAssertTrue(timer.waitForExistence(timeout: 10))
    let before = timer.label
    let values = before.split(separator: ":").compactMap { Int($0) }
    XCTAssertEqual(values.count, 2)
    let seconds = values[0] * 60 + values[1]
    XCTAssertGreaterThan(seconds, (minutes - 2) * 60)
    XCTAssertLessThanOrEqual(seconds, minutes * 60)
    let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in timer.label != before }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 8), .completed, "Countdown did not decrease")
    let after = timer.label.split(separator: ":").compactMap { Int($0) }
    XCTAssertEqual(after.count, 2)
    XCTAssertLessThan(after[0] * 60 + after[1], seconds)
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
    dismissRatingPrompt(checkIdle: false)
    XCTAssertFalse(app.alerts.firstMatch.exists, "Emergency unblock must succeed without a hidden failure")
    // The production action dismisses the sheet on successful completion.
    XCTAssertTrue(app.staticTexts["Emergency Access"].waitForNonExistence(timeout: 10))
    if persona == "library" { libraryIndex = 1 }
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
      let heading = app.staticTexts["Continue until..."]
      let option = persona == "manual-nfc" ? "Specific tag" : "Specific code"
      let selection = app.descendants(matching: .any).matching(
        NSPredicate(format: "label == %@ OR value == %@", option, option)
      ).firstMatch
      XCTAssertTrue(selection.exists)
      XCTAssertGreaterThan(selection.frame.minY, heading.frame.maxY, "Specific picker must belong to the stop section")
      let key = persona == "manual-nfc" ? "tag" : "code"
      let selected = app.buttons["RC \(persona) stop \(key)"]
      scrollTo(selected)
      XCTAssertEqual(selected.value as? String, "Selected")
      XCTAssertGreaterThan(selected.frame.minY, heading.frame.maxY, "Selected key must belong to the stop section")
      screenshot("specific-stop-key")
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

  private func assertAdjacentValue(_ label: String, expected: String, within scope: XCUIElement? = nil) {
    let container = scope ?? app
    var geometry = "No snapshot captured"
    let adjacent = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        let window = self.app.frame
        let labels = container.staticTexts.matching(NSPredicate(format: "label == %@", label))
          .allElementsBoundByIndex.map { $0.frame }.filter { !$0.isEmpty && window.contains($0) }
        let values = container.staticTexts.matching(NSPredicate(format: "label == %@", expected))
          .allElementsBoundByIndex.map { $0.frame }.filter { !$0.isEmpty && window.contains($0) }
        geometry = "label=\(labels), expected value=\(values), window=\(window)"
        guard labels.count == 1, let title = labels.first else { return false }
        return values.contains {
          abs($0.minX - title.minX) < 2 && $0.minY >= title.maxY && $0.minY - title.maxY < 25
        }
      }, object: nil)
    let result = XCTWaiter.wait(for: [adjacent], timeout: 10)
    if result != .completed {
      let evidence = XCTAttachment(string: "Scoped hierarchy:\n\(container.debugDescription)\nApplication hierarchy:\n\(app.debugDescription)")
      evidence.name = "adjacent-value-timeout"
      evidence.lifetime = .keepAlways
      add(evidence)
      screenshot("adjacent-value-timeout")
    }
    XCTAssertEqual(
      result, .completed,
      "Wrong adjacent value for \(label): expected \(expected)\n\(geometry)")
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
    scrollTo(app.staticTexts["Within RC Study"])
    XCTAssertTrue(app.staticTexts["Within RC Study"].exists)
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
    let refusal = app.alerts.containing(.staticText, identifier: text).firstMatch
    XCTAssertTrue(refusal.waitForExistence(timeout: 10))
    screenshot("invalid-timer-refused")
    refusal.buttons["OK"].tap()
    assertIdle()
    openEditor("RC Library 06")
    scrollTo(app.buttons["Configure"].firstMatch)
    press("Configure")
    XCTAssertTrue(app.staticTexts["Timer Settings"].waitForExistence(timeout: 10))
    press("Set Duration")  // Normal editor repair, saved default duration 60 minutes.
    press("Update")
    closeProfiles()
    openEditor("RC Library 06")
    scrollTo(app.staticTexts["60 min"])
    XCTAssertTrue(app.staticTexts["60 min"].exists)
    screenshot("repaired-timer-settings")
    press("Cancel")
    closeProfiles()
    selectLibraryProfile(6)
    startFocus(timerMinutes: 60)
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
    if persona == "library" { selectLibraryProfile(6) }
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
