import XCTest

@testable import FamilyFoqos

final class LogTailTests: XCTestCase {

  func testGivenLogContent_WhenGettingTail_ThenReturnsAtMostNLines() {
    // Given: Log has content
    _ = Log.shared.getLogContent()

    // When: We request tailed content with 10 lines max
    let tailedContent = Log.shared.getLogContentTail(maxLines: 10)

    // Then: Tailed content has at most 10 lines
    let lineCount = tailedContent.components(separatedBy: "\n").filter { !$0.isEmpty }.count
    XCTAssertLessThanOrEqual(lineCount, 10)
  }

  func testGivenRecentLogEntry_WhenGettingTail_ThenPreservesNewestEntries() {
    // Given: We add a unique log entry
    let uniqueMarker = "TAIL_TEST_\(UUID().uuidString)"
    Log.info(uniqueMarker, category: .app)

    // When: We get tailed content (queue.sync drains pending writes)
    let tailedContent = Log.shared.getLogContentTail(maxLines: 100)

    // Then: The newest entry is present
    XCTAssertTrue(tailedContent.contains(uniqueMarker))
  }

  func testGivenZeroMaxLines_WhenGettingTail_ThenReturnsEmpty() {
    // Edge case: requesting zero lines should return empty string
    let tailedContent = Log.shared.getLogContentTail(maxLines: 0)
    XCTAssertEqual(tailedContent, "")
  }

  func testGivenMultipleLogEntries_WhenGettingTail_ThenPreservesChronologicalOrder() {
    // Given: We log multiple entries with identifiable order
    let marker1 = "ORDER_TEST_FIRST_\(UUID().uuidString)"
    let marker2 = "ORDER_TEST_SECOND_\(UUID().uuidString)"
    let marker3 = "ORDER_TEST_THIRD_\(UUID().uuidString)"

    Log.info(marker1, category: .app)
    Log.info(marker2, category: .app)
    Log.info(marker3, category: .app)

    // When: We get tailed content (queue.sync drains pending writes)
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

  func testGivenLoggedEntry_WhenGettingFileURLs_ThenReturnsNonEmpty() {
    // Given: We log something to ensure a file exists
    let marker = "FILE_URL_TEST_\(UUID().uuidString)"
    Log.info(marker, category: .app)

    // When: We get log file URLs (queue.sync drains pending writes)
    let urls = Log.shared.getLogFileURLs()

    // Then: At least one log file exists
    XCTAssertFalse(urls.isEmpty, "Should have at least one log file after logging")
    for url in urls {
      XCTAssertTrue(
        FileManager.default.fileExists(atPath: url.path),
        "Returned URL should point to existing file: \(url.path)")
    }
  }

  func testGivenLoggedEntry_WhenGettingTotalSize_ThenReturnsPositive() {
    // Given: We log something to ensure files have content
    let marker = "SIZE_TEST_\(UUID().uuidString)"
    Log.info(marker, category: .app)

    // When: We get total log size (queue.sync drains pending writes)
    let size = Log.shared.getTotalLogSize()

    // Then: Size is positive
    XCTAssertGreaterThan(size, 0, "Total log size should be positive after logging")
  }

  func testGivenLogFiles_WhenCopyingToStaging_ThenCopiesAllFiles() throws {
    // Given: We log something to ensure files exist
    let marker = "COPY_TEST_\(UUID().uuidString)"
    Log.info(marker, category: .app)

    let stagingDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("LogCopyTest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: stagingDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: stagingDir) }

    // Capture the count of log files before copying
    let originalCount = Log.shared.getLogFileURLs().count

    // When: We copy log files to staging (queue.sync drains pending writes first)
    try Log.shared.copyLogFilesToStagingDirectory(stagingDir)

    // Then: All log files were copied
    let copiedFiles = try FileManager.default.contentsOfDirectory(
      at: stagingDir, includingPropertiesForKeys: nil)
    XCTAssertFalse(copiedFiles.isEmpty, "Should have copied at least one log file")
    XCTAssertEqual(
      copiedFiles.count,
      originalCount,
      "Number of copied log files should match the number of existing log files"
    )

    // And: copied files contain our marker
    let hasMarker = copiedFiles.contains { url in
      (try? String(contentsOf: url, encoding: .utf8))?.contains(marker) == true
    }
    XCTAssertTrue(hasMarker, "Copied files should contain the logged marker")
  }

  func testGivenDestinationCollision_WhenCopyingToStaging_ThenThrows() throws {
    let marker = "COPY_COLLISION_TEST_\(UUID().uuidString)"
    Log.info(marker, category: .app)

    guard let source = Log.shared.getLogFileURLs().first else {
      XCTFail("Expected at least one log file")
      return
    }

    let stagingDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("LogCopyCollisionTest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: stagingDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: stagingDir) }

    let collision = stagingDir.appendingPathComponent(Log.stagingDestinationName(for: source))
    try "existing".write(to: collision, atomically: true, encoding: .utf8)

    XCTAssertThrowsError(try Log.shared.copyLogFilesToStagingDirectory(stagingDir))
  }
}
