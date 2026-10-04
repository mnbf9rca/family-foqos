import CoreNFC
import FoqosShared
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class LegacyTagIdentityTests: XCTestCase {
  private var container: ModelContainer!
  private var suite: String!
  private var context: ModelContext { container.mainContext }
  private var syncWasEnabled = false
  private let uid = "04AABBCCDD"
  private let appURL = "https://family-foqos.app/profile/11111111-1111-1111-1111-111111111111?source=V1%20tag"

  override func setUp() async throws {
    suite = "LegacyTagIdentityTests-\(UUID())"
    SharedData.configure(suite: UserDefaults(suiteName: suite)!)
    container = try TestModelContainer.create()
    syncWasEnabled = ProfileSyncManager.shared.isEnabled
    ProfileSyncManager.shared.isEnabled = false
  }

  override func tearDown() async throws {
    ProfileSyncManager.shared.isEnabled = syncWasEnabled
    UserDefaults().removePersistentDomain(forName: suite)
  }

  private func nfc(_ id: String, url: String? = nil, now: Date) throws -> NFCResult {
    let message = url.map { NFCNDEFMessage(records: [NFCNDEFPayload.wellKnownTypeURIPayload(url: URL(string: $0)!)!]) }
    return try NFCResult.read(id: id, message: message, error: nil, now: now)
  }

  private func session(strategy: String, tag: String, physical: String? = nil, nfc: Bool, force: Bool = false, now: Date) throws -> BlockedProfileSession {
    let p = BlockedProfiles(name: "V1", createdAt: now, updatedAt: now)
    p.profileSchemaVersion = 1
    p.blockingStrategyId = strategy
    if nfc { p.physicalUnblockNFCTagId = physical } else { p.physicalUnblockQRCodeId = physical }
    context.insert(p)
    let s = BlockedProfileSession(tag: tag, blockedProfile: p, forceStarted: force, startTime: now)
    context.insert(s)
    try context.save()
    XCTAssertNil(p.startTriggersData)
    XCTAssertNil(p.stopConditionsData)
    SharedData.createActiveSharedSession(for: s.toSnapshot())
    return s
  }

  func testNFCOriginalTagAcceptsRealV1UIDAndURLAlongsidePrefixedUID() throws {
    let now = Date()
    for stored in [uid, appURL, "nfc:\(uid)"] {
      let scanner = IdentityNFCScanner()
      let strategy = NFCBlockingStrategy(nfcScanner: scanner)
      let s = try session(strategy: NFCBlockingStrategy.id, tag: stored, nfc: true, now: now)
      _ = strategy.stopBlocking(context: context, session: s)
      scanner.onTagScanned?(try nfc("112233", url: stored == appURL ? appURL + "x" : nil, now: now))
      XCTAssertTrue(s.isActive, stored)
      if stored == appURL {
        scanner.onTagScanned?(try nfc(uid, url: appURL + "x", now: now))
        XCTAssertTrue(s.isActive, "The same chip with different URL content is not the V1 URL identity")
      }
      scanner.onTagScanned?(try nfc(uid, url: stored == appURL ? appURL : nil, now: now))
      XCTAssertFalse(s.isActive, stored)
    }
  }

  func testAllNFCLegacyStrategiesHonorRawPhysicalKeysEvenWhenForceStarted() throws {
    let now = Date()
    for kind in 0..<3 {
      for physical in [uid, appURL] {
        let scanner = IdentityNFCScanner()
        let strategies: [BlockingStrategy] = [NFCBlockingStrategy(nfcScanner: scanner), NFCManualBlockingStrategy(nfcScanner: scanner), NFCTimerBlockingStrategy(nfcScanner: scanner)]
        let strategy = strategies[kind]
        let s = try session(strategy: strategy.getIdentifier(), tag: "old initiating tag", physical: physical, nfc: true, force: true, now: now)
        _ = strategy.stopBlocking(context: context, session: s)
        scanner.onTagScanned?(try nfc("112233", url: physical == appURL ? appURL + "x" : nil, now: now))
        XCTAssertTrue(s.isActive, "Physical key overrides forceStarted")
        scanner.onTagScanned?(try nfc(uid, url: physical == appURL ? appURL : nil, now: now))
        XCTAssertFalse(s.isActive, "\(strategy.getIdentifier()) / \(physical)")
      }
    }
  }

  func testV1NFCURLSelectionDoesNotAdoptThirdPartyOrDuplicateRecords() throws {
    let now = Date()
    let own = NFCNDEFPayload.wellKnownTypeURIPayload(url: URL(string: appURL)!)!
    let foreign = NFCNDEFPayload.wellKnownTypeURIPayload(url: URL(string: "https://example.com/tag")!)!
    for records in [[foreign], [own, own]] {
      let scanner = IdentityNFCScanner()
      let strategy = NFCBlockingStrategy(nfcScanner: scanner)
      let s = try session(strategy: NFCBlockingStrategy.id, tag: uid, nfc: true, now: now)
      _ = strategy.stopBlocking(context: context, session: s)
      scanner.onTagScanned?(try NFCResult.read(id: uid, message: NFCNDEFMessage(records: records), error: nil, now: now))
      XCTAssertFalse(s.isActive, "V1 chose the UID when there was not exactly one matching URI")
    }
    XCTAssertThrowsError(try NFCResult.read(id: uid, message: NFCNDEFMessage(records: [own]), error: NSError(domain: "read", code: 1), now: now))
  }

  func testQRSessionUsesExactV1TextAndStillReadsV2PrefixedDigests() throws {
    let now = Date()
    let raw = "  HTTPS://EXAMPLE.COM/  "
    let scan = try QRScanResult.read(raw)
    for stored in [raw, "qr:\(scan.hash)", "qr:\(scan.rawHash)"] {
      let strategy = QRCodeBlockingStrategy()
      let s = try session(strategy: strategy.getIdentifier(), tag: stored, nfc: false, now: now)
      let view = try XCTUnwrap(strategy.stopBlocking(context: context, session: s) as? LabeledCodeScannerView)
      view.onScanResult(.success(try QRScanResult.read("wrong code")))
      XCTAssertTrue(s.isActive)
      if stored == raw {
        // Retained V1 sessions compare exact text; normalized equivalence is a V2 policy.
        view.onScanResult(.success(try QRScanResult.read("https://example.com")))
        XCTAssertTrue(s.isActive)
      }
      view.onScanResult(.success(scan))
      XCTAssertFalse(s.isActive, stored)
    }
  }

  func testAllQRLegacyStrategiesHonorRawAndDigestPhysicalKeys() throws {
    let now = Date()
    let raw = "  V1 printed QR string  "
    let scan = try QRScanResult.read(raw)
    for strategy in [QRCodeBlockingStrategy(), QRManualBlockingStrategy(), QRTimerBlockingStrategy()] as [BlockingStrategy] {
      for physical in [raw, scan.hash, scan.rawHash] {
        let s = try session(strategy: strategy.getIdentifier(), tag: "old initiating code", physical: physical, nfc: false, force: true, now: now)
        let view = try XCTUnwrap(strategy.stopBlocking(context: context, session: s) as? LabeledCodeScannerView)
        view.onScanResult(.success(try QRScanResult.read("wrong code")))
        XCTAssertTrue(s.isActive, "Physical key overrides forceStarted")
        view.onScanResult(.success(scan))
        XCTAssertFalse(s.isActive, "\(strategy.getIdentifier()) / \(physical)")
      }
    }
  }

  func testForceStartedSameTagStrategiesAllowAnyScanWithoutPhysicalKey() throws {
    let now = Date()
    let scanner = IdentityNFCScanner()
    let n = NFCBlockingStrategy(nfcScanner: scanner)
    let ns = try session(strategy: n.getIdentifier(), tag: "old UID", nfc: true, force: true, now: now)
    _ = n.stopBlocking(context: context, session: ns)
    scanner.onTagScanned?(try nfc(uid, now: now))
    XCTAssertFalse(ns.isActive)
    let q = QRCodeBlockingStrategy()
    let qs = try session(strategy: q.getIdentifier(), tag: "old QR", nfc: false, force: true, now: now)
    let view = try XCTUnwrap(q.stopBlocking(context: context, session: qs) as? LabeledCodeScannerView)
    view.onScanResult(.success(try QRScanResult.read("another QR")))
    XCTAssertFalse(qs.isActive)
  }

  func testConvertedV1PhysicalKeysMatchSpecificScans() throws {
    let now = Date()
    let rawQR = "  HTTPS://EXAMPLE.COM/  "
    for (isNFC, raw) in [(true, uid), (true, appURL), (false, rawQR)] {
      let s = try session(strategy: isNFC ? NFCManualBlockingStrategy.id : QRManualBlockingStrategy.id, tag: ManualBlockingStrategy.id, physical: raw, nfc: isNFC, now: now)
      s.endSession(now: now)
      let p = s.blockedProfile
      XCTAssertTrue(try ProfileMigrationUtil.migrate(p, hasActiveSession: false))
      let good = try isNFC ? XCTUnwrap(nfc(uid, url: raw == appURL ? appURL : nil, now: now).event) : XCTUnwrap(QRScanResult.read("https://example.com").event)
      let bad = try isNFC ? XCTUnwrap(nfc("112233", url: raw == appURL ? appURL + "x" : nil, now: now).event) : XCTUnwrap(QRScanResult.read("wrong code").event)
      // Converted QR Specific uses V2 normalization; unlike the retained V1 path above.
      for (event, allowed) in [(bad, false), (good, true)] {
        XCTAssertEqual(StartStopActionResolver.canStop(with: .tag(event), conditions: p.stopConditions, sessionTag: nil, stopNFCTagIds: p.stopNFCTagIds, stopQRCodeIds: p.stopQRCodeIds).allowed, allowed, raw)
      }
      XCTAssertEqual(p.profileSchemaVersion, 3)
    }
  }

  func testConvertedURLKeySupportsSpecificStartAndSameStop() async throws {
    let now = Date()
    let s = try session(strategy: NFCManualBlockingStrategy.id, tag: ManualBlockingStrategy.id, nfc: true, now: now)
    s.endSession(now: now)
    let p = s.blockedProfile
    let url = "https://family-foqos.app/profile/\(p.id)?source=V1%20tag"
    p.physicalUnblockNFCTagId = url
    XCTAssertTrue(try ProfileMigrationUtil.migrate(p, hasActiveSession: false))
    p.startNFCTagIds = p.stopNFCTagIds
    p.startTriggers = .init(specificNFC: true)
    p.stopConditions = .init(nfc: .same)
    try context.save()
    let manager = StrategyManager(startSessionActivity: { _ in }, cancelPreActivationReminders: { _ in })
    defer { manager.stopTimer() }
    let wrong = try XCTUnwrap(nfc("112233", now: now).event)
    let good = try XCTUnwrap(nfc(uid, url: url, now: now).event)
    await manager.handleTagEvent(wrong, operation: .explicitStart(p.id), context: context, now: now)
    XCTAssertNil(manager.activeSession)
    await manager.handleTagEvent(good, operation: .explicitStart(p.id), context: context, now: now)
    let active = try XCTUnwrap(manager.activeSession)
    XCTAssertEqual(active.origin?.key, url)
    await manager.handleTagEvent(wrong, operation: .scan, context: context, now: now)
    XCTAssertTrue(active.isActive)
    await manager.handleTagEvent(good, operation: .scan, context: context, now: now)
    XCTAssertFalse(active.isActive)
  }

  func testURLCompatibilityDoesNotCrossOpaqueOrBackgroundBoundaries() throws {
    let now = Date()
    let typed = "https://family-foqos.app/profile/11111111-1111-1111-1111-111111111111/nfc/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    let typedEvent = try XCTUnwrap(nfc(uid, url: typed, now: now).event)
    XCTAssertFalse(StartStopActionResolver.canStop(with: .tag(typedEvent), conditions: .init(nfc: .specific), sessionTag: nil, stopNFCTagIds: [typed, uid], stopQRCodeIds: []).allowed)
    XCTAssertTrue(StartStopActionResolver.canStop(with: .tag(typedEvent), conditions: .init(nfc: .specific), sessionTag: nil, stopNFCTagIds: ["nfc:opaque:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"], stopQRCodeIds: []).allowed)
    let activity = IdentityNFCActivity(activityType: NSUserActivityTypeBrowsingWeb)
    activity.webpageURL = URL(string: appURL)!
    activity.message = NFCNDEFMessage(records: [NFCNDEFPayload.wellKnownTypeURIPayload(url: activity.webpageURL!)!])
    guard case .tag(let background) = try ProfileTagLink.classify(activity) else { return XCTFail("Expected verified NFC route") }
    XCTAssertFalse(StartStopActionResolver.canStop(with: .tag(background), conditions: .init(nfc: .specific), sessionTag: nil, stopNFCTagIds: [appURL], stopQRCodeIds: []).allowed)
    XCTAssertThrowsError(try nfc(uid, url: "https://family-foqos.app/profile/bad", now: now))
  }

}

@MainActor
private final class IdentityNFCScanner: NFCScannerUtil {
  override func scan(profileName: String) {}
}

private final class IdentityNFCActivity: NSUserActivity {
  var message = NFCNDEFMessage(records: [])
  override var ndefMessagePayload: NFCNDEFMessage { message }
}
