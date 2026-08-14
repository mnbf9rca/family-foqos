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

  func testGivenConflictThenApproval_WhenForegroundRetries_ThenChildStateIsPreserved() async {
    let appModeManager = AppModeManager.shared
    let cloudKitManager = CloudKitManager.shared
    let pendingAcceptance = PendingShareAcceptance.shared
    let originalMode = appModeManager.currentMode
    let originalConnected = cloudKitManager.isConnectedToFamily
    let originalMessage = cloudKitManager.shareAcceptedMessage
    let originalShareAcceptanceIsError = cloudKitManager.shareAcceptanceIsError
    let originalShowConfirmation = pendingAcceptance.showConfirmation
    let suiteName = "FamilyControlsVerificationTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.set(
      try! JSONEncoder().encode([FamilyLockCode(code: "test-code", scope: .allChildren)]),
      forKey: "family_foqos_child_lock_codes")
    LockCodeManager.shared.overrideDefaults(defaults)
    defer {
      LockCodeManager.shared.overrideDefaults(nil)
      defaults.removePersistentDomain(forName: suiteName)
      appModeManager.selectMode(originalMode)
      cloudKitManager.isConnectedToFamily = originalConnected
      cloudKitManager.shareAcceptedMessage = originalMessage
      cloudKitManager.shareAcceptanceIsError = originalShareAcceptanceIsError
      pendingAcceptance.showConfirmation = originalShowConfirmation
    }

    appModeManager.selectMode(.child)
    cloudKitManager.isConnectedToFamily = true
    cloudKitManager.shareAcceptedMessage = nil
    cloudKitManager.shareAcceptanceIsError = false
    pendingAcceptance.showConfirmation = false
    let results: [AuthorizationVerifier.VerificationResult] = [
      .authorizationConflict,
      .authorized,
    ]
    var verificationIndex = 0

    for expectedVerificationCount in 1...2 {
      await verifyChildAuthorizationIfNeeded {
        defer { verificationIndex += 1 }
        return results[verificationIndex]
      }

      XCTAssertEqual(verificationIndex, expectedVerificationCount)
      XCTAssertEqual(appModeManager.currentMode, .child)
      XCTAssertTrue(cloudKitManager.isConnectedToFamily)
      XCTAssertTrue(LockCodeManager.shared.canVerifyCode)
      XCTAssertNotNil(defaults.data(forKey: "family_foqos_child_lock_codes"))
      XCTAssertNil(cloudKitManager.shareAcceptedMessage)
      XCTAssertFalse(cloudKitManager.shareAcceptanceIsError)
      XCTAssertFalse(pendingAcceptance.showConfirmation)
    }
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
