import XCTest

@testable import FamilyFoqos

@MainActor
final class LockCodeVerifyTests: XCTestCase {

  private let testPin = "1234"
  private let wrongPin = "9999"
  private let childId = "child-device-001"

  private func makeCode(
    _ pin: String,
    scope: LockCodeScope = .allChildren
  ) -> FamilyLockCode {
    FamilyLockCode(code: pin, scope: scope)
  }

  // MARK: - Parent mode

  func testGivenParentMode_WhenCorrectCode_ThenReturnsTrue() {
    let codes = [makeCode(testPin)]

    let result = LockCodeManager.verifyCode(
      testPin,
      forChildId: nil,
      mode: .parent,
      authorizationType: .none,
      codes: codes
    )

    XCTAssertTrue(result)
  }

  func testGivenParentMode_WhenWrongCode_ThenReturnsFalse() {
    let codes = [makeCode(testPin)]

    let result = LockCodeManager.verifyCode(
      wrongPin,
      forChildId: nil,
      mode: .parent,
      authorizationType: .none,
      codes: codes
    )

    XCTAssertFalse(result)
  }

  func testGivenParentMode_WhenNoCodes_ThenReturnsFalse() {
    let result = LockCodeManager.verifyCode(
      testPin,
      forChildId: nil,
      mode: .parent,
      authorizationType: .none,
      codes: []
    )

    XCTAssertFalse(result)
  }

  // MARK: - Child mode: authorization boundary

  func testGivenChildMode_WhenAuthTypeNotChild_ThenReturnsFalseImmediately() {
    let codes = [makeCode(testPin)]

    let result = LockCodeManager.verifyCode(
      testPin,
      forChildId: childId,
      mode: .child,
      authorizationType: .individual,
      codes: codes
    )

    XCTAssertFalse(result)
  }

  func testGivenChildMode_WhenAuthTypeNone_ThenReturnsFalseImmediately() {
    let codes = [makeCode(testPin)]

    let result = LockCodeManager.verifyCode(
      testPin,
      forChildId: childId,
      mode: .child,
      authorizationType: .none,
      codes: codes
    )

    XCTAssertFalse(result)
  }

  // MARK: - Child mode: specific child code

  func testGivenChildMode_WhenSpecificChildCodeMatches_ThenReturnsTrue() {
    let codes = [makeCode(testPin, scope: .specificChild(childId: childId))]

    let result = LockCodeManager.verifyCode(
      testPin,
      forChildId: childId,
      mode: .child,
      authorizationType: .child,
      codes: codes
    )

    XCTAssertTrue(result)
  }

  func testGivenChildMode_WhenSpecificChildCodeForDifferentChild_ThenFallsThrough() {
    let codes = [makeCode(testPin, scope: .specificChild(childId: "other-child"))]

    let result = LockCodeManager.verifyCode(
      testPin,
      forChildId: childId,
      mode: .child,
      authorizationType: .child,
      codes: codes
    )

    XCTAssertFalse(result)
  }

  // MARK: - Child mode: fallback to allChildren

  func testGivenChildMode_WhenNoSpecificCode_ThenFallsBackToAllChildren() {
    let codes = [makeCode(testPin, scope: .allChildren)]

    let result = LockCodeManager.verifyCode(
      testPin,
      forChildId: childId,
      mode: .child,
      authorizationType: .child,
      codes: codes
    )

    XCTAssertTrue(result)
  }

  func testGivenChildMode_WhenBothSpecificAndGeneral_ThenPrefersSpecific() {
    let specificPin = "5678"
    let generalPin = "1234"
    let codes = [
      makeCode(specificPin, scope: .specificChild(childId: childId)),
      makeCode(generalPin, scope: .allChildren),
    ]

    // Specific code should match
    let resultSpecific = LockCodeManager.verifyCode(
      specificPin,
      forChildId: childId,
      mode: .child,
      authorizationType: .child,
      codes: codes
    )
    XCTAssertTrue(resultSpecific)

    // General code should NOT match (specific takes priority, wrong pin for specific)
    let resultGeneral = LockCodeManager.verifyCode(
      generalPin,
      forChildId: childId,
      mode: .child,
      authorizationType: .child,
      codes: codes
    )
    XCTAssertFalse(resultGeneral)
  }

  // MARK: - Child mode: nil childId

  func testGivenChildMode_WhenNilChildId_ThenSkipsSpecificAndUsesGeneral() {
    let codes = [
      makeCode("5678", scope: .specificChild(childId: childId)),
      makeCode(testPin, scope: .allChildren),
    ]

    let result = LockCodeManager.verifyCode(
      testPin,
      forChildId: nil,
      mode: .child,
      authorizationType: .child,
      codes: codes
    )

    XCTAssertTrue(result)
  }

  // MARK: - Individual mode

  func testGivenIndividualMode_WhenCorrectCode_ThenReturnsTrue() {
    let codes = [makeCode(testPin)]

    let result = LockCodeManager.verifyCode(
      testPin,
      forChildId: nil,
      mode: .individual,
      authorizationType: .none,
      codes: codes
    )

    XCTAssertTrue(result)
  }

  func testGivenIndividualMode_WhenNoAuthCheck_ThenStillVerifies() {
    let codes = [makeCode(testPin)]

    let result = LockCodeManager.verifyCode(
      testPin,
      forChildId: nil,
      mode: .individual,
      authorizationType: .individual,
      codes: codes
    )

    XCTAssertTrue(result)
  }

  // MARK: - Empty codes

  func testGivenChildMode_WhenNoCodes_ThenReturnsFalse() {
    let result = LockCodeManager.verifyCode(
      testPin,
      forChildId: childId,
      mode: .child,
      authorizationType: .child,
      codes: []
    )

    XCTAssertFalse(result)
  }

  func testGivenNoCodes_WhenVerifyingWithNilChildId_ThenReturnsFalse() {
    let result = LockCodeManager.verifyCode(
      "1234",
      forChildId: nil,
      mode: .child,
      authorizationType: .child,
      codes: []
    )
    XCTAssertFalse(result, "Should return false when no codes exist")
  }
}
