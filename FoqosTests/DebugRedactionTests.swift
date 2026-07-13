import XCTest

@testable import FamilyFoqos

final class DebugRedactionTests: XCTestCase {
  func testGivenNFCId_WhenChildModeAndEightCharacters_ThenMasksMiddle() {
    XCTAssertEqual(
      DebugRedaction.physicalUnblockNFCTagIdForDisplay("ABCDEF12", mode: .child),
      "AB…12"
    )
  }

  func testGivenNFCId_WhenChildModeAndSevenCharacters_ThenFullConstantMask() {
    XCTAssertEqual(
      DebugRedaction.physicalUnblockNFCTagIdForDisplay("ABCDEFG", mode: .child),
      "••••••"
    )
  }

  func testGivenNFCId_WhenChildModeAndNil_ThenNil() {
    XCTAssertNil(DebugRedaction.physicalUnblockNFCTagIdForDisplay(nil, mode: .child))
  }

  func testGivenNFCId_WhenParentMode_ThenRaw() {
    XCTAssertEqual(
      DebugRedaction.physicalUnblockNFCTagIdForDisplay("ABCDEF12", mode: .parent),
      "ABCDEF12"
    )
  }

  func testGivenNFCId_WhenIndividualMode_ThenRaw() {
    XCTAssertEqual(
      DebugRedaction.physicalUnblockNFCTagIdForDisplay("ABCDEF12", mode: .individual),
      "ABCDEF12"
    )
  }
}
