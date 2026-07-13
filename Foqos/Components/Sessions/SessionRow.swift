import Foundation
import SwiftUI

// REGRESSION GUARD (#298): SessionRow accepts ONLY this value type - it can no longer hold a live
// BlockedProfileSession @Model, so a re-render can never read a vacated store row.
struct SessionRowData {
  let startTime: Date
  let endTime: Date?
  let breakStartTime: Date?
  let breakEndTime: Date?
  let isActive: Bool
  let durationSeconds: TimeInterval

  var formattedDate: String {
    let calendar = Calendar.current
    if calendar.isDateInToday(startTime) {
      return "Today"
    } else if calendar.isDateInYesterday(startTime) {
      return "Yesterday"
    }

    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter.string(from: startTime)
  }

  var formattedStartTime: String {
    startTime.formatted(date: .omitted, time: .shortened)
  }

  var formattedEndTime: String? {
    endTime?.formatted(date: .omitted, time: .shortened)
  }

  var timeRangeText: String {
    if let endTimeText = formattedEndTime {
      return "\(formattedStartTime) → \(endTimeText)"
    }

    return "Started \(formattedStartTime)"
  }

  var breakRangeText: String? {
    guard let breakStartTime else {
      return nil
    }

    let breakStartText = breakStartTime.formatted(date: .omitted, time: .shortened)

    if let breakEndTime {
      let breakEndText = breakEndTime.formatted(date: .omitted, time: .shortened)
      return "Break \(breakStartText) → \(breakEndText)"
    }

    return isActive ? "Break \(breakStartText) (ongoing)" : "Break \(breakStartText)"
  }

  var formattedDuration: String {
    let minutes = Int(durationSeconds) / 60
    let hours = minutes / 60
    let remainingMinutes = minutes % 60

    if hours > 0 {
      return "\(hours)h \(remainingMinutes)m"
    }

    return "\(minutes)m"
  }
}

extension BlockedProfileSession {
  /// Build the row snapshot. MUST be called only on a valid (non-zombie) model - callers gate
  /// via `SafeModelView` before invoking. Reads live attributes/relationships.
  ///
  /// TRIPWIRE (#298 edit-propagation): this MUST be evaluated inside an observation-tracked
  /// SwiftUI body (SessionRow's `SafeModelView` content closure). Those tracked reads register
  /// the `@Observable` dependencies that make a legitimate edit rebuild the snapshot. Do NOT
  /// memoize it, cache it on the model, or move the call into an `init` / stored property / out of
  /// the render path - that silently stops the row updating on edits while still compiling and
  /// passing the zombie test. Verified by
  /// `testGivenSessionRowDataThenModelDeletedAndSaved_ThenValuesStillReadableNoTrap` and the
  /// device-gate edit step.
  var sessionRowData: SessionRowData {
    SessionRowData(
      startTime: startTime,
      endTime: endTime,
      breakStartTime: breakStartTime,
      breakEndTime: breakEndTime,
      isActive: isActive,
      durationSeconds: duration()
    )
  }
}

struct SessionRow: View {
  @EnvironmentObject private var themeManager: ThemeManager

  let data: SessionRowData

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(data.formattedDate)
          .font(.headline)
          .fontWeight(.semibold)
          .lineLimit(1)

        Spacer(minLength: 8)

        HStack(spacing: 4) {
          Image(systemName: "clock")
            .font(.caption)
          Text(data.formattedDuration)
            .monospacedDigit()
        }
        .font(.subheadline)
        .foregroundColor(.secondary)
      }

      HStack(spacing: 6) {
        Image(systemName: "timer")
          .font(.caption)
        Text(data.timeRangeText)
          .monospacedDigit()
      }
      .font(.subheadline)
      .foregroundColor(.secondary)

      if let breakText = data.breakRangeText {
        HStack(spacing: 6) {
          Image(systemName: "cup.and.saucer")
            .font(.caption)
          Text(breakText)
            .font(.caption)
            .foregroundColor(.secondary)
            .monospacedDigit()
            .lineLimit(1)
        }
      }
    }
    .padding(.vertical, 6)
  }
}
