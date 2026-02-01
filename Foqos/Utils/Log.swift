import Foundation
import OSLog

/// Log levels for the privacy-focused logging framework
enum LogLevel: Int, Comparable, Codable {
  case debug = 0
  case info = 1
  case warning = 2
  case error = 3

  static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
    return lhs.rawValue < rhs.rawValue
  }

  var prefix: String {
    switch self {
    case .debug: return "DEBUG"
    case .info: return "INFO"
    case .warning: return "WARNING"
    case .error: return "ERROR"
    }
  }

  var osLogType: OSLogType {
    switch self {
    case .debug: return .debug
    case .info: return .info
    case .warning: return .default
    case .error: return .error
    }
  }
}

/// Categories for organizing log output
enum LogCategory: String, CaseIterable {
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
struct LogEntry: Codable, Identifiable {
  let id: UUID
  let timestamp: Date
  let level: LogLevel
  let category: String
  let message: String
  let file: String
  let function: String
  let line: Int

  init(
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

  var formattedString: String {
    let dateFormatter = ISO8601DateFormatter()
    dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let timestamp = dateFormatter.string(from: self.timestamp)
    return "[\(timestamp)] [\(level.prefix)] [\(category)] \(file):\(line) \(function) - \(message)"
  }
}

/// Privacy-focused logging framework with file persistence and export capabilities
final class Log {
  static let shared = Log()

  private let queue = DispatchQueue(label: "com.cynexia.family-foqos.log", qos: .utility)
  private var entries: [LogEntry] = []
  private let maxEntriesInMemory = 1000
  private let maxLogFileSize = 5 * 1024 * 1024  // 5MB per file
  private let maxLogFiles = 5

  private let osLog: OSLog
  private let fileManager = FileManager.default

  /// Minimum log level to record (configurable)
  var minimumLevel: LogLevel = .debug

  /// Whether to also output to console (print)
  var consoleOutputEnabled: Bool = true

  /// Whether to persist logs to file
  var fileLoggingEnabled: Bool = true

  private var logDirectory: URL? {
    guard
      let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first
    else {
      return nil
    }
    let logsDir = appSupport.appendingPathComponent("Logs", isDirectory: true)
    if !fileManager.fileExists(atPath: logsDir.path) {
      try? fileManager.createDirectory(at: logsDir, withIntermediateDirectories: true)
    }
    return logsDir
  }

  private var currentLogFile: URL? {
    logDirectory?.appendingPathComponent("foqos.log")
  }

  private init() {
    self.osLog = OSLog(subsystem: "com.cynexia.family-foqos", category: "App")
    loadRecentEntries()
  }

  // MARK: - Public Logging Methods

  static func debug(
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

  static func info(
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

  static func warning(
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

  static func error(
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

    // Console output
    if consoleOutputEnabled {
      print(entry.formattedString)
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

    // Remove oldest if at max
    for i in stride(from: maxLogFiles - 1, through: 1, by: -1) {
      let oldFile = logDir.appendingPathComponent("foqos.\(i).log")
      let newFile = logDir.appendingPathComponent("foqos.\(i + 1).log")
      if fileManager.fileExists(atPath: oldFile.path) {
        if i == maxLogFiles - 1 {
          try? fileManager.removeItem(at: oldFile)
        } else {
          try? fileManager.moveItem(at: oldFile, to: newFile)
        }
      }
    }

    // Move current to .1
    let rotatedFile = logDir.appendingPathComponent("foqos.1.log")
    try? fileManager.moveItem(at: currentFile, to: rotatedFile)
  }

  private func loadRecentEntries() {
    // Load recent entries from file on init (optional, for export)
    // Entries are primarily reconstructed during export
  }

  // MARK: - Export Functions

  /// Get all in-memory log entries
  func getEntries() -> [LogEntry] {
    return queue.sync { entries }
  }

  /// Get all log file URLs for export
  func getLogFileURLs() -> [URL] {
    guard let logDir = logDirectory else { return [] }

    var urls: [URL] = []

    if let currentFile = currentLogFile, fileManager.fileExists(atPath: currentFile.path) {
      urls.append(currentFile)
    }

    for i in 1..<maxLogFiles {
      let rotatedFile = logDir.appendingPathComponent("foqos.\(i).log")
      if fileManager.fileExists(atPath: rotatedFile.path) {
        urls.append(rotatedFile)
      }
    }

    return urls
  }

  /// Get combined log content as a string
  func getLogContent() -> String {
    let urls = getLogFileURLs().reversed()  // Oldest first
    var content = ""

    for url in urls {
      if let fileContent = try? String(contentsOf: url, encoding: .utf8) {
        content += fileContent
      }
    }

    return content
  }

  /// Get tailed log content (last N lines) for preview - avoids loading massive logs
  func getLogContentTail(maxLines: Int) -> String {
    guard maxLines > 0 else { return "" }

    let urls = getLogFileURLs()  // Current file first, then rotated
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

  /// Clear all log files and in-memory entries
  func clearLogs() {
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

  /// Get total size of all log files
  func getTotalLogSize() -> Int {
    let urls = getLogFileURLs()
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
