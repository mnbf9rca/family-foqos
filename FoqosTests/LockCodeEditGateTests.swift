import XCTest

@testable import FamilyFoqos

final class LockCodeEditGateTests: XCTestCase {
  // Only a managed profile, on a child device, not temporarily unlocked, is edit-locked.
  func testGivenManagedProfileOnChildDeviceLocked_WhenGating_ThenEditLocked() {
    XCTAssertTrue(
      LockCodeManager.isEditLocked(isManaged: true, mode: .child, isUnlocked: false))
  }

  func testGivenManagedProfileOnChildDeviceUnlocked_WhenGating_ThenNotLocked() {
    XCTAssertFalse(
      LockCodeManager.isEditLocked(isManaged: true, mode: .child, isUnlocked: true))
  }

  func testGivenManagedProfileOnParentDevice_WhenGating_ThenNotLocked() {
    XCTAssertFalse(
      LockCodeManager.isEditLocked(isManaged: true, mode: .parent, isUnlocked: false))
  }

  // AGENTS.md invariant: Individual mode must NOT be gated (`== .child`, not `!= .parent`).
  func testGivenManagedProfileOnIndividualDevice_WhenGating_ThenNotLocked() {
    XCTAssertFalse(
      LockCodeManager.isEditLocked(isManaged: true, mode: .individual, isUnlocked: false))
  }

  func testGivenUnmanagedProfileOnChildDevice_WhenGating_ThenNotLocked() {
    XCTAssertFalse(
      LockCodeManager.isEditLocked(isManaged: false, mode: .child, isUnlocked: false))
  }
}
