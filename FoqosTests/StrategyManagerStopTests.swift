// FoqosTests/StrategyManagerStopTests.swift
import FoqosShared
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class StrategyManagerStopTests: XCTestCase {

  func testGivenManualStopEnabled_WhenStoppingWithManual_ThenAllowed() {
    var stop = ProfileStopConditions()
    stop.manual = true

    let result = StartStopActionResolver.canStop(
      with: .manual,
      conditions: stop,
      sessionTag: nil,
      stopNFCTagIds: [],
      stopQRCodeIds: []
    )

    XCTAssertTrue(result.allowed)
  }

  func testGivenManualStopDisabled_WhenStoppingWithManual_ThenNotAllowed() {
    var stop = ProfileStopConditions()
    stop.timer = true

    let result = StartStopActionResolver.canStop(
      with: .manual,
      conditions: stop,
      sessionTag: nil,
      stopNFCTagIds: [],
      stopQRCodeIds: []
    )

    XCTAssertFalse(result.allowed)
  }

  func testGivenAnyNFCEnabled_WhenStoppingWithNFC_ThenAllowed() {
    var stop = ProfileStopConditions()
    stop.anyNFC = true

    let result = StartStopActionResolver.canStop(
      with: .nfc(tag: "any-tag"),
      conditions: stop,
      sessionTag: nil,
      stopNFCTagIds: [],
      stopQRCodeIds: []
    )

    XCTAssertTrue(result.allowed)
  }

  func testGivenSpecificNFCEnabled_WhenStoppingWithMatchingTag_ThenAllowed() {
    var stop = ProfileStopConditions()
    stop.specificNFC = true

    let result = StartStopActionResolver.canStop(
      with: .nfc(tag: "required-tag"),
      conditions: stop,
      sessionTag: nil,
      stopNFCTagIds: ["required-tag"],
      stopQRCodeIds: []
    )

    XCTAssertTrue(result.allowed)
  }

  func testGivenSpecificNFCEnabled_WhenStoppingWithWrongTag_ThenNotAllowed() {
    var stop = ProfileStopConditions()
    stop.specificNFC = true

    let result = StartStopActionResolver.canStop(
      with: .nfc(tag: "wrong-tag"),
      conditions: stop,
      sessionTag: nil,
      stopNFCTagIds: ["required-tag"],
      stopQRCodeIds: []
    )

    XCTAssertFalse(result.allowed)
    XCTAssertNotNil(result.errorMessage)
  }

  func testGivenSameNFCEnabled_WhenStoppingWithMatchingSessionTag_ThenAllowed() {
    var stop = ProfileStopConditions()
    stop.sameNFC = true

    // Session tags are stored with "nfc:" prefix in production (via startWithNFCTag)
    let result = StartStopActionResolver.canStop(
      with: .nfc(tag: "session-tag"),
      conditions: stop,
      sessionTag: "nfc:session-tag",
      stopNFCTagIds: [],
      stopQRCodeIds: []
    )

    XCTAssertTrue(result.allowed)
  }

  func testGivenSameNFCEnabled_WhenStoppingWithDifferentTag_ThenNotAllowed() {
    var stop = ProfileStopConditions()
    stop.sameNFC = true

    let result = StartStopActionResolver.canStop(
      with: .nfc(tag: "different-tag"),
      conditions: stop,
      sessionTag: "nfc:original-tag",
      stopNFCTagIds: [],
      stopQRCodeIds: []
    )

    XCTAssertFalse(result.allowed)
    XCTAssertNotNil(result.errorMessage)
  }

  func testGivenSameQREnabled_WhenStoppingWithMatchingSessionTag_ThenAllowed() {
    var stop = ProfileStopConditions()
    stop.sameQR = true

    // Session tags are stored with "qr:" prefix in production (via startWithQRCode)
    let result = StartStopActionResolver.canStop(
      with: .qr(code: "session-code"),
      conditions: stop,
      sessionTag: "qr:session-code",
      stopNFCTagIds: [],
      stopQRCodeIds: []
    )

    XCTAssertTrue(result.allowed)
  }

  func testGivenSameQREnabled_WhenStoppingWithDifferentCode_ThenNotAllowed() {
    var stop = ProfileStopConditions()
    stop.sameQR = true

    let result = StartStopActionResolver.canStop(
      with: .qr(code: "different-code"),
      conditions: stop,
      sessionTag: "qr:original-code",
      stopNFCTagIds: [],
      stopQRCodeIds: []
    )

    XCTAssertFalse(result.allowed)
    XCTAssertNotNil(result.errorMessage)
  }

  // MARK: - determineStopAction Tests

  func testGivenManualAndNFC_WhenDeterminingStopAction_ThenStopImmediately() {
    var conditions = ProfileStopConditions()
    conditions.manual = true
    conditions.anyNFC = true  // Even with NFC, manual wins

    let action = StartStopActionResolver.determineStopAction(for: conditions)

    XCTAssertEqual(action, .stopImmediately)
  }

  func testGivenOnlyAnyNFC_WhenDeterminingStopAction_ThenScanNFC() {
    var conditions = ProfileStopConditions()
    conditions.anyNFC = true

    let action = StartStopActionResolver.determineStopAction(for: conditions)

    XCTAssertEqual(action, .scanNFC)
  }

  func testGivenOnlySameNFC_WhenDeterminingStopAction_ThenScanNFC() {
    var conditions = ProfileStopConditions()
    conditions.sameNFC = true

    let action = StartStopActionResolver.determineStopAction(for: conditions)

    XCTAssertEqual(action, .scanNFC)
  }

  func testGivenOnlySpecificNFC_WhenDeterminingStopAction_ThenScanNFC() {
    var conditions = ProfileStopConditions()
    conditions.specificNFC = true

    let action = StartStopActionResolver.determineStopAction(for: conditions)

    XCTAssertEqual(action, .scanNFC)
  }

  func testGivenOnlyAnyQR_WhenDeterminingStopAction_ThenScanQR() {
    var conditions = ProfileStopConditions()
    conditions.anyQR = true

    let action = StartStopActionResolver.determineStopAction(for: conditions)

    XCTAssertEqual(action, .scanQR)
  }

  func testGivenOnlySameQR_WhenDeterminingStopAction_ThenScanQR() {
    var conditions = ProfileStopConditions()
    conditions.sameQR = true

    let action = StartStopActionResolver.determineStopAction(for: conditions)

    XCTAssertEqual(action, .scanQR)
  }

  func testGivenOnlySpecificQR_WhenDeterminingStopAction_ThenScanQR() {
    var conditions = ProfileStopConditions()
    conditions.specificQR = true

    let action = StartStopActionResolver.determineStopAction(for: conditions)

    XCTAssertEqual(action, .scanQR)
  }

  func testGivenNFCAndQR_WhenDeterminingStopAction_ThenShowPicker() {
    var conditions = ProfileStopConditions()
    conditions.anyNFC = true
    conditions.anyQR = true

    let action = StartStopActionResolver.determineStopAction(for: conditions)

    XCTAssertEqual(action, .showPicker(options: [.scanNFC, .scanQR]))
  }

  func testGivenOnlyTimer_WhenDeterminingStopAction_ThenCannotStop() {
    var conditions = ProfileStopConditions()
    conditions.timer = true

    let action = StartStopActionResolver.determineStopAction(for: conditions)

    if case .cannotStop = action {
      // pass
    } else {
      XCTFail("Expected .cannotStop, got \(action)")
    }
  }

  func testGivenOnlySchedule_WhenDeterminingStopAction_ThenCannotStop() {
    var conditions = ProfileStopConditions()
    conditions.schedule = true

    let action = StartStopActionResolver.determineStopAction(for: conditions)

    if case .cannotStop = action {
      // pass
    } else {
      XCTFail("Expected .cannotStop, got \(action)")
    }
  }

  func testGivenEmptyConditions_WhenDeterminingStopAction_ThenCannotStop() {
    let conditions = ProfileStopConditions()

    let action = StartStopActionResolver.determineStopAction(for: conditions)

    if case .cannotStop = action {
      // pass
    } else {
      XCTFail("Expected .cannotStop, got \(action)")
    }
  }

  func testGivenAllConditionsEnabled_WhenDeterminingStopAction_ThenManualOverrides() {
    var conditions = ProfileStopConditions()
    conditions.manual = true
    conditions.anyNFC = true
    conditions.anyQR = true
    conditions.timer = true
    conditions.schedule = true

    let action = StartStopActionResolver.determineStopAction(for: conditions)

    XCTAssertEqual(action, .stopImmediately)
  }
  func testSpecificStopAcceptsSecondTagAndRejectsUnknownForBothKinds() {
    for isNFC in [true, false] {
      var conditions = ProfileStopConditions()
      conditions.specificNFC = isNFC
      conditions.specificQR = !isNFC
      for (value, allowed) in [("second", true), ("unknown", false)] {
        let result = StartStopActionResolver.canStop(
          with: isNFC ? .nfc(tag: value) : .qr(code: value), conditions: conditions,
          sessionTag: nil, stopNFCTagIds: ["first", "second"], stopQRCodeIds: ["first", "second"])
        XCTAssertEqual(result.allowed, allowed)
        if !allowed { XCTAssertEqual(result.errorMessage, isNFC ? "Scan the correct NFC tag to stop" : "Scan the correct QR code to stop") }
      }
    }
  }

  func testSameTagStillRequiresSessionTagEvenWhenScannedValueIsInStopList() {
    for isNFC in [true, false] {
      var conditions = ProfileStopConditions()
      conditions.sameNFC = isNFC
      conditions.sameQR = !isNFC
      let result = StartStopActionResolver.canStop(
        with: isNFC ? .nfc(tag: "other") : .qr(code: "other"), conditions: conditions,
        sessionTag: isNFC ? "nfc:session" : "qr:session", stopNFCTagIds: ["other"], stopQRCodeIds: ["other"])
      XCTAssertFalse(result.allowed)
    }
  }

  func testDeferredV1SessionEndMigratesAndEnqueuesProfileAndTagOnce() throws {
    let now = Date()
    let container = try TestModelContainer.create()
    let context = container.mainContext
    let facade = ProfileSyncManager.shared
    let previous = facade.engineController
    let enabled = facade.isEnabled
    let spy = MockSyncEngineControlling()
    // Keep migration upload assertions real, then suppress unrelated live session CloudKit I/O.
    spy.onTagSave = { facade.isEnabled = false }
    facade.engineController = spy
    facade.isEnabled = true
    defer {
      facade.engineController = previous
      facade.isEnabled = enabled
    }
    let profile = BlockedProfiles(name: "Legacy", createdAt: now, updatedAt: now)
    profile.profileSchemaVersion = 1
    profile.physicalUnblockNFCTagId = "stop-tag"
    context.insert(profile)
    let session = BlockedProfileSession.createSession(in: context, withTag: "nfc:start", withProfile: profile)
    try context.save()
    let manager = StrategyManager()
    defer { manager.stopTimer() }
    let strategy = manager.getStrategy(id: ManualBlockingStrategy.id)
    _ = strategy.stopBlocking(context: context, session: session)
    XCTAssertEqual(profile.profileSchemaVersion, 3)
    XCTAssertEqual(profile.stopNFCTagIds, ["stop-tag"])
    XCTAssertNotNil(try SavedTag.find(byID: "stop-tag", in: context))
    XCTAssertEqual(spy.enqueuedProfileSaves, [profile.id])
    XCTAssertEqual(spy.enqueuedTagSaves, ["stop-tag"])
  }

  func testDeferredV1NFCStrategyStillRequiresLegacyPhysicalUnblockTag() throws {
    let now = Date()
    let container = try TestModelContainer.create()
    let context = container.mainContext
    let profile = BlockedProfiles(name: "Legacy", createdAt: now, updatedAt: now)
    profile.profileSchemaVersion = 1
    profile.physicalUnblockNFCTagId = "required"
    context.insert(profile)
    let session = BlockedProfileSession.createSession(in: context, withTag: "nfc:start", withProfile: profile)
    try context.save()
    XCTAssertTrue(try profile.migrateIfEligible(hasActiveSession: true).isEmpty)
    let strategy = NFCBlockingStrategy()
    var rejection: String?
    strategy.onErrorMessage = { rejection = $0 }
    _ = strategy.stopBlocking(context: context, session: session)
    // Exercise the existing scanner callback without changing the scanner or opening hardware.
    let scanner = try XCTUnwrap(Mirror(reflecting: strategy).children.compactMap { $0.value as? NFCScannerUtil }.first)
    scanner.onTagScanned?(NFCResult(id: "wrong", dateScanned: now))
    XCTAssertTrue(session.isActive)
    XCTAssertNotNil(rejection)
    XCTAssertEqual(profile.physicalUnblockNFCTagId, "required")
    scanner.onTagScanned?(NFCResult(id: "required", dateScanned: now))
    XCTAssertFalse(session.isActive)
  }

  func testSpecificQRStopMatchesOldRawPrimarySpareAndNewPrintoutOnly() {
    let scan = " \nHTTPS://EXAMPLE.COM/\t"
    let oldHash = "f7bab0e3b417cf24e9a77e97a53fc4cea1084e20398a2e7258281e80239ca6f1"
    let newHash = QRCodeHasher.hash("https://example.com")
    for (ids, allowed) in [
      ([oldHash, "other"], true), (["other", oldHash], true),
      (["other", newHash], true), (["other"], false), ([], false),
    ] {
      let result = StartStopActionResolver.canStop(
        with: .qr(code: QRCodeHasher.hash(scan), rawHash: QRCodeHasher.rawHash(scan)),
        conditions: ProfileStopConditions(specificQR: true), sessionTag: nil,
        stopNFCTagIds: [oldHash, newHash], stopQRCodeIds: ids)
      XCTAssertEqual(result.allowed, allowed)
    }
  }

  func testSameQRStopMatchesOldSessionButNeverNFCPrefixOrAnotherSession() {
    let scan = " \nHTTPS://EXAMPLE.COM/\t"
    let oldHash = "f7bab0e3b417cf24e9a77e97a53fc4cea1084e20398a2e7258281e80239ca6f1"
    for (sessionTag, allowed) in [("qr:" + oldHash, true), ("nfc:" + oldHash, false), ("qr:other", false)] {
      let result = StartStopActionResolver.canStop(
        with: .qr(code: QRCodeHasher.hash(scan), rawHash: QRCodeHasher.rawHash(scan)),
        conditions: ProfileStopConditions(sameQR: true), sessionTag: sessionTag,
        stopNFCTagIds: [], stopQRCodeIds: [oldHash])
      XCTAssertEqual(result.allowed, allowed)
    }
  }

  func testLegacyQRStrategiesAcceptRawHashAndRejectUnknownScan() throws {
    let now = Date()
    let container = try TestModelContainer.create()
    let context = container.mainContext
    let payload = " \nHTTPS://EXAMPLE.COM/\t"
    let oldHash = "f7bab0e3b417cf24e9a77e97a53fc4cea1084e20398a2e7258281e80239ca6f1"
    for var strategy: any BlockingStrategy in [QRCodeBlockingStrategy(), QRManualBlockingStrategy(), QRTimerBlockingStrategy()] {
      let profile = BlockedProfiles(name: "Legacy", createdAt: now, updatedAt: now)
      profile.profileSchemaVersion = 1
      profile.physicalUnblockQRCodeId = oldHash
      context.insert(profile)
      let session = BlockedProfileSession.createSession(in: context, withTag: "qr:other", withProfile: profile)
      try context.save()
      var rejection: String?
      strategy.onErrorMessage = { rejection = $0 }
      let scanner = try XCTUnwrap(strategy.stopBlocking(context: context, session: session) as? LabeledCodeScannerView)
      scanner.onScanResult(.success((hash: "wrong", rawHash: "also-wrong")))
      XCTAssertTrue(session.isActive)
      XCTAssertNotNil(rejection)
      scanner.onScanResult(.success((hash: QRCodeHasher.hash(payload), rawHash: QRCodeHasher.rawHash(payload))))
      XCTAssertFalse(session.isActive)
    }
  }

}
