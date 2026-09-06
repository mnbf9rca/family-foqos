import XCTest

@testable import FamilyFoqos

@MainActor
final class QRScannerZoomTests: XCTestCase {
  func testZoomCyclesOnlyThroughSupportedPresets() {
    let cases: [(CGFloat, CGFloat, CGFloat, CGFloat?)] = [
      (1, 1, 10, 2), (2, 1, 10, 5), (5, 1, 10, 1),
      (1, 1, 3, 2), (2, 1, 3, 1), (2, 2, 5, 5), (5, 2, 5, 2),
      (3, 1, 5, 5), (5, 1, 2, 1),
      (1, 1, 1, nil), (1, 1, 1.5, nil), (3, 3, 4, nil), (1, 5, 1, nil),
    ]
    for (current, minimum, maximum, expected) in cases {
      XCTAssertEqual(
        LabeledCodeScannerView.nextZoomFactor(
          current: current, minimum: minimum, maximum: maximum), expected)
    }
  }
}
