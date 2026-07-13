import Foundation
import OSLog

/// Log levels for the privacy-focused logging framework
public enum LogLevel: Int, Comparable, Codable {
  case debug = 0
  case info = 1
  case warning = 2
  case error = 3

  public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
    return lhs.rawValue < rhs.rawValue
  }

  public var prefix: String {
    switch self {
    case .debug: return "DEBUG"
    case .info: return "INFO"
    case .warning: return "WARNING"
    case .error: return "ERROR"
    }
  }

  public var osLogType: OSLogType {
    switch self {
    case .debug: return .debug
    case .info: return .info
    case .warning: return .default
    case .error: return .error
    }
  }
}

/// Categories for organizing log output
public enum LogCategory: String, CaseIterable {
  case app = "App"
  case cloudKit = "CloudKit"
  case sync = "Sync"
  case strategy = "Strategy"
  case session = "Session"
  case ui = "UI"
  case location = "Location"
  case nfc = "NFC"
  case timer = "Timer"
  case authorization = "Authorization"
  case liveActivity = "LiveActivity"
  case familyControls = "FamilyControls"
}

/// A single log entry with timestamp, level, category, and message
public struct LogEntry: Codable, Identifiable {
  public let id: UUID
  public let timestamp: Date
  public let level: LogLevel
  public let category: String
  public let message: String
  public let file: String
  public let function: String
  public let line: Int

  public init(
    level: LogLevel,
    category: String,
    message: String,
    file: String,
    function: String,
    line: Int
  ) {
    self.id = UUID()
    self.timestamp = Date()
    self.level = level
    self.category = category
    self.message = message
    self.file = (file as NSString).lastPathComponent
    self.function = function
    self.line = line
  }

  public var formattedString: String {
    let dateFormatter = ISO8601DateFormatter()
    dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let timestamp = dateFormatter.string(from: self.timestamp)
    return "[\(timestamp)] [\(level.prefix)] [\(category)] \(file):\(line) \(function) - \(message)"
  }
}

/// Privacy-focused logging framework with file persistence and export capabilities
public final class Log: @unchecked Sendable {  // SAFETY: entries/file I/O protected by serial queue; minimumLevel/fileLoggingEnabled are immutable
  public static let shared = Log()

  private let queue = DispatchQueue(label: "com.cynexia.family-foqos.log", qos: .utility)
  private var entries: [LogEntry] = []
  private let maxEntriesInMemory = 1000
  private let maxLogFileSize = 5 * 1024 * 1024  // 5MB per file
  private let maxLogFiles = 5

  private let osLog: OSLog
  private let fileManager = FileManager.default

  /// Minimum log level to record
  public let minimumLevel: LogLevel = .debug

  /// Whether to persist logs to file
  public let fileLoggingEnabled: Bool = true

  // MARK: - Per-process log file naming (#250)

  public static let appGroupIdentifier = "group.com.cynexia.family-foqos"
  private static let processLogTag = logBaseName(forBundleIdentifier: Bundle.main.bundleIdentifier)

  /// #250: a distinct per-process basename tag so app/extensions never write to the same file.
  public static func logBaseName(forBundleIdentifier bundleID: String?) -> String {
    guard let bundleID, !bundleID.isEmpty else { return "app" }
    if bundleID.hasSuffix(".FoqosDeviceMonitor") { return "monitor" }
    if bundleID.hasSuffix(".FoqosWidget") { return "widget" }
    if bundleID.hasSuffix(".FoqosShieldConfig") { return "shield" }
    if bundleID == "com.cynexia.family-foqos" { return "app" }
    return bundleID.lowercased()
      .replacingOccurrences(of: ".", with: "-")
      .replacingOccurrences(of: "_", with: "-")
      .replacingOccurrences(of: "/", with: "-")
  }

