import Foundation
import XCTest

@testable import FamilyFoqos

final class ChildRevocationCacheTests: XCTestCase {
  private static let cacheKey = "family_foqos_child_lock_codes"

  @MainActor
  func testGivenConfirmedCloudKitRevocation_WhenHandlingCache_ThenPINErased() {
    let suiteName = "ChildRevocationCacheTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let codes = [FamilyLockCode(code: "test-code", scope: .allChildren)]
    defaults.set(try! JSONEncoder().encode(codes), forKey: Self.cacheKey)
    LockCodeManager.shared.overrideDefaults(defaults)
    defer {
      LockCodeManager.shared.overrideDefaults(nil)
      defaults.removePersistentDomain(forName: suiteName)
    }
    XCTAssertNotNil(defaults.data(forKey: Self.cacheKey))
    XCTAssertEqual(LockCodeManager.shared.cachedChildLockCodeCount, 1)

    LockCodeManager.shared.handleConfirmedCloudKitRevocation()

    XCTAssertNil(defaults.data(forKey: Self.cacheKey))
    XCTAssertEqual(LockCodeManager.shared.cachedChildLockCodeCount, 0)
  }
}
