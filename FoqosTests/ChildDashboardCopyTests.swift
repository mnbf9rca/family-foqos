import XCTest

@testable import FamilyFoqos

@MainActor
final class ChildDashboardCopyTests: XCTestCase {
  func testGivenRecoverableAuthorizationFailure_WhenPresentingAlert_ThenCopyOffersRetryOnly() {
    XCTAssertEqual(
      ChildDashboardView.authorizationVerificationAlertTitle,
      "Unable to Verify Screen Time")
    XCTAssertEqual(
      ChildDashboardView.authorizationVerificationActions.map(\.title),
      ["Try Again", "Cancel"])
  }

  func testGivenLockedProfilesFooter_WhenRead_ThenPromisesEditOrDeleteNotStop() {
    let footer = EditLockedProfilesSheet.lockedProfilesFooter
    XCTAssertEqual(footer, "Locked profiles require the lock code to edit or delete.")
    XCTAssertFalse(
      footer.lowercased().contains("stop"),
      "Footer must not promise that stopping is lock-gated (stopping is un-gated by design, deviation #7)"
    )
  }

  func testGivenDisableRequested_WhenVerificationHasNotSucceeded_ThenChangeCannotBeApplied() {
    var gate = EmergencySettingsLockChangeGate()

    gate.request(false)

    XCTAssertNil(gate.resolve(verificationSucceeded: false))
  }

  func testGivenDisableRequested_WhenVerificationSucceeds_ThenPendingValueCanBeApplied() {
    var gate = EmergencySettingsLockChangeGate()

    gate.request(false)

    XCTAssertEqual(gate.resolve(verificationSucceeded: true), false)
    XCTAssertNil(
      gate.resolve(verificationSucceeded: true),
      "A verified change must be consumed exactly once"
    )
  }
}
