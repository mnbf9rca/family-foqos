import XCTest

@testable import FamilyFoqos

@MainActor
final class ChildDashboardCopyTests: XCTestCase {
  func testGivenLockedProfilesFooter_WhenRead_ThenPromisesEditOrDeleteNotStop() {
    let footer = EditLockedProfilesSheet.lockedProfilesFooter
    XCTAssertEqual(footer, "Locked profiles require the lock code to edit or delete.")
    XCTAssertFalse(
      footer.lowercased().contains("stop"),
      "Footer must not promise that stopping is lock-gated (stopping is un-gated by design, deviation #7)"
    )
  }
}
