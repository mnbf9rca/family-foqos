import XCTest

@testable import FamilyFoqos

@MainActor
final class FamilyCommandApplyTests: XCTestCase {
  private static let emergencyDefaultsKeys = [
    "family_foqos_emergency_unblocks_reset_period_in_days",
    "family_foqos_last_emergency_unblocks_reset_date",
    "family_foqos_emergency_settings_locked",
    "family_foqos_emergency_settings_version",
    "family_foqos_emergency_unblock_events",
    "family_foqos_emergency_reset_epoch",
  ]

  override func setUp() {
    super.setUp()
    MainActor.assumeIsolated {
      let defaults = UserDefaults(suiteName: "FamilyCommandApplyTests")!
      defaults.removePersistentDomain(forName: "FamilyCommandApplyTests")
      LockCodeManager.shared.overrideDefaults(defaults)
      LockCodeManager.shared.resetThrottle()
      EmergencyUnblockManager.shared.seedForTesting(epoch: 0)
    }
  }

  override func tearDown() {
    MainActor.assumeIsolated {
      LockCodeManager.shared.resetThrottle()
      LockCodeManager.shared.overrideDefaults(nil)
      for key in Self.emergencyDefaultsKeys {
        UserDefaults.standard.removeObject(forKey: key)
      }
    }
    super.tearDown()
  }

  func testGivenLockedOutChild_WhenResetThrottleCommandApplied_ThenThrottleCleared() {
    let now = Date()
    for _ in 0..<10 {
      LockCodeManager.shared.recordFailedAttempt(now: now)
    }
    XCTAssertTrue(LockCodeManager.shared.isLockedOut(now: now))

    let command = FamilyCommand(
      commandType: .resetLockCodeThrottle,
      targetChildId: "child-rec-1",
      createdBy: "parent-rec-1"
    )
    LockCodeManager.shared.applyCommand(command)

    XCTAssertEqual(LockCodeManager.shared.failedAttempts, 0)
    XCTAssertFalse(LockCodeManager.shared.isLockedOut(now: now))
  }

  func testGivenEmergencyResetCommandAlreadyProcessed_WhenDeliveredAfterFreshLoad_ThenEpochAdvancesOnce() {
    let command = FamilyCommand(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000230")!,
      commandType: .resetEmergencyCount,
      targetChildId: "child-rec-1",
      createdBy: "parent-rec-1",
      createdAt: Date()
    )

    XCTAssertTrue(LockCodeManager.shared.applyCommandIfNeeded(command))
    let defaults = UserDefaults(suiteName: "FamilyCommandApplyTests")!
    LockCodeManager.shared.overrideDefaults(nil)
    LockCodeManager.shared.overrideDefaults(defaults)

    XCTAssertFalse(LockCodeManager.shared.applyCommandIfNeeded(command))
    XCTAssertEqual(EmergencyUnblockManager.shared.currentResetEpoch, 1)
  }
}
