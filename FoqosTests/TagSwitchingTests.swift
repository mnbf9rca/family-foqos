import CoreImage
import CoreNFC
import FoqosShared
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class TagSwitchingTests: XCTestCase {
  private var container: ModelContainer!
  private var context: ModelContext { container.mainContext }
  private var manager: StrategyManager!
  private var suite: String!
  private var applier: RecordingRestrictionApplier!
  private var registrations = 0
  private var cancelled: [String] = []
  private var failRegistration = false
  private var failSave = false
  private var syncWasEnabled = false
  private let aKey = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  private let bKey = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  private let cKey = "cccccccccccccccccccccccccccccccc"

  override func setUp() async throws {
    suite = "TagSwitchingTests-\(UUID())"
    SharedData.configure(suite: UserDefaults(suiteName: suite)!)
    container = try TestModelContainer.create()
    syncWasEnabled = ProfileSyncManager.shared.isEnabled
    ProfileSyncManager.shared.isEnabled = false
    applier = RecordingRestrictionApplier()
    manager = StrategyManager(
      appBlocker: applier,
      registerTimer: { _, _, minutes, now in
        self.registrations += 1
        if self.failRegistration { throw NSError(domain: "registrar", code: 1) }
        return now.addingTimeInterval(Double(minutes) * 60)
      }, cancelTimer: { _, id in self.cancelled.append(id) }, startSessionActivity: { _ in },
      cancelPreActivationReminders: { _ in },
      saveSession: { context in
        if self.failSave {
          self.failSave = false
          throw NSError(domain: "save", code: 1)
        }
        try context.save()
      }, scheduleReconciler: { _ in })
  }

  override func tearDown() async throws {
    manager.stopTimer()
    ProfileSyncManager.shared.isEnabled = syncWasEnabled
    UserDefaults().removePersistentDomain(forName: suite)
  }

  private func profile(_ name: String, type: TagType, stop: TagStopKind = .any, now: Date) throws -> BlockedProfiles {
    let p = BlockedProfiles(name: name, createdAt: now, updatedAt: now)
    p.startTriggers = type == .nfc ? .init(anyNFC: true) : .init(anyQR: true)
    p.stopConditions = type == .nfc ? .init(manual: true, nfc: stop) : .init(manual: true, qr: stop)
    context.insert(p)
    try context.save()
    return p
  }

  private func event(_ type: TagType, key: String, target: UUID? = nil) -> TagEvent {
    TagEvent(type: type, namespace: .opaque, key: key, targetProfileId: target)
  }

  private func classifiedActivity(_ type: TagType, key: String, target: UUID) throws -> ProfileTagLink.Delivery {
    let activity = SwitchActivity(activityType: NSUserActivityTypeBrowsingWeb)
    activity.webpageURL = ProfileTagLink.make(profileId: target, type: type, key: key)
    if type == .nfc {
      activity.message = NFCNDEFMessage(records: [NFCNDEFPayload.wellKnownTypeURIPayload(url: activity.webpageURL!)!])
    } else {
      activity.barcode = CIQRCodeDescriptor(payload: Data([1]), symbolVersion: 1, maskPattern: 0, errorCorrectionLevel: .levelL)
    }
    return try ProfileTagLink.classify(activity)
  }

  private func active(_ p: BlockedProfiles, type: TagType, now: Date) throws -> BlockedProfileSession {
    try manager.startOriginatingSession(context: context, profile: p, origin: event(type, key: aKey).origin, now: now)
  }

  private func retire(_ session: BlockedProfileSession, now: Date) {
    session.endSession(now: now)
    manager.activeSession = nil
    manager.stopTimer()
    manager.cancelTagOperation()
    manager.errorMessage = nil
    applier.clearForAssertion()
  }

  func testBothRoutesUseTargetedAdmissionOR() async throws {
    let now = Date()
    for type in [TagType.nfc, .qr] {
      for link in [false, true] {
        let p = try profile("B", type: type, now: now)
        p.startTriggers = type == .nfc ? .init(specificNFC: true, deepLink: link) : .init(specificQR: true, deepLink: link)
        p.startNFCTagIds = ["nfc:opaque:\(bKey)"]
        p.startQRCodeIds = ["qr:opaque:\(bKey)"]
        try context.save()
        let scan = event(type, key: bKey, target: p.id)
        for background in [false, true] {
          if background {
            let activity = SwitchActivity(activityType: NSUserActivityTypeBrowsingWeb)
            activity.webpageURL = ProfileTagLink.make(profileId: p.id, type: type, key: bKey)
            if type == .nfc { activity.message = NFCNDEFMessage(records: [NFCNDEFPayload.wellKnownTypeURIPayload(url: activity.webpageURL!)!]) } else { activity.barcode = CIQRCodeDescriptor(payload: Data([1]), symbolVersion: 1, maskPattern: 0, errorCorrectionLevel: .levelL) }
            await manager.handleDelivery(try ProfileTagLink.classify(activity), context: context, now: now)
          } else {
            await manager.handleTagEvent(scan, operation: .scan, context: context, now: now)
          }
          let session = try XCTUnwrap(manager.activeSession)
          XCTAssertEqual(session.blockedProfile.id, p.id)
          XCTAssertEqual(session.origin, scan.origin)
          retire(session, now: now)
        }
        await manager.handleTagEvent(event(type, key: cKey, target: p.id), operation: .scan, context: context, now: now)
        if link { retire(try XCTUnwrap(manager.activeSession), now: now) } else { XCTAssertNil(manager.activeSession) }
        let unidentified = TagEvent(type: type, namespace: nil, key: nil, targetProfileId: p.id, unidentifiedLegacyTag: true)
        await manager.handleTagEvent(unidentified, operation: .scan, context: context, now: now)
        if link { retire(try XCTUnwrap(manager.activeSession), now: now) } else { XCTAssertNil(manager.activeSession) }
      }
      let plain = try profile("Converted", type: type, stop: .same, now: now)
      var stops = plain.stopConditions
      stops.manual = false
      plain.stopConditions = stops
      await manager.handleTagEvent(TagEvent(type: type, namespace: nil, key: nil, targetProfileId: plain.id, unidentifiedLegacyTag: true), operation: .scan, context: context, now: now)
      XCTAssertTrue(manager.activeSession?.origin?.unidentifiedLegacyTag == true)
      retire(try XCTUnwrap(manager.activeSession), now: now)
      await manager.handleDelivery(.link(profileId: plain.id), context: context, now: now)
      XCTAssertNil(manager.activeSession)
    }
  }

  func testExplicitStartIgnoresEmbeddedTargetAndNeverFallsBack() async throws {
    let now = Date()
    for type in [TagType.nfc, .qr] {
      let p = try profile("P", type: type, now: now)
      let b = try profile("B", type: type, now: now)
      p.startTriggers = type == .nfc ? .init(specificNFC: true, deepLink: true) : .init(specificQR: true, deepLink: true)
      p.startNFCTagIds = ["nfc:opaque:\(aKey)"]
      p.startQRCodeIds = ["qr:opaque:\(aKey)"]
      try context.save()
      await manager.handleTagEvent(event(type, key: bKey, target: b.id), operation: .explicitStart(p.id), context: context, now: now)
      XCTAssertNil(manager.activeSession)
      await manager.handleTagEvent(event(type, key: aKey, target: b.id), operation: .explicitStart(p.id), context: context, now: now)
      XCTAssertEqual(manager.activeSession?.blockedProfile.id, p.id)
      retire(try XCTUnwrap(manager.activeSession), now: now)
    }
  }

  func testR10SwitchMatrixSameForInAppAndBackground() async throws {
    let now = Date()
    for type in [TagType.nfc, .qr] {
      for kind in [TagStopKind.any, .specific, .same, .none] {
        let a = try profile("A", type: type, stop: kind, now: now)
        a.stopNFCTagIds = ["nfc:opaque:\(aKey)"]
        a.stopQRCodeIds = ["qr:opaque:\(aKey)"]
        let b = try profile("B", type: type, now: now)
        for background in [false, true] {
          let victim = try active(a, type: type, now: now)
          applier.clearForAssertion()
          if background {
            await manager.handleDelivery(try classifiedActivity(type, key: bKey, target: b.id), context: context, now: now)
          } else {
            await manager.handleTagEvent(event(type, key: bKey, target: b.id), operation: .scan, context: context, now: now)
          }
          if kind == .any {
            XCTAssertFalse(victim.isActive)
            XCTAssertEqual(manager.activeSession?.blockedProfile.id, b.id)
            XCTAssertEqual(applier.calls, [.activate(profileId: b.id)])
            retire(try XCTUnwrap(manager.activeSession), now: now)
          } else {
            XCTAssertTrue(victim.isActive)
            XCTAssertTrue(applier.calls.isEmpty)
            if kind == .none {
              XCTAssertNil(manager.pendingTagSwitch)
              XCTAssertEqual(manager.errorMessage, "A can’t stop with this tag or code. Stop it another way before starting B.")
            } else {
              XCTAssertNotNil(manager.pendingTagSwitch)
              await manager.handleTagEvent(event(type, key: aKey), operation: .confirmSwitch, context: context, now: now)
              XCTAssertEqual(manager.activeSession?.blockedProfile.id, b.id)
              XCTAssertFalse(victim.isActive)
            }
            retire(try XCTUnwrap(manager.activeSession), now: now)
          }
        }
      }
    }
  }

  func testRequiredConfirmationPreservesBAndOriginalBOrigin() async throws {
    let now = Date()
    let a = try profile("A", type: .nfc, stop: .same, now: now)
    let b = try profile("B", type: .nfc, now: now)
    let c = try profile("C", type: .nfc, now: now)
    let victim = try active(a, type: .nfc, now: now)
    let original = event(.nfc, key: bKey, target: b.id)
    await manager.handleTagEvent(original, operation: .scan, context: context, now: now)
    XCTAssertEqual(manager.pendingTagSwitch?.targetProfileId, b.id)
    XCTAssertEqual(manager.pendingTagSwitch?.event, original)
    await manager.handleTagEvent(event(.nfc, key: cKey, target: c.id), operation: .confirmSwitch, context: context, now: now)
    XCTAssertTrue(victim.isActive)
    XCTAssertNotNil(manager.pendingTagSwitch)
    await manager.handleTagEvent(event(.nfc, key: aKey, target: c.id), operation: .confirmSwitch, context: context, now: now)
    XCTAssertFalse(victim.isActive)
    XCTAssertEqual(manager.activeSession?.blockedProfile.id, b.id)
    XCTAssertEqual(manager.activeSession?.origin, original.origin)
    XCTAssertNil(manager.pendingTagSwitch)
  }

  func testFailedBRegistrationSaveAndChangedSettingsLeaveAIntact() async throws {
    let now = Date()
    for failure in ["timer", "save", "disabled", "invalid", "selection", "cancel"] {
      let a = try profile("A", type: .qr, stop: .same, now: now)
      let b = try profile("B", type: .qr, now: now)
      b.stopConditions = .init(manual: true, timer: true, timerDurationMinutes: 37)
      let victim = try active(a, type: .qr, now: now)
      let before = registrations
      await manager.handleTagEvent(event(.qr, key: bKey, target: b.id), operation: .scan, context: context, now: now)
      switch failure {
      case "timer": failRegistration = true
      case "save": failSave = true
      case "disabled": b.startTriggers = .init(manual: true)
      case "invalid": b.stopConditions = .init(deepLink: true)
      case "selection": b.needsAppSelection = true
      default: manager.cancelTagOperation()
      }
      await manager.handleTagEvent(event(.qr, key: aKey), operation: .confirmSwitch, context: context, now: now)
      XCTAssertTrue(victim.isActive, failure)
      XCTAssertEqual(manager.activeSession?.id, victim.id, failure)
      XCTAssertEqual(SharedData.getActiveSharedSession()?.id, victim.id, failure)
      XCTAssertTrue(b.sessions.isEmpty, failure)
      if failure == "timer" || failure == "save" {
        XCTAssertEqual(registrations, before + 1)
        XCTAssertFalse(cancelled.contains(victim.id))
      } else {
        XCTAssertEqual(registrations, before)
      }
      XCTAssertNil(manager.pendingTagSwitch)
      failRegistration = false
      failSave = false
      retire(victim, now: now)
    }
  }

  func testTargetActiveAIsStopOnlyAndOrdinaryLinksNeverSwitch() async throws {
    let now = Date()
    for type in [TagType.nfc, .qr] {
      for kind in [TagStopKind.any, .specific, .same, .none] {
        let a = try profile("A", type: type, stop: kind, now: now)
        a.stopNFCTagIds = ["nfc:opaque:\(aKey)"]
        a.stopQRCodeIds = ["qr:opaque:\(aKey)"]
        let victim = try active(a, type: type, now: now)
        // Stop admission is independent of newly disabled/invalid starts.
        a.startTriggers = .init()
        let before = registrations
        await manager.handleDelivery(.link(profileId: a.id), context: context, now: now)
        XCTAssertTrue(victim.isActive)
        XCTAssertNil(manager.errorMessage)
        await manager.handleTagEvent(event(type, key: aKey, target: a.id), operation: .scan, context: context, now: now)
        XCTAssertEqual(registrations, before)
        if kind == .none {
          XCTAssertTrue(victim.isActive)
          retire(victim, now: now)
        } else {
          XCTAssertFalse(victim.isActive)
          XCTAssertNil(manager.activeSession)
          XCTAssertNil(SharedData.getActiveSharedSession())
        }
      }
    }
  }

  func testOwnTagWrongKeyPromptsWithoutReplacementAndKeepsStopOnlyTarget() async throws {
    let now = Date()
    for type in [TagType.nfc, .qr] {
      let a = try profile("A", type: type, stop: .same, now: now)
      let victim = try active(a, type: type, now: now)
      let before = registrations
      await manager.handleDelivery(try classifiedActivity(type, key: bKey, target: a.id), context: context, now: now)
      XCTAssertTrue(manager.showTagConfirmation)
      XCTAssertNil(manager.pendingTagSwitch?.targetProfileId)
      await manager.handleTagEvent(event(type, key: cKey), operation: .confirmSwitch, context: context, now: now)
      XCTAssertTrue(victim.isActive)
      XCTAssertEqual(manager.tagScanError, type == .nfc ? "That NFC tag doesn’t match. Scan the required tag." : "That QR code doesn’t match. Scan the required code.")
      await manager.handleTagEvent(event(type, key: aKey), operation: .confirmSwitch, context: context, now: now)
      XCTAssertFalse(victim.isActive)
      XCTAssertNil(manager.activeSession)
      XCTAssertEqual(registrations, before)
    }
  }

  func testIneligibleBRefusesBeforePromisingConfirmation() async throws {
    let now = Date()
    for failure in ["disabled", "invalid", "selection"] {
      let a = try profile("A", type: .qr, stop: .same, now: now)
      let b = try profile("B", type: .qr, now: now)
      let victim = try active(a, type: .qr, now: now)
      switch failure {
      case "disabled": b.startTriggers = .init(manual: true)
      case "invalid": b.stopConditions = .init(deepLink: true)
      default: b.needsAppSelection = true
      }
      let before = registrations
      await manager.handleDelivery(try classifiedActivity(.qr, key: bKey, target: b.id), context: context, now: now)
      XCTAssertNil(manager.pendingTagSwitch, failure)
      XCTAssertFalse(manager.showTagConfirmation, failure)
      XCTAssertNotNil(manager.errorMessage, failure)
      XCTAssertEqual(manager.activeSession?.id, victim.id)
      XCTAssertTrue(victim.isActive)
      XCTAssertEqual(registrations, before)
      retire(victim, now: now)
    }
  }

  func testVerifiedBackgroundTagsPreserveGenuineV1LinkLifecycle() async throws {
    let now = Date()
    for type in [TagType.nfc, .qr] {
      for flag in [false, true] {
        for hasStaleV2Blob in [false, true] {
          let p = try profile("V1", type: type, now: now)
          p.profileSchemaVersion = 1
          p.blockingStrategyId = ManualBlockingStrategy.id
          p.disableBackgroundStops = flag
          p.startTriggersData = nil
          p.stopConditionsData = hasStaleV2Blob ? try JSONEncoder().encode(ProfileStopConditions()) : nil
          let victim = BlockedProfileSession(tag: "manual", blockedProfile: p, startTime: now)
          context.insert(victim)
          try context.save()
          manager.activeSession = victim
          BlockedProfiles.updateSnapshot(for: p)
          SharedData.createActiveSharedSession(for: victim.toSnapshot())
          await manager.handleDelivery(try classifiedActivity(type, key: bKey, target: p.id), context: context, now: now)
          let refused = flag
          XCTAssertEqual(victim.isActive, refused)
          if refused {
            XCTAssertNotNil(manager.errorMessage)
            retire(victim, now: now)
          }
          XCTAssertEqual(registrations, 0)
        }
      }
    }
  }

  func testReplacedAAndTargetlessScansDoNotActivateB() async throws {
    let now = Date()
    let a = try profile("A", type: .nfc, stop: .same, now: now)
    let b = try profile("B", type: .nfc, now: now)
    let victim = try active(a, type: .nfc, now: now)
    await manager.handleTagEvent(event(.nfc, key: bKey, target: b.id), operation: .scan, context: context, now: now)
    victim.endSession(now: now)
    manager.activeSession = nil
    let replacement = try active(a, type: .nfc, now: now.addingTimeInterval(1))
    await manager.handleTagEvent(event(.nfc, key: aKey), operation: .confirmSwitch, context: context, now: now)
    XCTAssertEqual(manager.activeSession?.id, replacement.id)
    XCTAssertTrue(replacement.isActive)
    XCTAssertTrue(b.sessions.isEmpty)
    XCTAssertNil(manager.pendingTagSwitch)
    await manager.handleTagEvent(event(.nfc, key: aKey), operation: .scan, context: context, now: now)
    XCTAssertNil(manager.activeSession)
    XCTAssertTrue(b.sessions.isEmpty)
  }

  func testStaleGeofenceReplyNewRequestAndSceneCancellationKeepWinner() async throws {
    let now = Date()
    let geofence = SuspendedTagGeofence()
    let sut = StrategyManager(
      geofenceEvaluator: geofence, appBlocker: applier,
      registerTimer: { _, _, _, _ in
        XCTFail("Cancelled transition registered a timer")
        return now
      },
      cancelTimer: { _, _ in }, startSessionActivity: { _ in }, cancelPreActivationReminders: { _ in }, scheduleReconciler: { _ in })
    defer { sut.stopTimer() }
    let a = try profile("A", type: .nfc, now: now)
    let b = try profile("B", type: .nfc, now: now)
    for action in ["cancel", "new request", "replacement"] {
      let victim = try sut.startOriginatingSession(context: context, profile: a, origin: event(.nfc, key: aKey).origin, now: now)
      let entered = expectation(description: "geofence suspended")
      geofence.entered = { entered.fulfill() }
      let operation = Task { await sut.handleTagEvent(event(.nfc, key: bKey, target: b.id), operation: .scan, context: context, now: now) }
      await fulfillment(of: [entered], timeout: 3)
      var winner: BlockedProfileSession?
      switch action {
      case "replacement":
        victim.endSession(now: now)
        sut.activeSession = nil
        winner = try sut.startOriginatingSession(context: context, profile: a, origin: event(.nfc, key: cKey).origin, now: now.addingTimeInterval(1))
      case "new request":
        await sut.handleDelivery(.link(profileId: b.id), context: context, now: now)
      default: sut.cancelTagOperation()
      }
      geofence.resume()
      await operation.value
      XCTAssertEqual(sut.activeSession?.id, winner?.id ?? victim.id)
      XCTAssertTrue(b.sessions.isEmpty)
      XCTAssertNil(sut.pendingTagSwitch)
      (winner ?? victim).endSession(now: now)
      sut.activeSession = nil
    }
  }

  func testRegistrationOwnershipRaceCompensatesOnlyB() async throws {
    let now = Date()
    let a = try profile("A", type: .nfc, now: now)
    let b = try profile("B", type: .nfc, now: now)
    b.stopConditions = .init(timer: true, timerDurationMinutes: 37)
    let victim = try active(a, type: .nfc, now: now)
    var winner: BlockedProfileSession?
    var cancelledIds: [String] = []
    var sut: StrategyManager!
    sut = StrategyManager(
      appBlocker: applier,
      registerTimer: { _, _, _, _ in
        let replacement = BlockedProfileSession(tag: "manual", blockedProfile: a, startTime: now.addingTimeInterval(1), id: UUID().uuidString, origin: .init(kind: .manual))
        self.context.insert(replacement)
        winner = replacement
        SharedData.createActiveSharedSession(for: replacement.toSnapshot())
        sut.activeSession = replacement
        return now.addingTimeInterval(2220)
      }, cancelTimer: { _, id in cancelledIds.append(id) }, startSessionActivity: { _ in }, cancelPreActivationReminders: { _ in }, scheduleReconciler: { _ in })
    defer { sut.stopTimer() }
    sut.activeSession = victim
    applier.clearForAssertion()
    await sut.handleTagEvent(event(.nfc, key: bKey, target: b.id), operation: .scan, context: context, now: now)
    XCTAssertEqual(sut.activeSession?.id, try XCTUnwrap(winner).id)
    XCTAssertEqual(SharedData.getActiveSharedSession()?.id, try XCTUnwrap(winner).id)
    XCTAssertTrue(victim.isActive)
    XCTAssertTrue(b.sessions.isEmpty)
    XCTAssertEqual(cancelledIds.count, 1)
    XCTAssertFalse(cancelledIds.contains(victim.id))
    XCTAssertTrue(applier.calls.isEmpty)
  }

  func testOriginAwareSameNamespacesAndMirrors() throws {
    let events = [event(.nfc, key: aKey), event(.qr, key: aKey)]
    for scan in events {
      let conditions: ProfileStopConditions = scan.type == .nfc ? .init(sameNFC: true) : .init(sameQR: true)
      let canStop: (TagEvent, SessionOrigin?) -> Bool = { event, origin in
        StartStopActionResolver.canStop(
          with: .tag(event), conditions: conditions, sessionTag: nil,
          stopNFCTagIds: [], stopQRCodeIds: [], sessionOrigin: origin
        ).allowed
      }
      XCTAssertTrue(canStop(scan, scan.origin))
      let raw = TagEvent(type: scan.type, namespace: scan.type == .nfc ? .nfcUID : .qrDigest, key: aKey)
      XCTAssertFalse(canStop(raw, scan.origin))
      XCTAssertFalse(canStop(scan, raw.origin))
      XCTAssertFalse(canStop(scan, nil))
      XCTAssertFalse(canStop(scan, .init(kind: .link)))
      let legacy = SessionOrigin(kind: scan.type == .nfc ? .nfc : .qr, unidentifiedLegacyTag: true)
      XCTAssertTrue(canStop(scan, legacy))
      XCTAssertFalse(canStop(TagEvent(type: scan.type == .nfc ? .qr : .nfc, namespace: .opaque, key: aKey), legacy))
      XCTAssertEqual(try JSONDecoder().decode(SessionOrigin.self, from: JSONEncoder().encode(legacy)), legacy)
    }
  }

  func testColdQueueDispatchesOneActualTransitionAfterReadiness() async throws {
    let now = Date()
    let b = try profile("B", type: .nfc, now: now)
    let navigation = NavigationManager()
    let scene = SceneDelegate(navigation: navigation)
    let activity = SwitchActivity(activityType: NSUserActivityTypeBrowsingWeb)
    activity.webpageURL = ProfileTagLink.make(profileId: b.id, type: .nfc, key: bKey)
    activity.message = NFCNDEFMessage(records: [NFCNDEFPayload.wellKnownTypeURIPayload(url: activity.webpageURL!)!])
    scene.receiveConnection(activities: [activity], urls: [])
    navigation.receiveSwiftUI(activity)
    navigation.receiveSwiftUI(activity.webpageURL!)
    await navigation.dispatchQueued(using: manager, context: context, ready: false, now: now)
    XCTAssertNil(manager.activeSession)
    XCTAssertEqual(navigation.deliveries.count, 1)
    await navigation.dispatchQueued(using: manager, context: context, ready: true, now: now)
    XCTAssertEqual(manager.activeSession?.blockedProfile.id, b.id)
    XCTAssertEqual(b.sessions.count, 1)
    XCTAssertTrue(navigation.deliveries.isEmpty)
    scene.receiveActivity(activity)
    await navigation.dispatchQueued(using: manager, context: context, ready: true, now: now)
    XCTAssertTrue(manager.activeSession?.isActive == true)
    XCTAssertEqual(b.sessions.count, 1)
  }
}

private final class SwitchActivity: NSUserActivity {
  var message = NFCNDEFMessage(records: [])
  var barcode: CIBarcodeDescriptor?
  override var ndefMessagePayload: NFCNDEFMessage { message }
  override var detectedBarcodeDescriptor: CIBarcodeDescriptor? { barcode }
}

@MainActor
private final class SuspendedTagGeofence: GeofenceEvaluator {
  var entered: (() -> Void)?
  private var continuation: CheckedContinuation<Void, Never>?
  override func evaluateGeofenceForStop(profile: BlockedProfiles, context: ModelContext) async -> GeofenceCheckResult? {
    await withCheckedContinuation { continuation in
      self.continuation = continuation
      entered?()
    }
    return nil
  }
  func resume() {
    continuation?.resume()
    continuation = nil
  }
}
