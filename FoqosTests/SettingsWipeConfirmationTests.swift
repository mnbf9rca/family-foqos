import XCTest

@testable import FamilyFoqos

final class SettingsWipeConfirmationTests: XCTestCase {
  func testWipeRequiresLockInChildMode() {
    XCTAssertTrue(SettingsView.wipeRequiresLockVerification(mode: .child, canVerifyCode: true))
    XCTAssertFalse(SettingsView.wipeRequiresLockVerification(mode: .child, canVerifyCode: false))
    XCTAssertFalse(SettingsView.wipeRequiresLockVerification(mode: .parent, canVerifyCode: true))
    XCTAssertFalse(SettingsView.wipeRequiresLockVerification(mode: .individual, canVerifyCode: true))
  }

  func testWipeAvailabilityFailsClosedOnlyForChildWithoutVerifiableCode() {
    XCTAssertTrue(SettingsView.wipeIsAllowed(mode: .child, canVerifyCode: true))
    XCTAssertFalse(SettingsView.wipeIsAllowed(mode: .child, canVerifyCode: false))
    XCTAssertTrue(SettingsView.wipeIsAllowed(mode: .parent, canVerifyCode: false))
    XCTAssertTrue(SettingsView.wipeIsAllowed(mode: .individual, canVerifyCode: false))
  }

  func testWipeConfirmationRechecksAvailabilityBeforeChoosingItsAction() {
    XCTAssertEqual(
      SettingsView.wipeConfirmationAction(isAllowed: false, requiresLockVerification: false),
      .blocked)
    XCTAssertEqual(
      SettingsView.wipeConfirmationAction(isAllowed: true, requiresLockVerification: true),
      .requestLockVerification)
    XCTAssertEqual(
      SettingsView.wipeConfirmationAction(isAllowed: true, requiresLockVerification: false),
      .confirm)
  }

  func testWipeConfirmationAlwaysStatesV1Caveat() {
    XCTAssertTrue(SettingsView.wipeConfirmationMessage.contains("old app version"))
    XCTAssertTrue(SettingsView.wipeConfirmationMessage.contains("can't interoperate with the new sync"))
  }
}
