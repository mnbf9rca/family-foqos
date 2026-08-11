import Foundation
import XCTest

@testable import FamilyFoqos

final class LogExportManagerRosterTests: XCTestCase {
  func testGivenNilRoster_WhenStaging_ThenDoesNotCreateRosterFile() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    try LogExportManager.writeFamilyRoster(nil, to: directory, fileManager: .default)

    XCTAssertFalse(
      FileManager.default.fileExists(atPath: directory.appendingPathComponent("roster.txt").path)
    )
  }

  func testGivenRosterContent_WhenStaging_ThenWritesExactUTF8FileIncludingEmptyContent() throws {
    for content in ["child·ABCDEF12 — Emma\n", ""] {
      let directory = try makeTemporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }

      try LogExportManager.writeFamilyRoster(content, to: directory, fileManager: .default)

      XCTAssertEqual(
        try String(
          contentsOf: directory.appendingPathComponent("roster.txt"), encoding: .utf8),
        content
      )
    }
  }

  private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("RosterTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }
}
