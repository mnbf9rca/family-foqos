import CloudKit
import Foundation
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class EmergencyUnblockMigrationTests: XCTestCase {
  private var suiteName: String!
  private var defaults: UserDefaults!

  override func setUp() async throws {
    try await super.setUp()
    suiteName = "EmergencyMigration-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)!
  }

  override func tearDown() async throws {
    defaults.removePersistentDomain(forName: suiteName)
    try await super.tearDown()
  }

  private func seedV1(_ defaults: UserDefaults, remaining: Int, weeks: Int, resetDate: Date) {
    defaults.set(remaining, forKey: "emergencyUnblocksRemaining")
    defaults.set(weeks, forKey: "emergencyUnblocksResetPeriodInWeeks")
    defaults.set(resetDate.timeIntervalSinceReferenceDate, forKey: "lastEmergencyUnblocksResetDate")
  }

  func testRealV1CountsAndPeriodsSurviveMigrationWithoutRefill() {
    let now = Date()
    for remaining in 0...3 {
      for weeks in [2, 4, 6, 8] {
        defaults.removePersistentDomain(forName: suiteName)
        seedV1(defaults, remaining: remaining, weeks: weeks, resetDate: now)

        UserDefaultsMigration.migrateIfNeeded(defaults: defaults)
        let manager = EmergencyUnblockManager(defaults: defaults)

        XCTAssertEqual(manager.getRemainingEmergencyUnblocks(), remaining)
        XCTAssertEqual(manager.getResetPeriodInDays(), weeks * 7)
        XCTAssertEqual(manager.getNextResetDate(), Calendar.current.date(byAdding: .day, value: weeks * 7, to: now))
        XCTAssertEqual(manager.emergencySettingsVersion, 0, "migration is not a new settings edit")
        XCTAssertNil(defaults.object(forKey: "emergencyUnblocksResetPeriodInWeeks"))
        XCTAssertNil(defaults.object(forKey: "emergencyUnblocksRemaining"))
        XCTAssertNil(defaults.object(forKey: "family_foqos_emergency_unblocks_remaining"))
      }
    }
  }

  func testManagerMigratesV1BeforeReadingSettingsWithoutAppStartup() {
    let now = Date()
    seedV1(defaults, remaining: 1, weeks: 6, resetDate: now)

    let manager = EmergencyUnblockManager(defaults: defaults)

    XCTAssertEqual(manager.getRemainingEmergencyUnblocks(), 1)
    XCTAssertEqual(manager.getResetPeriodInDays(), 42)
    XCTAssertEqual(manager.getNextResetDate(), Calendar.current.date(byAdding: .day, value: 42, to: now))
  }

  func testExistingV2SettingsWinOverLegacyShadows() {
    let now = Date()
    let resetDate = now.addingTimeInterval(-3_600)
    seedV1(defaults, remaining: 1, weeks: 6, resetDate: now)
    defaults.set(28, forKey: "emergencyUnblocksResetPeriodInDays")
    defaults.set(false, forKey: "emergencySettingsLocked")
    defaults.set(2, forKey: "emergencySettingsVersion")
    defaults.set(14, forKey: "family_foqos_emergency_unblocks_reset_period_in_days")
    defaults.set(resetDate.timeIntervalSinceReferenceDate, forKey: "family_foqos_last_emergency_unblocks_reset_date")
    defaults.set(true, forKey: "family_foqos_emergency_settings_locked")
    defaults.set(9, forKey: "family_foqos_emergency_settings_version")

    let manager = EmergencyUnblockManager(defaults: defaults)
    let settings = manager.currentEmergencySettings(deviceId: "test-device", now: now)

    XCTAssertEqual(settings.resetPeriodInDays, 14)
    XCTAssertEqual(settings.lastResetDate, resetDate)
    XCTAssertTrue(settings.settingsLocked)
    XCTAssertEqual(settings.version, 9)
    XCTAssertEqual(settings.unblocksRemaining, 1)
  }

  func testCrashReplayAndPeerMigrationUnionWithoutDoubleCounting() throws {
    let now = Date()
    let peerSuite = "EmergencyMigrationPeer-\(UUID().uuidString)"
    let peerDefaults = try XCTUnwrap(UserDefaults(suiteName: peerSuite))
    defer { peerDefaults.removePersistentDomain(forName: peerSuite) }
    seedV1(defaults, remaining: 1, weeks: 6, resetDate: now)
    seedV1(peerDefaults, remaining: 1, weeks: 6, resetDate: now.addingTimeInterval(-86_400))
    let first = EmergencyUnblockManager(defaults: defaults)
    let peer = EmergencyUnblockManager(defaults: peerDefaults)
    let names = Set(first.allUnblockEventRecordNames())
    XCTAssertEqual(names.count, 2)
    XCTAssertEqual(names, Set(peer.allUnblockEventRecordNames()), "slot identities must not depend on device or reset date")

    // Crash after ledger persistence but before removing the migrated counter.
    defaults.set(1, forKey: "family_foqos_emergency_unblocks_remaining")
    let replay = EmergencyUnblockManager(defaults: defaults)
    for name in peer.allUnblockEventRecordNames() {
      replay.mergeRemoteUnblockEvent(try XCTUnwrap(peer.eventRecord(forRecordName: name)))
    }
    XCTAssertEqual(Set(replay.allUnblockEventRecordNames()), names)
    XCTAssertEqual(replay.getRemainingEmergencyUnblocks(), 1)
    XCTAssertNil(defaults.object(forKey: "family_foqos_emergency_unblocks_remaining"))

    let fresh = replay.consumeUnblockEvent(now: now)
    peer.mergeRemoteUnblockEvent(fresh)
    XCTAssertEqual(replay.getRemainingEmergencyUnblocks(), 0)
    XCTAssertEqual(peer.getRemainingEmergencyUnblocks(), 0)
  }

  func testDifferentV1DeviceCountsConvergeWithoutRefill() throws {
    let now = Date()
    let peerSuite = "EmergencyMigrationPeer-\(UUID().uuidString)"
    let peerDefaults = try XCTUnwrap(UserDefaults(suiteName: peerSuite))
    defer { peerDefaults.removePersistentDomain(forName: peerSuite) }
    seedV1(defaults, remaining: 1, weeks: 2, resetDate: now)
    seedV1(peerDefaults, remaining: 3, weeks: 2, resetDate: now)
    let first = EmergencyUnblockManager(defaults: defaults)
    let peer = EmergencyUnblockManager(defaults: peerDefaults)

    for name in first.allUnblockEventRecordNames() {
      peer.mergeRemoteUnblockEvent(try XCTUnwrap(first.eventRecord(forRecordName: name)))
    }

    XCTAssertEqual(first.getRemainingEmergencyUnblocks(), 1)
    XCTAssertEqual(peer.getRemainingEmergencyUnblocks(), 1)
  }

  func testLegacyConsumptionMergesWithExistingEventsRegardlessOfFetchOrder() throws {
    let now = Date()
    let event = SyncedEmergencyUnblockEvent(id: UUID(), deviceId: "peer", consumedAt: now, resetEpoch: 0)
    defaults.set(try JSONEncoder().encode([event]), forKey: "family_foqos_emergency_unblock_events")
    seedV1(defaults, remaining: 1, weeks: 6, resetDate: now)
    let migrated = EmergencyUnblockManager(defaults: defaults)

    XCTAssertEqual(migrated.getRemainingEmergencyUnblocks(), 0, "both V1 consumption and the fetched/local event count")
    XCTAssertEqual(migrated.allUnblockEventRecordNames().count, 3)
  }

  func testSettingsSyncPreservesVersionOrderingAndCannotRefillMigratedUsage() throws {
    let now = Date()
    seedV1(defaults, remaining: 1, weeks: 6, resetDate: now)
    let manager = EmergencyUnblockManager(defaults: defaults)
    let container = try TestModelContainer.create()
    let store = SyncEngineStore(userRecordName: "test-user", defaults: defaults)
    let apply = SyncApplyService(
      modelContext: container.mainContext, store: store, sessionController: MockSessionController(),
      emergencyManager: manager, deviceId: "test-device")
    let zone = CKRecordZone.ID(zoneName: CloudKitConstants.syncZoneName, ownerName: CKCurrentUserDefaultName)
    func receive(version: Int, days: Int) {
      let remote = SyncedEmergencySettings(
        unblocksRemaining: 3, resetPeriodInDays: days, lastResetDate: now,
        settingsLocked: true, version: version, lastModified: now, originDeviceId: "peer")
      _ = apply.applyFetchedModification(remote.toCKRecord(in: zone), isPendingDeleteOrTombstoned: { _ in false })
    }

    receive(version: 0, days: 28)
    XCTAssertEqual(manager.getResetPeriodInDays(), 42, "equal-version default must not overwrite migration")
    receive(version: 5, days: 14)
    XCTAssertEqual(manager.getResetPeriodInDays(), 14, "a newer explicit config wins")
    receive(version: 4, days: 56)
    XCTAssertEqual(manager.getResetPeriodInDays(), 14, "stale settings must not win")
    XCTAssertEqual(manager.getRemainingEmergencyUnblocks(), 1)
    XCTAssertEqual(manager.emergencySettingsVersion, 5)

    let restarted = EmergencyUnblockManager(defaults: defaults)
    XCTAssertEqual(restarted.getRemainingEmergencyUnblocks(), 1)
    XCTAssertEqual(restarted.getResetPeriodInDays(), 14)
    XCTAssertEqual(restarted.emergencySettingsVersion, 5)
    XCTAssertTrue(restarted.isEmergencySettingsLocked())
  }

  func testImportedEventsMaterializeForFirstBootstrapSync() throws {
    let now = Date()
    seedV1(defaults, remaining: 1, weeks: 6, resetDate: now)
    let manager = EmergencyUnblockManager(defaults: defaults)
    let container = try TestModelContainer.create()
    let store = SyncEngineStore(userRecordName: "test-user", defaults: defaults)
    let provider = RecordProvider(
      modelContext: container.mainContext, store: store, emergencyManager: manager, deviceId: "test-device")

    XCTAssertEqual(provider.restorableEmergencyRecordNames().count, 3, "epoch plus two imported events")
    for name in manager.allUnblockEventRecordNames() {
      let event = try XCTUnwrap(SyncedEmergencyUnblockEvent(from: try XCTUnwrap(provider.record(forRecordName: name))))
      XCTAssertEqual(event.resetEpoch, 0)
      XCTAssertEqual(event.consumedAt, now)
    }
    let settings = try XCTUnwrap(SyncedEmergencySettings(from: try XCTUnwrap(provider.record(forRecordName: SyncedEmergencySettings.recordName))))
    XCTAssertEqual(settings.unblocksRemaining, 1)
    XCTAssertEqual(settings.resetPeriodInDays, 42)
    XCTAssertEqual(settings.version, 0)
  }

  func testMissingLegacyResetTimestampUsesReferenceDateZero() throws {
    defaults.set(1, forKey: "emergencyUnblocksRemaining")
    defaults.set(2, forKey: "emergencyUnblocksResetPeriodInWeeks")
    let manager = EmergencyUnblockManager(defaults: defaults)

    XCTAssertEqual(manager.getRemainingEmergencyUnblocks(), 1)
    XCTAssertEqual(manager.getResetPeriodInDays(), 14)
    XCTAssertNil(manager.getNextResetDate())
    for name in manager.allUnblockEventRecordNames() {
      XCTAssertEqual(try XCTUnwrap(manager.eventRecord(forRecordName: name)).consumedAt, Date(timeIntervalSinceReferenceDate: 0))
    }
  }

  func testEpochAdvanceRefillsNormallyButRelaunchDoesNotReseed() {
    let now = Date()
    seedV1(defaults, remaining: 1, weeks: 6, resetDate: now)
    let manager = EmergencyUnblockManager(defaults: defaults)
    XCTAssertEqual(manager.getRemainingEmergencyUnblocks(), 1)

    manager.adoptRemoteEpoch(1)
    let restarted = EmergencyUnblockManager(defaults: defaults)

    XCTAssertEqual(restarted.getRemainingEmergencyUnblocks(), 3)
    XCTAssertEqual(restarted.currentResetEpoch, 1)
    XCTAssertEqual(restarted.getResetPeriodInDays(), 42)
  }

  func testGenerationAdoptionClearsUsageButPreservesConvertedConfiguration() {
    let now = Date()
    seedV1(defaults, remaining: 1, weeks: 6, resetDate: now)
    let manager = EmergencyUnblockManager(defaults: defaults)
    manager.clearLedgerForGenerationAdoption()
    let restarted = EmergencyUnblockManager(defaults: defaults)

    XCTAssertEqual(restarted.getRemainingEmergencyUnblocks(), 3)
    XCTAssertEqual(restarted.getResetPeriodInDays(), 42)
    XCTAssertTrue(restarted.allUnblockEventRecordNames().isEmpty)
  }

  func testAccountSwitchDoesNotResurrectLegacySettingsOrConsumption() {
    let now = Date()
    seedV1(defaults, remaining: 1, weeks: 6, resetDate: now)
    let manager = EmergencyUnblockManager(defaults: defaults)
    manager.resetAllStateForAccountSwitch()
    let restarted = EmergencyUnblockManager(defaults: defaults)

    XCTAssertEqual(restarted.getRemainingEmergencyUnblocks(), 3)
    XCTAssertEqual(restarted.getResetPeriodInDays(), 28)
    XCTAssertNil(restarted.getNextResetDate())
  }

  func testUnsavedV1DefaultsStayThreeAndTwentyEightWithoutSyntheticUsage() {
    let manager = EmergencyUnblockManager(defaults: defaults)

    XCTAssertEqual(manager.getRemainingEmergencyUnblocks(), 3)
    XCTAssertEqual(manager.getResetPeriodInDays(), 28)
    XCTAssertTrue(manager.allUnblockEventRecordNames().isEmpty)
  }
}
