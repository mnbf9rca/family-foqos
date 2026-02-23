import Foundation
import SwiftData

enum DataExportSortDirection: Hashable {
  case ascending
  case descending
}

enum DataExportTimeZone: Hashable {
  case utc
  case local
}

struct DataExporter {
  static func exportSessionsCSV(
    forProfileIDs profileIDs: [UUID],
    in context: ModelContext,
    sortDirection: DataExportSortDirection = .ascending,
    timeZone: DataExportTimeZone = .utc
  ) throws -> String {
    var lines: [String] = [
      "session_id,profile_name,start_time,end_time,break_start_time,break_end_time"
    ]

    if profileIDs.isEmpty {
      return lines.joined(separator: "\n")
    }

    let order: SortOrder = (sortDirection == .ascending) ? .forward : .reverse
    let descriptor = FetchDescriptor<BlockedProfileSession>(
      predicate: #Predicate { session in
        profileIDs.contains(session.blockedProfile.id)
      },
      sortBy: [SortDescriptor(\.startTime, order: order)]
    )

    let sessions = try context.fetch(descriptor)

    let dateFormatter = makeISO8601Formatter(timeZone: timeZone)
    lines.reserveCapacity(sessions.count + 1)
    for session in sessions {
      let id = session.id
      let profileName = session.blockedProfile.name
      let start = dateFormatter.string(from: session.startTime)
      let end = session.endTime.map { dateFormatter.string(from: $0) } ?? ""
      let breakStart = session.breakStartTime.map { dateFormatter.string(from: $0) } ?? ""
      let breakEnd = session.breakEndTime.map { dateFormatter.string(from: $0) } ?? ""

      let row = [id, profileName, start, end, breakStart, breakEnd]
        .map { escapeCSVField($0) }
        .joined(separator: ",")
      lines.append(row)
    }

    return lines.joined(separator: "\n")
  }

  static func escapeCSVField(_ field: String) -> String {
    var field = field
    if let first = field.first, "=+-@".contains(first) {
      field = "\t" + field
    }
    // Swift treats \r\n as a single grapheme cluster, so contains("\n") misses CRLF pairs.
    // All three checks are needed: \n (standalone LF), \r\n (CRLF pair), \r (standalone CR).
    if field.contains(",") || field.contains("\"") || field.contains("\n")
      || field.contains("\r\n") || field.contains("\r")
    {
      let escaped = field.replacingOccurrences(of: "\"", with: "\"\"")
      return "\"\(escaped)\""
    }
    return field
  }

  private static func makeISO8601Formatter(timeZone: DataExportTimeZone) -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    switch timeZone {
    case .utc:
      formatter.timeZone = TimeZone(secondsFromGMT: 0)
    case .local:
      formatter.timeZone = .current
    }
    return formatter
  }
}
