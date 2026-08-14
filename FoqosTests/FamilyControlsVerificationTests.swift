import FamilyControls
import Foundation
import XCTest

@testable import FamilyFoqos

@MainActor
final class FamilyControlsVerificationTests: XCTestCase {
  func testGivenSameFamilyControlsDomain_WhenCodesDiffer_ThenTypedOutcomesRemainDistinct() {
    let invalidAccount = NSError(
      domain: FamilyControlsError.errorDomain,
      code: FamilyControlsError.invalidAccountType.rawValue)
    let conflict = NSError(
      domain: FamilyControlsError.errorDomain,
      code: FamilyControlsError.authorizationConflict.rawValue)

    guard case .notChildDevice = AuthorizationVerifier.verificationResult(for: invalidAccount)
    else {
      return XCTFail("invalidAccountType must remain the pre-share non-child signal")
    }
    guard case .authorizationConflict = AuthorizationVerifier.verificationResult(for: conflict)
    else {
      return XCTFail("authorizationConflict must remain recoverable")
    }
  }

  func testGivenFamilyControlsCodes_WhenMapping_ThenEachResultIsTyped() {
    let fixtures: [(FamilyControlsError, ExpectedResult)] = [
      (.restricted, .unknown),
      (.unavailable, .unknown),
      (.invalidAccountType, .notChildDevice),
      (.invalidArgument, .unknown),
      (.authorizationConflict, .authorizationConflict),
      (.authorizationCanceled, .authorizationCanceled),
      (.networkError, .networkError),
      (.authenticationMethodUnavailable, .unknown),
    ]

    for (familyControlsError, expectedResult) in fixtures {
      let error = NSError(
        domain: FamilyControlsError.errorDomain,
        code: familyControlsError.rawValue)

      assert(
        AuthorizationVerifier.verificationResult(for: error),
        matches: expectedResult)
    }
  }

  func testGivenUnauthorizedCode_WhenMapping_ThenResultIsNotAuthorized() throws {
    guard #available(iOS 26.4, *) else { throw XCTSkip("Requires the iOS 26.4 SDK") }
    let error = NSError(
      domain: FamilyControlsError.errorDomain,
      code: FamilyControlsError.unauthorized.rawValue)

    guard case .notAuthorized = AuthorizationVerifier.verificationResult(for: error) else {
      return XCTFail("unauthorized must remain a recoverable authorization result")
    }
  }

  func testGivenUnknownFamilyControlsCode_WhenMapping_ThenResultIsUnknown() {
    let error = NSError(domain: FamilyControlsError.errorDomain, code: Int.max)

    guard case .unknownError = AuthorizationVerifier.verificationResult(for: error) else {
      return XCTFail("unknown Family Controls codes must fail closed")
    }
  }

  func testGivenAnyFamilyControlsFailure_WhenEnrolledChildDisposition_ThenResultIsIndeterminate() {
    let underlyingError = NSError(domain: FamilyControlsError.errorDomain, code: Int.max)
    let results: [AuthorizationVerifier.VerificationResult] = [
      .notChildDevice,
      .notAuthorized,
      .authorizationConflict,
      .authorizationCanceled,
      .networkError(underlyingError),
      .unknownError(underlyingError),
    ]

    for result in results {
      XCTAssertEqual(
        AuthorizationVerifier.verificationDisposition(for: result),
        .indeterminate)
    }
  }

  func testGivenVerificationResult_WhenDetectingPreShareRole_ThenOnlyTypedRolesAreReturned() {
    XCTAssertEqual(AuthorizationVerifier.detectedFamilyRole(for: .authorized), .child)
    XCTAssertEqual(AuthorizationVerifier.detectedFamilyRole(for: .notChildDevice), .parent)
    XCTAssertNil(AuthorizationVerifier.detectedFamilyRole(for: .notAuthorized))
    XCTAssertNil(AuthorizationVerifier.detectedFamilyRole(for: .authorizationConflict))
    XCTAssertNil(AuthorizationVerifier.detectedFamilyRole(for: .authorizationCanceled))
  }

  func testGivenConflictThenApproval_WhenRetryingEnrolledChild_ThenStateNeverLeavesChild() {
    let results: [AuthorizationVerifier.VerificationResult] = [
      .authorizationConflict,
      .authorized,
    ]

    XCTAssertEqual(
      results.map(AuthorizationVerifier.verificationDisposition(for:)),
      [.indeterminate, .authorized])
    XCTAssertNil(AuthorizationVerifier.detectedFamilyRole(for: results[0]))
    XCTAssertEqual(AuthorizationVerifier.detectedFamilyRole(for: results[1]), .child)
  }

  func testGivenAuthorizationConflict_WhenReadingGuidance_ThenCopyIsRecoverableAndAccurate() {
    let message = AuthorizationVerifier.VerificationResult.authorizationConflict.errorMessage?
      .lowercased()

    XCTAssertNotNil(message)
    XCTAssertTrue(message?.contains("couldn't check") == true)
    XCTAssertTrue(message?.contains("try again") == true)
    for forbiddenWord in ["removed", "revoked", "invitation", "leave"] {
      XCTAssertFalse(message?.contains(forbiddenWord) == true)
    }
  }

  func testGivenInvalidAccountType_WhenReadingEnrolledChildGuidance_ThenNoInvitationIsClaimed() {
    let message = AuthorizationVerifier.VerificationResult.notChildDevice.errorMessage?
      .lowercased()

    XCTAssertNotNil(message)
    XCTAssertTrue(message?.contains("couldn't verify") == true)
    XCTAssertTrue(message?.contains("try again") == true)
    for forbiddenWord in ["removed", "revoked", "invitation", "leave"] {
      XCTAssertFalse(message?.contains(forbiddenWord) == true)
    }
  }

  private enum ExpectedResult {
    case notChildDevice
    case authorizationConflict
    case authorizationCanceled
    case networkError
    case unknown
  }

  private func assert(
    _ result: AuthorizationVerifier.VerificationResult,
    matches expectedResult: ExpectedResult,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let matches: Bool
    switch (result, expectedResult) {
    case (.notChildDevice, .notChildDevice),
      (.authorizationConflict, .authorizationConflict),
      (.authorizationCanceled, .authorizationCanceled),
      (.networkError, .networkError),
      (.unknownError, .unknown):
      matches = true
    default:
      matches = false
    }

    XCTAssertTrue(matches, "Unexpected typed mapping", file: file, line: line)
  }
}
