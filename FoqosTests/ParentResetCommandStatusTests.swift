import XCTest

@testable import FamilyFoqos

final class ParentResetCommandStatusTests: XCTestCase {
  func testAfterSuccessfulSave_IsAwaitingChild_NotConfirmed() {
    XCTAssertEqual(ParentResetCommandStatus.afterSuccessfulSave, .awaitingChild)
    XCTAssertNotEqual(ParentResetCommandStatus.afterSuccessfulSave, .confirmed)
  }

  func testConfirmationProbe_StillPending_IsAwaitingChild() {
    XCTAssertEqual(
      ParentResetCommandStatus.afterConfirmationProbe(commandStillPending: true),
      .awaitingChild
    )
  }

  func testConfirmationProbe_Gone_IsConfirmed() {
    XCTAssertEqual(
      ParentResetCommandStatus.afterConfirmationProbe(commandStillPending: false),
      .confirmed
    )
  }

  func testDisplayText_Awaiting_IsHonestAndNotSuccess() {
    XCTAssertEqual(
      ParentResetCommandStatus.awaitingChild.displayText,
      "Sent — waiting for child to confirm"
    )
    XCTAssertFalse(
      ParentResetCommandStatus.awaitingChild.displayText!.lowercased().contains("success"),
      "must not claim success at save time (#331a)"
    )
  }

  func testDisplayText_Confirmed_AndIdle() {
    XCTAssertEqual(ParentResetCommandStatus.confirmed.displayText, "Confirmed by child")
    XCTAssertNil(ParentResetCommandStatus.idle.displayText)
  }
}
