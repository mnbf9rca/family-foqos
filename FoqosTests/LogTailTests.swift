import XCTest

@testable import FamilyFoqos

final class LogTailTests: XCTestCase {

  func testGetLogContentTailReturnsLastNLines() {
    // Given: Log has content
    _ = Log.shared.getLogContent()

    // When: We request tailed content with 10 lines max
    let tailedContent = Log.shared.getLogContentTail(maxLines: 10)

    // Then: Tailed content has at most 10 lines
    let lineCount = tailedContent.components(separatedBy: "\n").filter { !$0.isEmpty }.count
    XCTAssertLessThanOrEqual(lineCount, 10)
  }

  func testGetLogContentTailPreservesNewestEntries() {
    // Given: We add a unique log entry
    let uniqueMarker = "TAIL_TEST_\(UUID().uuidString)"
    Log.info(uniqueMarker, category: .app)

    // Allow async write to complete
    let expectation = XCTestExpectation(description: "Log write")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 2.0)

    // When: We get tailed content
    let tailedContent = Log.shared.getLogContentTail(maxLines: 100)

    // Then: The newest entry is present
    XCTAssertTrue(tailedContent.contains(uniqueMarker))
  }

  func testGetLogContentTailWithZeroLinesReturnsEmpty() {
    // Edge case: requesting zero lines should return empty string
    let tailedContent = Log.shared.getLogContentTail(maxLines: 0)
    XCTAssertEqual(tailedContent, "")
  }

  func testGetLogContentTailPreservesChronologicalOrder() {
    // Given: We log multiple entries with identifiable order
    let marker1 = "ORDER_TEST_FIRST_\(UUID().uuidString)"
    let marker2 = "ORDER_TEST_SECOND_\(UUID().uuidString)"
    let marker3 = "ORDER_TEST_THIRD_\(UUID().uuidString)"

    Log.info(marker1, category: .app)
    Log.info(marker2, category: .app)
    Log.info(marker3, category: .app)

    // Allow async writes to complete
    let expectation = XCTestExpectation(description: "Log writes")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 2.0)

    // When: We get tailed content
    let tailedContent = Log.shared.getLogContentTail(maxLines: 100)

    // Then: Entries appear in chronological order (first logged appears before last logged)
    guard let pos1 = tailedContent.range(of: marker1)?.lowerBound,
      let pos2 = tailedContent.range(of: marker2)?.lowerBound,
      let pos3 = tailedContent.range(of: marker3)?.lowerBound
    else {
      XCTFail("Could not find all markers in tailed content")
      return
    }

    XCTAssertLessThan(pos1, pos2, "First entry should appear before second entry")
    XCTAssertLessThan(pos2, pos3, "Second entry should appear before third entry")
  }
}
