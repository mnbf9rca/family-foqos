import XCTest

@testable import FamilyFoqos

final class DiagnosticsAccessTests: XCTestCase {
  func testGivenChildMode_WhenCheckingDiagnosticsAccess_ThenRestricted() {
    XCTAssertTrue(DiagnosticsAccess.isRestricted(mode: .child))
  }

  func testGivenParentMode_WhenCheckingDiagnosticsAccess_ThenAllowed() {
    XCTAssertFalse(DiagnosticsAccess.isRestricted(mode: .parent))
  }

  func testGivenIndividualMode_WhenCheckingDiagnosticsAccess_ThenAllowed() {
    XCTAssertFalse(DiagnosticsAccess.isRestricted(mode: .individual))
  }
}
