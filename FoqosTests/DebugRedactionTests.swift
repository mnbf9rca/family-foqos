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

  func testGivenQRDigest_WhenChildMode_ThenVisible() {
    let digest = String(repeating: "a", count: 64)

    XCTAssertEqual(
      DebugRedaction.physicalUnblockQRCodeIdForDisplay(digest, mode: .child),
      digest
    )
  }

  func testGivenLegacyQRPlaintext_WhenChildModeAndEightCharacters_ThenMasksMiddle() {
    XCTAssertEqual(
      DebugRedaction.physicalUnblockQRCodeIdForDisplay("legacy12", mode: .child),
      "le…12"
    )
  }

  func testGivenLegacyQRPlaintext_WhenChildModeAndSevenCharacters_ThenFullConstantMask() {
    XCTAssertEqual(
      DebugRedaction.physicalUnblockQRCodeIdForDisplay("legacy1", mode: .child),
      "••••••"
    )
  }

  func testGivenUppercaseOrNonHexQR_WhenChildMode_ThenTreatedAsLegacyPlaintext() {
    XCTAssertEqual(
      DebugRedaction.physicalUnblockQRCodeIdForDisplay(String(repeating: "A", count: 64), mode: .child),
      "AA…AA"
    )
    XCTAssertEqual(
      DebugRedaction.physicalUnblockQRCodeIdForDisplay(String(repeating: "g", count: 64), mode: .child),
      "gg…gg"
    )
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

  func testGivenQRValue_WhenParentMode_ThenRaw() {
    XCTAssertEqual(
      DebugRedaction.physicalUnblockQRCodeIdForDisplay("legacy-plaintext", mode: .parent),
      "legacy-plaintext"
    )
  }
}
