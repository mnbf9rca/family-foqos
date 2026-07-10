import XCTest

@testable import FamilyFoqos

@MainActor
final class EmergencyUnblockManagerSnapshotTests: XCTestCase {
  private var suiteName: String!
  private var defaults: UserDefaults!
  private let defaultsKeys = [
    "family_foqos_emergency_unblocks_reset_period_in_days",
    "family_foqos_last_emergency_unblocks_reset_date",
    "family_foqos_emergency_settings_locked",
    "family_foqos_emergency_settings_version",
    "family_foqos_emergency_unblock_events",
    "family_foqos_emergency_reset_epoch",
  ]

  override func setUp() async throws {
    try await super.setUp()
    suiteName = "EmergencySnapshot-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)!
  }

  override func tearDown() async throws {
    for key in defaultsKeys { UserDefaults.standard.removeObject(forKey: key) }
    defaults.removePersistentDomain(forName: suiteName)
    try await super.tearDown()
  }

  func testGivenAppliedState_WhenSnapshotRequested_ThenReflectsCurrentValuesWithoutBump() {
    let now = Date()
    let manager = EmergencyUnblockManager(defaults: defaults)
    manager.seedForTesting(epoch: 1)
    _ = manager.consumeUnblockEvent(now: now)
    let remote = SyncedEmergencySettings(
      unblocksRemaining: 99,
      resetPeriodInDays: 14,
      lastResetDate: now,
      settingsLocked: true,
      version: 9,
      lastModified: now,
      originDeviceId: "remote-device"
    )
    manager.applyRemoteEmergencySettings(remote)

    let snapshot = manager.currentEmergencySettings(deviceId: "device-A", now: now)

    XCTAssertEqual(snapshot.unblocksRemaining, 2, "count is derived from current-epoch events")
    XCTAssertEqual(snapshot.resetPeriodInDays, 14)
    XCTAssertEqual(snapshot.settingsLocked, true)
    XCTAssertEqual(snapshot.version, 9, "snapshot must carry the current version verbatim (no bump)")
    XCTAssertEqual(snapshot.originDeviceId, "device-A")
    XCTAssertEqual(snapshot.lastModified, now)
    XCTAssertEqual(
      snapshot.lastResetDate.timeIntervalSinceReferenceDate,
      now.timeIntervalSinceReferenceDate,
      accuracy: 0.001
    )
  }
}
