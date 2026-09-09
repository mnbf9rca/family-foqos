import XCTest

@testable import FamilyFoqos

final class ParentResetCommandStatusTests: XCTestCase {
  func testAfterSuccessfulSave_IsAwaitingChild_NotConfirmed() {
    XCTAssertEqual(ParentResetCommandStatus.afterSuccessfulSave, .awaitingChild)
    XCTAssertNotEqual(ParentResetCommandStatus.afterSuccessfulSave, .noLongerPending)
  }

  func testConfirmationProbe_StillPending_IsAwaitingChild() {
    XCTAssertEqual(
      ParentResetCommandStatus.afterConfirmationProbe(commandStillPending: true),
      .awaitingChild
    )
  }

  func testConfirmationProbe_Gone_IsNoLongerPending() {
    XCTAssertEqual(
      ParentResetCommandStatus.afterConfirmationProbe(commandStillPending: false),
      .noLongerPending
    )
  }

  func testDisplayText_Awaiting_IsHonestAndNotSuccess() {
    XCTAssertEqual(
      ParentResetCommandStatus.awaitingChild.displayText,
      "Sent — not yet confirmed. Open Foqos on the child's device; both devices may need an app update."
    )
    XCTAssertFalse(
      ParentResetCommandStatus.awaitingChild.displayText!.lowercased().contains("success"),
      "must not claim success at save time (#331a)"
    )
  }

  func testDisplayText_NoLongerPending_AndIdle() {
    XCTAssertEqual(ParentResetCommandStatus.noLongerPending.displayText, "Request no longer pending.")
    XCTAssertNil(ParentResetCommandStatus.idle.displayText)
  }
}
