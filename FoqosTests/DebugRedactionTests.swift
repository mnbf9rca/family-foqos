import XCTest

@testable import FamilyFoqos

final class DebugRedactionTests: XCTestCase {
  func testGivenNFCId_WhenPreparingForLog_ThenMasksMiddle() {
    XCTAssertEqual(DebugRedaction.physicalUnblockNFCTagIdForLog("ABCDEF12"), "AB…12")
  }

  func testGivenShortNFCId_WhenPreparingForLog_ThenUsesConstantMask() {
    XCTAssertEqual(DebugRedaction.physicalUnblockNFCTagIdForLog("ABC"), "••••••")
  }

  func testTagSummaryUsesNamesAndCountsWithoutIds() {
    let summary = SavedTag.summary(ids: ["hardware", "removed-id"], names: ["hardware": "Kitchen"])
    XCTAssertEqual(summary, "2: Kitchen, Removed tag")
    XCTAssertFalse(summary.contains("hardware"))
    XCTAssertFalse(summary.contains("removed-id"))
  }
}
