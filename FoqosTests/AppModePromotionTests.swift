import XCTest

@testable import FamilyFoqos

@MainActor
final class AppModePromotionTests: XCTestCase {
  func testGivenIndividualMode_WhenSettingLockCode_ThenPromotesToParent() {
    XCTAssertEqual(AppModeManager.modeAfterSettingLockCode(from: .individual), .parent)
  }

  func testGivenParentMode_WhenSettingLockCode_ThenNoModeChange() {
    XCTAssertNil(AppModeManager.modeAfterSettingLockCode(from: .parent))
  }

  func testGivenChildMode_WhenSettingLockCode_ThenNoModeChange() {
    XCTAssertNil(AppModeManager.modeAfterSettingLockCode(from: .child))
  }
}
