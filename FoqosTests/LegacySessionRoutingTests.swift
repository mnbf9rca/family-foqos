import FoqosShared
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class LegacySessionRoutingTests: XCTestCase {
  private var container: ModelContainer!
  private var context: ModelContext { container.mainContext }
  private var manager: StrategyManager!
  private var suite: String!
  private var syncWasEnabled = false

  override func setUp() async throws {
    suite = "LegacySessionRoutingTests-\(UUID())"
    SharedData.configure(suite: UserDefaults(suiteName: suite)!)
    container = try TestModelContainer.create()
    syncWasEnabled = ProfileSyncManager.shared.isEnabled
    ProfileSyncManager.shared.isEnabled = false
    manager = StrategyManager(startSessionActivity: { _ in }, cancelPreActivationReminders: { _ in }, scheduleReconciler: { _ in })
  }

  override func tearDown() async throws {
    manager.stopTimer()
    ProfileSyncManager.shared.isEnabled = syncWasEnabled
    UserDefaults().removePersistentDomain(forName: suite)
  }

  private func legacyProfile(_ strategy: String, now: Date) throws -> BlockedProfiles {
    let profile = BlockedProfiles(name: "Legacy", createdAt: now, updatedAt: now)
    profile.profileSchemaVersion = 1
    profile.blockingStrategyId = strategy
    context.insert(profile)
    try context.save()
    XCTAssertNil(profile.startTriggersData)
    XCTAssertNil(profile.stopConditionsData)
    return profile
  }

  private func active(_ profile: BlockedProfiles, tag: String, now: Date, force: Bool = false) throws -> BlockedProfileSession {
    let session = BlockedProfileSession(tag: tag, blockedProfile: profile, forceStarted: force, startTime: now)
    context.insert(session)
    try context.save()
    manager.activeSession = session
    BlockedProfiles.updateSnapshot(for: profile)
    SharedData.createActiveSharedSession(for: session.toSnapshot())
    return session
  }

  func testManualTapStopsDeferredV1AndPersistsMigration() throws {
    let now = Date()
    let profile = try legacyProfile(ManualBlockingStrategy.id, now: now)
    let session = try active(profile, tag: ManualBlockingStrategy.id, now: now)
    XCTAssertFalse(try ProfileMigrationUtil.migrate(profile, hasActiveSession: true))
    manager.toggleBlocking(context: context, activeProfile: profile)
    XCTAssertFalse(session.isActive)
    XCTAssertNil(SharedData.getActiveSharedSession())
    XCTAssertEqual(profile.profileSchemaVersion, 3)
    XCTAssertTrue(profile.stopConditions.manual)
    let reloaded = try XCTUnwrap(BlockedProfiles.findProfile(byID: profile.id, in: ModelContext(container)))
    XCTAssertEqual(reloaded.profileSchemaVersion, 3)
  }

  func testNFCTapKeepsV1SessionRunningUntilLegacyScannerAcceptsTag() throws {
    let now = Date()
    for strategy in [NFCBlockingStrategy.id, NFCManualBlockingStrategy.id, NFCTimerBlockingStrategy.id] {
      let profile = try legacyProfile(strategy, now: now)
      profile.physicalUnblockNFCTagId = "required"
      let session = try active(profile, tag: "nfc:original", now: now)
      manager.toggleBlocking(context: context, activeProfile: profile)
      XCTAssertTrue(session.isActive, strategy)
      XCTAssertEqual(profile.profileSchemaVersion, 1, strategy)
      XCTAssertEqual(profile.physicalUnblockNFCTagId, "required", strategy)
      session.endSession(now: now)
      manager.activeSession = nil
    }
  }

  func testQRTapUsesV1SamePhysicalAndForceStartedRulesThenMigrates() throws {
    let now = Date()
    for strategy in [QRCodeBlockingStrategy.id, QRManualBlockingStrategy.id, QRTimerBlockingStrategy.id] {
      for force in [false, true] {
        for physical in [false, true] {
          let profile = try legacyProfile(strategy, now: now)
          profile.physicalUnblockQRCodeId = physical ? "physical" : nil
          let session = try active(profile, tag: "qr:original", now: now, force: force)
          manager.toggleBlocking(context: context, activeProfile: profile)
          XCTAssertTrue(session.isActive)
          XCTAssertEqual(profile.profileSchemaVersion, 1)
          let scanner = try XCTUnwrap(manager.customStrategyView as? LabeledCodeScannerView)
          let acceptsAny = !physical && (force || strategy != QRCodeBlockingStrategy.id)
          scanner.onScanResult(.success(QRScanResult(hash: "other", rawHash: "other-raw")))
          XCTAssertEqual(session.isActive, !acceptsAny)
          if !acceptsAny {
            XCTAssertEqual(profile.profileSchemaVersion, 1)
            scanner.onScanResult(.success(QRScanResult(hash: "normalized", rawHash: physical ? "physical" : "original")))
          }
          XCTAssertFalse(session.isActive)
          XCTAssertEqual(profile.profileSchemaVersion, 3)
          XCTAssertNil(SharedData.getActiveSharedSession())
        }
      }
    }
  }

  func testV1ShortcutsStopUsesLegacySafeguardWithoutV2Flags() async throws {
    let now = Date()
    for strategy in [ManualBlockingStrategy.id, NFCBlockingStrategy.id, QRCodeBlockingStrategy.id] {
      for disabled in [false, true] {
        let profile = try legacyProfile(strategy, now: now)
        profile.disableBackgroundStops = disabled
        let session = try active(profile, tag: "nfc:original", now: now)
        do {
          try await manager.stopSessionFromBackground(profile.id, context: context)
          XCTAssertFalse(disabled)
          XCTAssertFalse(session.isActive)
          XCTAssertEqual(profile.profileSchemaVersion, 3)
        } catch {
          XCTAssertTrue(disabled, "Unexpected refusal: \(error)")
          guard case IntentError.backgroundStopsDisabled = error else { return XCTFail("Unexpected error: \(error)") }
          XCTAssertTrue(session.isActive)
          XCTAssertEqual(profile.profileSchemaVersion, 1)
          session.endSession(now: now)
          manager.activeSession = nil
        }
      }
    }
  }

  func testV1PlainLinkStopsWithoutV2FlagsAndHonorsSafeguard() async throws {
    let now = Date()
    for disabled in [false, true] {
      let profile = try legacyProfile(NFCBlockingStrategy.id, now: now)
      profile.disableBackgroundStops = disabled
      let session = try active(profile, tag: "nfc:original", now: now)
      await manager.handleDelivery(.link(profileId: profile.id), context: context, now: now)
      XCTAssertEqual(session.isActive, disabled)
      XCTAssertEqual(profile.profileSchemaVersion, disabled ? 1 : 3)
      if disabled {
        session.endSession(now: now)
        manager.activeSession = nil
      }
    }
  }

  func testColdV1LinkAndShortcutStartsConvertBeforeV2Admission() async throws {
    let now = Date()
    for shortcut in [false, true] {
      for strategy in [ManualBlockingStrategy.id, NFCBlockingStrategy.id] {
        let profile = try legacyProfile(strategy, now: now)
        if shortcut {
          do {
            _ = try manager.startSessionFromBackground(profile.id, context: context, authorization: MockAuthorizationRequesting(initialStatus: .approved))
          } catch {
            XCTAssertEqual(strategy, NFCBlockingStrategy.id, "Manual conversion should start: \(error)")
          }
        } else {
          await manager.handleDelivery(.link(profileId: profile.id), context: context, now: now)
        }
        XCTAssertEqual(profile.profileSchemaVersion, 3)
        if strategy == ManualBlockingStrategy.id {
          let session = try XCTUnwrap(manager.activeSession, manager.errorMessage ?? "No session")
          XCTAssertEqual(session.blockedProfile.id, profile.id)
          XCTAssertFalse(session.forceStarted)
          XCTAssertEqual(session.origin?.kind, shortcut ? .shortcut : .link)
          session.endSession(now: now)
          manager.activeSession = nil
        } else {
          XCTAssertNil(manager.activeSession)
          XCTAssertNotNil(manager.errorMessage)
        }
      }
    }
  }

  func testColdV1ExplicitTagStartConvertsAndRetainsScannedOrigin() async throws {
    let now = Date()
    let profile = try legacyProfile(QRCodeBlockingStrategy.id, now: now)
    await manager.handleTagEvent(TagEvent(type: .qr, namespace: .qrDigest, key: "start"), operation: .explicitStart(profile.id), context: context, now: now)
    let session = try XCTUnwrap(manager.activeSession, manager.errorMessage ?? "No session")
    XCTAssertEqual(profile.profileSchemaVersion, 3)
    XCTAssertEqual(session.origin?.key, "start")
    XCTAssertFalse(session.forceStarted)
  }
  func testV1BreakKeepsProfileDeferredUntilManualSessionEnds() throws {
    let now = Date()
    let profile = try legacyProfile(ManualBlockingStrategy.id, now: now)
    profile.enableBreaks = true
    profile.breakTimeInMinutes = 5
    manager = StrategyManager(backstopRegistrar: RecordingBackstopRegistrar())
    let session = try active(profile, tag: ManualBlockingStrategy.id, now: now)
    manager.toggleBreak(context: context)
    XCTAssertTrue(session.isBreakActive)
    XCTAssertEqual(profile.profileSchemaVersion, 1)
    manager.toggleBreak(context: context)
    XCTAssertFalse(session.isBreakActive)
    XCTAssertTrue(session.isActive)
    XCTAssertEqual(profile.profileSchemaVersion, 1)
    manager.toggleBlocking(context: context, activeProfile: profile)
    XCTAssertFalse(session.isActive)
    XCTAssertEqual(profile.profileSchemaVersion, 3)
  }

  func testV1EmergencyUnblockEndsAndMigrates() async throws {
    let now = Date()
    let profile = try legacyProfile(NFCBlockingStrategy.id, now: now)
    let emergency = EmergencyUnblockManager(defaults: UserDefaults(suiteName: suite)!)
    manager = StrategyManager(emergencyUnblockManager: emergency)
    let session = try active(profile, tag: "nfc:original", now: now)
    let before = emergency.getRemainingEmergencyUnblocks()
    try await manager.emergencyUnblock(context: context)
    XCTAssertFalse(session.isActive)
    XCTAssertEqual(profile.profileSchemaVersion, 3)
    XCTAssertEqual(emergency.getRemainingEmergencyUnblocks(), before - 1)
  }

  func testV1TimerEndConvertsOnForeground() throws {
    let now = Date()
    let profile = try legacyProfile(NFCTimerBlockingStrategy.id, now: now)
    profile.strategyData = StrategyTimerData.toData(from: .init(durationInMinutes: 30))
    let session = try active(profile, tag: NFCTimerBlockingStrategy.id, now: now.addingTimeInterval(-1800))
    StrategyTimerActivity(applier: RecordingRestrictionApplier()).stop(for: BlockedProfiles.getSnapshot(for: profile))
    XCTAssertNil(SharedData.getActiveSharedSession())
    XCTAssertEqual(profile.profileSchemaVersion, 1)
    try manager.loadActiveSession(context: context)
    XCTAssertFalse(session.isActive)
    XCTAssertNil(manager.activeSession)
    XCTAssertEqual(profile.profileSchemaVersion, 3)
    XCTAssertEqual(profile.stopConditions.timerDurationMinutes, 30)
  }

  func testActiveV1ProfileCannotBeConvertedByAnotherStart() throws {
    let now = Date()
    let profile = try legacyProfile(ManualBlockingStrategy.id, now: now)
    let session = try active(profile, tag: ManualBlockingStrategy.id, now: now)
    XCTAssertThrowsError(try manager.startOriginatingSession(context: context, profile: profile, origin: .init(kind: .manual), now: now))
    XCTAssertTrue(session.isActive)
    XCTAssertEqual(profile.profileSchemaVersion, 1)
    XCTAssertNil(profile.stopConditionsData)
    XCTAssertEqual(SharedData.getActiveSharedSession()?.id, session.id)
  }

  func testV1LinkSwitchConvertsTargetBeforeEndingVictim() async throws {
    let now = Date()
    for targetStrategy in [ManualBlockingStrategy.id, NFCBlockingStrategy.id] {
      let victimProfile = try legacyProfile(ManualBlockingStrategy.id, now: now)
      let target = try legacyProfile(targetStrategy, now: now)
      let victim = try active(victimProfile, tag: ManualBlockingStrategy.id, now: now)
      await manager.handleDelivery(.link(profileId: target.id), context: context, now: now)
      XCTAssertEqual(target.profileSchemaVersion, 3)
      if targetStrategy == ManualBlockingStrategy.id {
        XCTAssertFalse(victim.isActive)
        XCTAssertEqual(victimProfile.profileSchemaVersion, 3)
        let replacement = try XCTUnwrap(manager.activeSession)
        XCTAssertEqual(replacement.blockedProfile.id, target.id)
        XCTAssertEqual(replacement.origin?.kind, .link)
        replacement.endSession(now: now)
      } else {
        XCTAssertTrue(victim.isActive)
        XCTAssertEqual(victimProfile.profileSchemaVersion, 1)
        XCTAssertEqual(SharedData.getActiveSharedSession()?.id, victim.id)
        victim.endSession(now: now)
      }
      manager.activeSession = nil
    }
  }

  func testNFCStrategiesKeepSamePhysicalAndForceRulesThroughMigrationCallback() throws {
    let now = Date()
    for strategyID in [NFCBlockingStrategy.id, NFCManualBlockingStrategy.id, NFCTimerBlockingStrategy.id] {
      for force in [false, true] {
        for physical in [false, true] {
          let profile = try legacyProfile(strategyID, now: now)
          profile.physicalUnblockNFCTagId = physical ? "physical" : nil
          let session = try active(profile, tag: "nfc:original", now: now, force: force)
          let strategy = manager.getStrategy(id: strategyID)
          _ = strategy.stopBlocking(context: context, session: session)
          let scanner = try XCTUnwrap(Mirror(reflecting: strategy).children.compactMap { $0.value as? NFCScannerUtil }.first)
          scanner.onTagScanned?(NFCResult(id: "wrong", dateScanned: now))
          let acceptsAny = !physical && (force || strategyID != NFCBlockingStrategy.id)
          XCTAssertEqual(session.isActive, !acceptsAny)
          if !acceptsAny {
            XCTAssertEqual(profile.profileSchemaVersion, 1)
            scanner.onTagScanned?(NFCResult(id: physical ? "physical" : "original", dateScanned: now))
          }
          XCTAssertFalse(session.isActive)
          XCTAssertEqual(profile.profileSchemaVersion, 3)
        }
      }
    }
  }

}