  /// #250: every per-process log file in the shared directory, newest-first with a stable tie-break.
  public static func allLogFileURLs(inDirectory dir: URL, using fileManager: FileManager) -> [URL] {
    guard
      let entries = try? fileManager.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
    else { return [] }

    let logFiles = entries.filter {
      $0.lastPathComponent.hasPrefix("foqos-") && $0.pathExtension == "log"
    }
    return logFiles.sorted { lhs, rhs in
      let lhsDate =
        (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        ?? .distantPast
      let rhsDate =
        (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        ?? .distantPast
      if lhsDate != rhsDate { return lhsDate > rhsDate }
      return lhs.lastPathComponent < rhs.lastPathComponent
    }
  }

  /// #250: staging destination name = already-unique per-process basename.
  public static func stagingDestinationName(for fileURL: URL) -> String {
    fileURL.lastPathComponent
  }

  private var logDirectory: URL? {
    let baseDir: URL
    if let container = fileManager.containerURL(
      forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier)
    {
      baseDir = container
    } else if let appSupport = fileManager.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first {
      baseDir = appSupport
    } else {
      return nil
    }

    let logsDir = baseDir.appendingPathComponent("Logs", isDirectory: true)
    if !fileManager.fileExists(atPath: logsDir.path) {
      try? fileManager.createDirectory(at: logsDir, withIntermediateDirectories: true)
    }
    return logsDir
  }

  private var currentLogFile: URL? {
    logDirectory?.appendingPathComponent("foqos-\(Self.processLogTag).log")
  }

  private init() {
    self.osLog = OSLog(subsystem: "com.cynexia.family-foqos", category: "App")
    loadRecentEntries()
  }

  // MARK: - Public Logging Methods

  public static func debug(
    _ message: String,
    category: LogCategory = .app,
    file: String = #file,
    function: String = #function,
    line: Int = #line
  ) {
    shared.log(
      level: .debug, category: category.rawValue, message: message, file: file, function: function,
      line: line)
  }

  public static func info(
    _ message: String,
    category: LogCategory = .app,
    file: String = #file,
    function: String = #function,
    line: Int = #line
  ) {
    shared.log(
      level: .info, category: category.rawValue, message: message, file: file, function: function,
      line: line)
  }

  public static func warning(
    _ message: String,
    category: LogCategory = .app,
    file: String = #file,
    function: String = #function,
    line: Int = #line
  ) {
    shared.log(
      level: .warning, category: category.rawValue, message: message, file: file,
      function: function, line: line)
  }

  public static func error(
    _ message: String,
    category: LogCategory = .app,
    file: String = #file,
    function: String = #function,
    line: Int = #line
  ) {
    shared.log(
      level: .error, category: category.rawValue, message: message, file: file, function: function,
      line: line)
  }

  // MARK: - Core Logging

  private func log(
    level: LogLevel,
    category: String,
    message: String,
    file: String,
    function: String,
    line: Int
  ) {
    guard level >= minimumLevel else { return }

    let entry = LogEntry(
      level: level,
      category: category,
      message: message,
      file: file,
      function: function,
      line: line
    )

    queue.async { [weak self] in
      self?.processEntry(entry)
    }
  }

  private func processEntry(_ entry: LogEntry) {
    // Add to in-memory buffer
    entries.append(entry)
    if entries.count > maxEntriesInMemory {
      entries.removeFirst(entries.count - maxEntriesInMemory)
    }

    // OSLog integration
    os_log("%{public}@", log: osLog, type: entry.level.osLogType, entry.formattedString)

    // File persistence
    if fileLoggingEnabled {
      writeToFile(entry)
    }
  }

  // MARK: - File Operations

  private func writeToFile(_ entry: LogEntry) {
    guard let logFile = currentLogFile else { return }

    let line = entry.formattedString + "\n"
    guard let data = line.data(using: .utf8) else { return }

    if fileManager.fileExists(atPath: logFile.path) {
      // Check file size and rotate if needed
      if let attributes = try? fileManager.attributesOfItem(atPath: logFile.path),
        let size = attributes[.size] as? Int,
        size > maxLogFileSize
      {
        rotateLogFiles()
      }

      // Append to existing file
      if let handle = try? FileHandle(forWritingTo: logFile) {
        handle.seekToEndOfFile()
        handle.write(data)
        handle.closeFile()
      }
    } else {
      // Create new file
      try? data.write(to: logFile)
    }
  }

  private func rotateLogFiles() {
    guard let logDir = logDirectory, let currentFile = currentLogFile else { return }
    let tag = Self.processLogTag

    // Remove oldest if at max
    for i in stride(from: maxLogFiles - 1, through: 1, by: -1) {
      let oldFile = logDir.appendingPathComponent("foqos-\(tag).\(i).log")
      let newFile = logDir.appendingPathComponent("foqos-\(tag).\(i + 1).log")
      if fileManager.fileExists(atPath: oldFile.path) {
        if i == maxLogFiles - 1 {
          try? fileManager.removeItem(at: oldFile)
        } else {
          try? fileManager.moveItem(at: oldFile, to: newFile)
        }
      }
    }

    // Move current to .1
    let rotatedFile = logDir.appendingPathComponent("foqos-\(tag).1.log")
    try? fileManager.moveItem(at: currentFile, to: rotatedFile)
  }

  private func loadRecentEntries() {
    // Load recent entries from file on init (optional, for export)
    // Entries are primarily reconstructed during export
  }

  // MARK: - Export Functions

  /// Get all in-memory log entries
  public func getEntries() -> [LogEntry] {
    return queue.sync { entries }
  }

  /// Get all log file URLs (every process's files in the shared container) — MUST be called from
  /// within `queue` (or `queue.sync`).
  private func _getLogFileURLsUnsafe() -> [URL] {
    guard let logDir = logDirectory else { return [] }
    return Self.allLogFileURLs(inDirectory: logDir, using: fileManager)
  }

  /// Get all log file URLs for export (thread-safe)
  public func getLogFileURLs() -> [URL] {
    return queue.sync { _getLogFileURLsUnsafe() }
  }

  /// Copy all log files to a staging directory as a consistent snapshot.
  /// Runs within the serial queue so no rotation can occur mid-copy, but does
  /// not provide an all-or-nothing filesystem transaction if a copy fails.
  /// - Parameter stagingDir: Destination directory (must already exist).
  public func copyLogFilesToStagingDirectory(_ stagingDir: URL) throws {
    queue.sync {
      let urls = _getLogFileURLsUnsafe()
      for url in urls {
        let destURL = stagingDir.appendingPathComponent(Self.stagingDestinationName(for: url))
        // #250 best-effort: sibling processes can rotate/remove their own files between
        // enumeration and copy. Skip a vanished file rather than abort the whole export.
        try? fileManager.copyItem(at: url, to: destURL)
      }
    }
  }

  /// Get combined log content as a string
  public func getLogContent() -> String {
    return queue.sync {
      let urls = _getLogFileURLsUnsafe().reversed()  // Oldest first
      var content = ""

      for url in urls {
        if let fileContent = try? String(contentsOf: url, encoding: .utf8) {
          content += fileContent
        }
      }

      return content
    }
  }

  /// Get tailed log content (last N lines) for preview - avoids loading massive logs
  public func getLogContentTail(maxLines: Int) -> String {
    guard maxLines > 0 else { return "" }

    return queue.sync {
      let urls = _getLogFileURLsUnsafe()  // Current file first, then rotated
      var collectedLines: [String] = []

      // Read files newest-first, stop when we have enough lines
      for url in urls {
        guard collectedLines.count < maxLines else { break }

        guard let fileContent = try? String(contentsOf: url, encoding: .utf8) else { continue }

        let lines = fileContent.components(separatedBy: "\n").filter { !$0.isEmpty }
        let neededLines = maxLines - collectedLines.count

        if lines.count <= neededLines {
          // Prepend all lines from this file (older content goes first)
          collectedLines.insert(contentsOf: lines, at: 0)
        } else {
          // Take only the last neededLines from this file
          let tailLines = Array(lines.suffix(neededLines))
          collectedLines.insert(contentsOf: tailLines, at: 0)
        }
      }

      // Return most recent lines (last maxLines)
      let result = Array(collectedLines.suffix(maxLines))
      return result.joined(separator: "\n")
    }
  }

  /// Clear all log files and in-memory entries
  public func clearLogs() {
    queue.async { [weak self] in
      self?.entries.removeAll()

      guard let logDir = self?.logDirectory else { return }

      if let files = try? self?.fileManager.contentsOfDirectory(
        at: logDir, includingPropertiesForKeys: nil)
      {
        for file in files where file.pathExtension == "log" {
          try? self?.fileManager.removeItem(at: file)
        }
      }
    }
  }

  /// Get total size of all log files (thread-safe)
  public func getTotalLogSize() -> Int {
    return queue.sync {
      let urls = _getLogFileURLsUnsafe()
      var totalSize = 0

      for url in urls {
        if let attributes = try? fileManager.attributesOfItem(atPath: url.path),
          let size = attributes[.size] as? Int
        {
          totalSize += size
        }
      }

      return totalSize
    }
  }
}
