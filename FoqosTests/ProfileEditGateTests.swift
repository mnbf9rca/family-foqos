import XCTest

@testable import FamilyFoqos

final class ProfileEditGateTests: XCTestCase {
  // Parent mode with a managed, not-unlocked profile MUST remain editable (#211 core bug).
  func testGivenParentModeManagedProfile_WhenNotUnlocked_ThenEditingNotDisabled() {
    XCTAssertFalse(
      ProfileEditGate.editingDisabled(
        isBlocking: false, isManaged: true, isUnlocked: false, mode: .parent, lockActive: true))
  }

  func testGivenIndividualModeManagedProfile_WhenNotUnlocked_ThenEditingNotDisabled() {
    XCTAssertFalse(
      ProfileEditGate.editingDisabled(
        isBlocking: false, isManaged: true, isUnlocked: false, mode: .individual, lockActive: true))
  }

  // Child mode with an active lock and not unlocked MUST be disabled.
  func testGivenChildModeManagedProfile_WhenLockedAndNotUnlocked_ThenEditingDisabled() {
    XCTAssertTrue(
      ProfileEditGate.editingDisabled(
        isBlocking: false, isManaged: true, isUnlocked: false, mode: .child, lockActive: true))
  }

  // Child mode, unlocked -> editable.
  func testGivenChildModeManagedProfile_WhenUnlocked_ThenEditingNotDisabled() {
    XCTAssertFalse(
      ProfileEditGate.editingDisabled(
        isBlocking: false, isManaged: true, isUnlocked: true, mode: .child, lockActive: true))
  }

  // Active session always disables editing regardless of mode.
  func testGivenActiveSession_WhenAnyMode_ThenEditingDisabled() {
    XCTAssertTrue(
      ProfileEditGate.editingDisabled(
        isBlocking: true, isManaged: false, isUnlocked: true, mode: .individual, lockActive: false))
  }

  func testGivenRemoteActiveProfile_WhenComputingGate_ThenEditingDisabled() {
    XCTAssertTrue(
      ProfileEditGate.editingDisabled(
        isBlocking: true, isManaged: false, isUnlocked: true, mode: .individual, lockActive: false),
      "#311: a profile active on another device must be passed through as blocking")
  }
}
