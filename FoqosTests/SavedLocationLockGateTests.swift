import XCTest

@testable import FamilyFoqos

@MainActor
final class SavedLocationLockGateTests: XCTestCase {
  private func makeLocation(isLocked: Bool) -> SavedLocation {
    SavedLocation(id: UUID(), name: "Home", latitude: 1, longitude: 2, isLocked: isLocked)
  }

  func testGivenLockedLocation_WhenChildModeAndCodeAvailable_ThenRequiresLockCode() {
    let location = makeLocation(isLocked: true)
    XCTAssertTrue(location.requiresLockCodeToModify(mode: .child, canVerifyCode: true))
  }

  func testGivenLockedLocation_WhenChildModeAndNoCodeAvailable_ThenNoLockCodeRequired() {
    let location = makeLocation(isLocked: true)
    XCTAssertFalse(location.requiresLockCodeToModify(mode: .child, canVerifyCode: false))
  }

  func testGivenLockedLocation_WhenParentMode_ThenNoLockCodeRequired() {
    let location = makeLocation(isLocked: true)
    XCTAssertFalse(location.requiresLockCodeToModify(mode: .parent, canVerifyCode: true))
  }

  func testGivenLockedLocation_WhenIndividualMode_ThenNoLockCodeRequired() {
    let location = makeLocation(isLocked: true)
    XCTAssertFalse(location.requiresLockCodeToModify(mode: .individual, canVerifyCode: true))
  }

  func testGivenUnlockedLocation_WhenChildMode_ThenNoLockCodeRequired() {
    let location = makeLocation(isLocked: false)
    XCTAssertFalse(location.requiresLockCodeToModify(mode: .child, canVerifyCode: true))
  }
}
