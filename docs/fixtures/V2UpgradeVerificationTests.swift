// Copied temporarily into the selected V2 worktree test target by the runbook.
import CoreNFC
import FoqosShared
import Foundation
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class RCUpgradeVerificationTests: XCTestCase {
  func testActualV1InstallUpgrade() async throws {
    let now = Date()
    let container = try AppModelStore.makeContainer()
    let context = container.mainContext
    let seedURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/rc-v1-seed.json")
    let seed = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: seedURL)) as? [String: Any])
    let profiles = try BlockedProfiles.fetchProfiles(in: context)
    XCTAssertEqual(profiles.count, 14)
    let named = Dictionary(uniqueKeysWithValues: profiles.map { ($0.name, $0) })
    func profile(_ name: String) throws -> BlockedProfiles { try XCTUnwrap(named["RC " + name]) }
    let active = try profile("active NFC")
    let original = try XCTUnwrap(try BlockedProfileSession.mostRecentActiveSession(in: context))
    XCTAssertEqual(original.id, seed["sessionID"] as? String)
    XCTAssertEqual(original.startTime.timeIntervalSince1970, try XCTUnwrap(seed["sessionStart"] as? Double), accuracy: 0.001)
    XCTAssertEqual(original.tag, "nfc:04AABBCCDD")
    let shared = try XCTUnwrap(SharedData.getActiveSharedSession())
    XCTAssertEqual(shared.id, original.id)
    XCTAssertEqual(shared.startTime, original.startTime)
    XCTAssertFalse(shared.oneMoreMinuteUsed)
    XCTAssertNil(shared.origin)

    XCTAssertNil(original.endTime)
    XCTAssertEqual(active.profileSchemaVersion, 1)
    XCTAssertEqual(active.blockingStrategyId, NFCBlockingStrategy.id)
    XCTAssertNil(original.origin)
    let wasEnabled = ProfileSyncManager.shared.isEnabled
    ProfileSyncManager.shared.isEnabled = false
    defer { ProfileSyncManager.shared.isEnabled = wasEnabled }
    _ = ProfileMigrationUtil.migrateProfilesIfNeeded(context: context)
    XCTAssertEqual(active.profileSchemaVersion, 1)
    for p in profiles {
      XCTAssertTrue(p.enableLiveActivity, p.name)
      XCTAssertEqual(p.reminderTimeInSeconds, 300, p.name)
      XCTAssertEqual(p.customReminderMessage, "RC retained reminder", p.name)
      XCTAssertTrue(p.enableBreaks, p.name)
      XCTAssertEqual(p.breakTimeInMinutes, 7, p.name)
      XCTAssertTrue(p.enableStrictMode, p.name)
      XCTAssertTrue(p.enableAllowMode, p.name)
      XCTAssertTrue(p.enableAllowModeDomains, p.name)
      XCTAssertFalse(p.enableSafariBlocking, p.name)
      XCTAssertEqual(p.domains, ["example.com"], p.name)
      XCTAssertTrue(p.isManaged, p.name)
      if p !== active { XCTAssertEqual(p.profileSchemaVersion, 3, p.name) }
    }
    for (name, type) in [("plain NFC", TagType.nfc), ("plain QR", .qr)] {
      let p = try profile(name)
      XCTAssertEqual(p.startTriggers, type == .nfc ? .init(anyNFC: true) : .init(anyQR: true))
      XCTAssertEqual(p.stopConditions, type == .nfc ? .init(nfc: .same) : .init(qr: .same))
      XCTAssertFalse(p.hasInvalidConditionSettings)
    }
    XCTAssertEqual(try profile("specific NFC").stopConditions.nfc, .specific)
    XCTAssertEqual(try profile("specific NFC").stopNFCTagIds, ["04AABBCCDD"])
    XCTAssertEqual(try profile("specific QR").stopConditions.qr, .specific)
    XCTAssertEqual(try profile("specific QR").stopQRCodeIds, [QRCodeHasher.hash("legacy-unlock-qr")])
    for name in ["Shortcut timer", "NFC timer", "QR timer", "manual NFC", "manual QR", "schedule", "manual"] {
      let p = try profile(name)
      XCTAssertTrue(p.startTriggers.manual, p.name)
      XCTAssertTrue(p.startTriggers.shortcuts, p.name)
      XCTAssertTrue(p.startTriggers.deepLink, p.name)
      XCTAssertFalse(p.hasInvalidConditionSettings, p.name)
    }
    for name in ["Shortcut timer", "NFC timer", "QR timer"] {
      XCTAssertEqual(try profile(name).stopConditions.timerDurationMinutes, 37)
      XCTAssertFalse(try profile(name).stopConditions.allowChangingTimerBeforeStart)
    }
    let scheduled = try profile("schedule")
    XCTAssertTrue(scheduled.startTriggers.schedule)
    XCTAssertTrue(scheduled.stopConditions.schedule)
    XCTAssertEqual(scheduled.startSchedule?.days, [.monday, .friday])
    XCTAssertEqual(scheduled.stopSchedule?.days, [.monday, .friday])
    XCTAssertEqual(scheduled.startSchedule?.hour, 9)
    XCTAssertEqual(scheduled.startSchedule?.minute, 13)
    XCTAssertEqual(scheduled.stopSchedule?.hour, 17)
    XCTAssertEqual(scheduled.stopSchedule?.minute, 47)
    let manager = StrategyManager(
      appBlocker: RecordingRestrictionApplier(),
      registerTimer: { _, _, minutes, date in
        XCTAssertEqual(minutes, 37)
        return date.addingTimeInterval(Double(minutes) * 60)
      }, cancelTimer: { _, _ in }, startSessionActivity: { _ in }, cancelPreActivationReminders: { _ in }, scheduleReconciler: { _ in })
    defer { manager.stopTimer() }
    // Exercise the retained V1 scanner callback, then the real post-session migration boundary.
    let legacy = manager.getStrategy(id: NFCBlockingStrategy.id)
    _ = legacy.stopBlocking(context: context, session: original)
    let scanner = try XCTUnwrap(Mirror(reflecting: legacy).children.compactMap { $0.value as? NFCScannerUtil }.first)
    scanner.onTagScanned?(NFCResult(id: "WRONG", dateScanned: now))
    XCTAssertTrue(original.isActive)
    XCTAssertEqual(active.profileSchemaVersion, 1)
    scanner.onTagScanned?(NFCResult(id: "04AABBCCDD", dateScanned: now))
    XCTAssertFalse(original.isActive)
    XCTAssertEqual(active.profileSchemaVersion, 3)
    manager.activeSession = nil
    manager.errorMessage = nil
    let edit = "Please edit this profile before starting. Its start and stop settings need updating."
    for name in ["missing timer", "invalid key"] {
      let p = try profile(name)
      XCTAssertTrue(p.hasInvalidConditionSettings)
      for origin: SessionOrigin in [.init(kind: .manual), .init(kind: .shortcut), .init(kind: .link), .init(kind: .nfc, key: "04AABBCCDD", namespace: .nfcUID)] {
        XCTAssertThrowsError(try manager.startOriginatingSession(context: context, profile: p, origin: origin, now: now)) { XCTAssertEqual($0.localizedDescription, edit) }
      }
    }
    // Actual converted profiles through the shared in-app/background tag router.
    for (name, type, namespace, key) in [
      ("plain NFC", TagType.nfc, SessionOrigin.KeyNamespace.nfcUID, "04AABBCCDD"),
      ("plain QR", .qr, .qrDigest, QRCodeHasher.hash("ordinary-qr")),
      ("specific NFC", .nfc, .nfcUID, "04AABBCCDD"),
      ("specific QR", .qr, .qrDigest, QRCodeHasher.hash("legacy-unlock-qr")),
    ] {
      let p = try profile(name)
      let event = TagEvent(type: type, namespace: namespace, key: key, targetProfileId: p.id)
      await manager.handleTagEvent(event, operation: .scan, context: context, now: now)
      let session = try XCTUnwrap(manager.activeSession, p.name + ": " + (manager.errorMessage ?? "no manager error"))
      XCTAssertEqual(session.blockedProfile.id, p.id)
      await manager.handleTagEvent(TagEvent(type: type, namespace: namespace, key: "wrong"), operation: .scan, context: context, now: now)
      XCTAssertTrue(session.isActive)
      await manager.handleTagEvent(TagEvent(type: type, namespace: namespace, key: key), operation: .scan, context: context, now: now)
      XCTAssertFalse(session.isActive)
      manager.activeSession = nil
      manager.errorMessage = nil
      manager.cancelTagOperation()
    }
    for (name, type) in [("plain NFC", TagType.nfc), ("plain QR", .qr)] {
      let p = try profile(name)
      await manager.handleTagEvent(TagEvent(type: type, namespace: nil, key: nil, targetProfileId: p.id, unidentifiedLegacyTag: true), operation: .scan, context: context, now: now)
      let session = try XCTUnwrap(manager.activeSession)
      XCTAssertEqual(session.blockedProfile.id, p.id)
      await manager.handleTagEvent(TagEvent(type: type, namespace: type == .nfc ? .nfcUID : .qrDigest, key: "different-legacy-key"), operation: .scan, context: context, now: now)
      XCTAssertFalse(session.isActive)
      manager.activeSession = nil
      manager.errorMessage = nil
      manager.cancelTagOperation()
    }
    let timerProfile = try profile("Shortcut timer")
    XCTAssertEqual(try manager.startSessionFromBackground(timerProfile.id, context: context, authorization: MockAuthorizationRequesting(initialStatus: .approved), mode: .individual), timerProfile.name)
    let timed = try XCTUnwrap(manager.activeSession)
    XCTAssertEqual(try XCTUnwrap(timed.timerEndTime).timeIntervalSince(timed.startTime), 2220, accuracy: 0.001)
    XCTAssertEqual(timerProfile.stopConditions.timerDurationMinutes, 37)
    timed.endSession(now: now)
    manager.activeSession = nil
    XCTAssertThrowsError(try manager.startSessionFromBackground(timerProfile.id, context: context, durationInMinutes: 42, authorization: MockAuthorizationRequesting(initialStatus: .approved), mode: .individual)) { error in
      guard case IntentError.unexpected(let message) = error else {
        XCTFail("Wrong error: \(error)")
        return
      }
      XCTAssertEqual(message, "This start uses the profile’s saved timer. Remove Duration from the Shortcut or edit the profile’s timer.")
    }
    try context.save()
    let evidence = profiles.map { p in ["name": p.name, "schema": p.profileSchemaVersion, "invalid": p.hasInvalidConditionSettings, "starts": String(describing: p.startTriggers), "stops": String(describing: p.stopConditions)] as [String: Any] }
    try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]).write(to: seedURL.deletingLastPathComponent().appendingPathComponent("rc-upgrade-verification.json"))
  }
}
