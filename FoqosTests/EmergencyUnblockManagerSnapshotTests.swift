import XCTest

@testable import FamilyFoqos

@MainActor
final class EmergencyUnblockManagerSnapshotTests: XCTestCase {
  private let defaultsKeys = [
    "family_foqos_emergency_unblocks_remaining",
    "family_foqos_emergency_unblocks_reset_period_in_days",
    "family_foqos_last_emergency_unblocks_reset_date",
    "family_foqos_emergency_settings_locked",
    "family_foqos_emergency_settings_version",
  ]

  override func tearDown() async throws {
    for key in defaultsKeys { UserDefaults.standard.removeObject(forKey: key) }
    try await super.tearDown()
  }

  func testGivenAppliedState_WhenSnapshotRequested_ThenReflectsCurrentValuesWithoutBump() {
    let now = Date()
    let manager = EmergencyUnblockManager()
    let remote = SyncedEmergencySettings(
      unblocksRemaining: 2,
      resetPeriodInDays: 14,
      lastResetDate: now,
      settingsLocked: true,
      version: 9,
      lastModified: now,
      originDeviceId: "remote-device"
    )
    manager.applyRemoteEmergencySettings(remote)

    let snapshot = manager.currentEmergencySettings(deviceId: "device-A", now: now)

    XCTAssertEqual(snapshot.unblocksRemaining, 2)
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
