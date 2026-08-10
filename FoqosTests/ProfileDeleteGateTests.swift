import XCTest

@testable import FamilyFoqos

final class ProfileDeleteGateTests: XCTestCase {
  func testGivenRemotelyActive_WhenComputingGate_ThenBlockedRemotelyActive() {
    XCTAssertEqual(
      ProfileDeleteGate.blockedReason(
        hasLocalActiveSession: false,
        isRemotelyActive: true,
        isEditLocked: false
      ),
      .remotelyActive
    )
  }

  func testGivenLocalActive_WhenComputingGate_ThenBlockedActive() {
    XCTAssertEqual(
      ProfileDeleteGate.blockedReason(
        hasLocalActiveSession: true,
        isRemotelyActive: false,
        isEditLocked: false
      ),
      .active
    )
  }

  func testGivenEditLocked_WhenComputingGate_ThenBlockedLocked() {
    XCTAssertEqual(
      ProfileDeleteGate.blockedReason(
        hasLocalActiveSession: false,
        isRemotelyActive: false,
        isEditLocked: true
      ),
      .locked
    )
  }

  func testGivenNothing_WhenComputingGate_ThenNil() {
    XCTAssertNil(
      ProfileDeleteGate.blockedReason(
        hasLocalActiveSession: false,
        isRemotelyActive: false,
        isEditLocked: false
      )
    )
  }

  func testGivenLocalAndRemoteActive_WhenComputingGate_ThenLocalActiveWins() {
    XCTAssertEqual(
      ProfileDeleteGate.blockedReason(
        hasLocalActiveSession: true,
        isRemotelyActive: true,
        isEditLocked: false
      ),
      .active
    )
  }
}
