import XCTest

@testable import FamilyFoqos

final class SettingsWipeConfirmationTests: XCTestCase {
  func testWipeRequiresLockInChildMode() {
    XCTAssertTrue(SettingsView.wipeRequiresLockVerification(mode: .child, canVerifyCode: true))
    XCTAssertFalse(SettingsView.wipeRequiresLockVerification(mode: .child, canVerifyCode: false))
    XCTAssertFalse(SettingsView.wipeRequiresLockVerification(mode: .parent, canVerifyCode: true))
    XCTAssertFalse(SettingsView.wipeRequiresLockVerification(mode: .individual, canVerifyCode: true))
  }

  func testWipeConfirmationAlwaysStatesV1Caveat() {
    XCTAssertTrue(SettingsView.wipeConfirmationMessage.contains("old app version"))
    XCTAssertTrue(SettingsView.wipeConfirmationMessage.contains("can't interoperate with the new sync"))
  }
}
