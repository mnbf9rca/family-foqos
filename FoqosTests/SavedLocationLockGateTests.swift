import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class SavedLocationLockGateTests: XCTestCase {
  private func makeLocation(isLocked: Bool) -> SavedLocation {
    SavedLocation(id: UUID(), name: "Home", latitude: 1, longitude: 2, isLocked: isLocked)
  }

  func testGivenLockedLocation_WhenChildMode_ThenRequiresLockCode() {
    let location = makeLocation(isLocked: true)
    XCTAssertTrue(location.requiresLockCodeToModify(mode: .child))
  }

  func testGivenLockedLocation_WhenParentMode_ThenNoLockCodeRequired() {
    let location = makeLocation(isLocked: true)
    XCTAssertFalse(location.requiresLockCodeToModify(mode: .parent))
  }

  func testGivenLockedLocation_WhenIndividualMode_ThenNoLockCodeRequired() {
    let location = makeLocation(isLocked: true)
    XCTAssertFalse(location.requiresLockCodeToModify(mode: .individual))
  }

  func testGivenUnlockedLocation_WhenChildMode_ThenNoLockCodeRequired() {
    let location = makeLocation(isLocked: false)
    XCTAssertFalse(location.requiresLockCodeToModify(mode: .child))
  }
}
