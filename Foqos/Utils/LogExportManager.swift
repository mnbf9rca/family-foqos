import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Manages log export, compression, and sharing
final class LogExportManager {
  static let shared = LogExportManager()

  private let fileManager = FileManager.default

  private init() {}

  /// Create a zip archive of all log files
  func createLogArchive() throws -> URL {
    let tempDir = fileManager.temporaryDirectory
    let archiveName = "FamilyFoqos-Logs-\(formattedTimestamp()).zip"
    let archiveURL = tempDir.appendingPathComponent(archiveName)

    // Remove existing archive if present
    if fileManager.fileExists(atPath: archiveURL.path) {
      try fileManager.removeItem(at: archiveURL)
    }

    let logURLs = Log.shared.getLogFileURLs()
    guard !logURLs.isEmpty else {
      throw LogExportError.noLogsAvailable
    }

    // Create a temporary directory for the logs to zip
    let stagingDir = tempDir.appendingPathComponent("LogExportStaging-\(UUID().uuidString)")
    try fileManager.createDirectory(at: stagingDir, withIntermediateDirectories: true)
    defer {
      try? fileManager.removeItem(at: stagingDir)
    }

    // Copy log files to staging
    for (index, url) in logURLs.enumerated() {
      let destName = index == 0 ? "foqos-current.log" : "foqos-\(index).log"
      let destURL = stagingDir.appendingPathComponent(destName)
      try fileManager.copyItem(at: url, to: destURL)
    }

    // Add device info file
    let deviceInfo = generateDeviceInfo()
    let deviceInfoURL = stagingDir.appendingPathComponent("device-info.txt")
    try deviceInfo.write(to: deviceInfoURL, atomically: true, encoding: .utf8)

    // Create zip archive (returns actual URL, which may be .txt if fallback is used)
    let actualArchiveURL = try createZipArchive(from: stagingDir, to: archiveURL)

    return actualArchiveURL
  }

  /// Generate device and app info for debugging context
  private func generateDeviceInfo() -> String {
    let device = UIDevice.current
    let bundle = Bundle.main

    let info = """
      Family Foqos Log Export
      =======================
      Generated: \(ISO8601DateFormatter().string(from: Date()))

      App Info:
      - Version: \(bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown")
      - Build: \(bundle.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown")
      - Bundle ID: \(bundle.bundleIdentifier ?? "Unknown")

      Device Info:
      - Model: \(device.model)
      - System: \(device.systemName) \(device.systemVersion)
      - Name: [REDACTED FOR PRIVACY]

      Log Statistics:
      - Total Size: \(ByteCountFormatter.string(fromByteCount: Int64(Log.shared.getTotalLogSize()), countStyle: .file))
      - File Count: \(Log.shared.getLogFileURLs().count)

      """

    return info
  }

  private func formattedTimestamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd-HHmmss"
    return formatter.string(from: Date())
  }

  /// Create zip using Cocoa compression
  /// Returns the actual URL of the created archive (may differ from archiveURL if fallback is used)
  private func createZipArchive(from sourceDir: URL, to archiveURL: URL) throws -> URL {
    // Use NSFileCoordinator for zip creation (available on iOS)
    let coordinator = NSFileCoordinator()
    var coordinatorError: NSError?
    var copySucceeded = false

    coordinator.coordinate(
      readingItemAt: sourceDir,
      options: .forUploading,
      error: &coordinatorError
    ) { zipURL in
      do {
        try fileManager.copyItem(at: zipURL, to: archiveURL)
        copySucceeded = true
      } catch {
        Log.warning("Failed to copy zip file: \(error.localizedDescription)", category: .app)
      }
    }

    if coordinatorError != nil || !copySucceeded {
      // Fallback: create combined text file if zip fails
      let txtURL = try createCombinedLogFile(from: sourceDir, to: archiveURL)
      Log.warning(
        "Zip creation failed, using combined text fallback: \(coordinatorError?.localizedDescription ?? "copy failed")",
        category: .app)
      return txtURL
    }

    return archiveURL
  }

  /// Fallback: combine all logs into a single text file
  /// Returns the URL of the created text file
  private func createCombinedLogFile(from sourceDir: URL, to destURL: URL) throws -> URL {
    var combined = ""

    let files = try fileManager.contentsOfDirectory(at: sourceDir, includingPropertiesForKeys: nil)
    for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
      combined += "=== \(file.lastPathComponent) ===\n"
      if let content = try? String(contentsOf: file, encoding: .utf8) {
        combined += content
      }
      combined += "\n\n"
    }

    // Change extension to .txt for combined file
    let txtURL = destURL.deletingPathExtension().appendingPathExtension("txt")
    try combined.write(to: txtURL, atomically: true, encoding: .utf8)
    return txtURL
  }

  /// Present share sheet with log archive
  func shareLogArchive(from viewController: UIViewController? = nil) {
    do {
      let archiveURL = try createLogArchive()
      presentShareSheet(with: [archiveURL], from: viewController)
    } catch {
      Log.error("Failed to create log archive: \(error.localizedDescription)", category: .app)
    }
  }

  /// Present share sheet with items
  private func presentShareSheet(with items: [Any], from viewController: UIViewController?) {
    let activityVC = UIActivityViewController(activityItems: items, applicationActivities: nil)

    // Find the appropriate view controller to present from
    let presenter =
      viewController
      ?? UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap { $0.windows }
        .first { $0.isKeyWindow }?
        .rootViewController

    // Configure for iPad
    if let popover = activityVC.popoverPresentationController {
      popover.sourceView = presenter?.view
      popover.sourceRect = CGRect(
        x: UIScreen.main.bounds.midX, y: UIScreen.main.bounds.midY, width: 0, height: 0)
      popover.permittedArrowDirections = []
    }

    presenter?.present(activityVC, animated: true)
  }

  /// Get a shareable log file for email attachment
  func getShareableLogFile() throws -> URL {
    let tempDir = fileManager.temporaryDirectory
    let fileName = "FamilyFoqos-Logs-\(formattedTimestamp()).txt"
    let fileURL = tempDir.appendingPathComponent(fileName)

    let content = Log.shared.getLogContent()
    let deviceInfo = generateDeviceInfo()

    let fullContent = deviceInfo + "\n\n=== LOG CONTENT ===\n\n" + content

    try fullContent.write(to: fileURL, atomically: true, encoding: .utf8)

    return fileURL
  }
}

enum LogExportError: LocalizedError {
  case noLogsAvailable
  case archiveCreationFailed

  var errorDescription: String? {
    switch self {
    case .noLogsAvailable:
      return "No log files available for export"
    case .archiveCreationFailed:
      return "Failed to create log archive"
    }
  }
}
