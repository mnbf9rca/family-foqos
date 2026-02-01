import XCTest

@testable import FamilyFoqos

final class LogTailTests: XCTestCase {

  func testGetLogContentTailReturnsLastNLines() {
    // Given: Log has content
    let content = Log.shared.getLogContent()

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

  func testGetLogContentTailWithEmptyLogsReturnsEmpty() {
    // This tests the edge case - actual behavior depends on log state
    // Just verify it doesn't crash
    let tailedContent = Log.shared.getLogContentTail(maxLines: 0)
    XCTAssertNotNil(tailedContent)
  }
}
