import XCTest

@testable import FamilyFoqos

@MainActor
final class LockCodeChangedPinRegressionTests: XCTestCase {

  private let oldPin = "1234"
  private let newPin = "5678"
  private let childId = "child-device-001"

  private func code(_ pin: String) -> FamilyLockCode {
    FamilyLockCode(code: pin, scope: .allChildren)
  }

  func testGivenConnectedRefreshWithChangedPin_ThenNewCodeAdoptedAndOldDropped() {
    let resolved = LockCodeManager.resolveLockCodes(
      fetched: [code(newPin)],
      isConnected: true,
      persisted: [code(oldPin)]
    )

    XCTAssertTrue(
      LockCodeManager.verifyCode(
        newPin,
        forChildId: childId,
        mode: .child,
        authorizationType: .child,
        codes: resolved.cache),
      "New PIN must verify after a connected refresh")
    XCTAssertFalse(
      LockCodeManager.verifyCode(
        oldPin,
        forChildId: childId,
        mode: .child,
        authorizationType: .child,
        codes: resolved.cache),
      "Revoked old PIN must not verify after a connected refresh")
  }

  func testGivenDisconnectedRefresh_ThenLastSyncedCodesRetained() {
    let resolved = LockCodeManager.resolveLockCodes(
      fetched: [],
      isConnected: false,
      persisted: [code(oldPin)]
    )

    XCTAssertTrue(
      LockCodeManager.verifyCode(
        oldPin,
        forChildId: childId,
        mode: .child,
        authorizationType: .child,
        codes: resolved.cache),
      "Offline, the last-synced PIN must still verify")
  }
}
