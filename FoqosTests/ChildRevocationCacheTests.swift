import Foundation
import XCTest

@testable import FamilyFoqos

@MainActor
final class ChildRevocationCacheTests: XCTestCase {
  private static let cacheKey = "family_foqos_child_lock_codes"

  private var defaults: UserDefaults!
  private var originalMode: AppMode!
  private var suiteName: String!

  override func setUp() {
    super.setUp()
    originalMode = AppModeManager.shared.currentMode
    AppModeManager.shared.selectMode(.child)

    suiteName = "ChildRevocationCacheTests-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)!
    let codes = [FamilyLockCode(code: "test-code", scope: .allChildren)]
    defaults.set(try! JSONEncoder().encode(codes), forKey: Self.cacheKey)
    LockCodeManager.shared.overrideDefaults(defaults)
  }

  override func tearDown() {
    LockCodeManager.shared.overrideDefaults(nil)
    defaults.removePersistentDomain(forName: suiteName)
    AppModeManager.shared.selectMode(originalMode)
    defaults = nil
    originalMode = nil
    suiteName = nil
    super.tearDown()
  }

  func testGivenConfirmedCloudKitRevocation_WhenHandlingCache_ThenPINErased() {
    XCTAssertTrue(LockCodeManager.shared.canVerifyCode)

    LockCodeManager.shared.handleConfirmedCloudKitRevocation()

    XCTAssertFalse(LockCodeManager.shared.canVerifyCode)
    XCTAssertNil(defaults.data(forKey: Self.cacheKey))
  }
}
