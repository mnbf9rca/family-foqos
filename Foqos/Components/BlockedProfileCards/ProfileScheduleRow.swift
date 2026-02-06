import SwiftUI

struct ProfileScheduleRow: View {
  let profile: BlockedProfiles
  let isActive: Bool

  private var hasLegacySchedule: Bool { profile.schedule?.isActive == true }

  private var hasV2Schedule: Bool {
    let hasStart = profile.startTriggers.schedule
      && profile.startSchedule?.isActive == true
    let hasStop = profile.stopConditions.schedule
      && profile.stopSchedule?.isActive == true
    return hasStart || hasStop
  }

  private var hasSchedule: Bool { hasLegacySchedule || hasV2Schedule }

  private var isTimerStrategy: Bool {
    profile.stopConditions.timer
  }

  private var timerDuration: Int? {
    guard let strategyData = profile.strategyData else { return nil }
    let timerData = StrategyTimerData.toStrategyTimerData(from: strategyData)
    return timerData.durationInMinutes
  }

  private var daysLine: String {
    if hasV2Schedule {
      var allDays = Set<Weekday>()
      if let start = profile.startSchedule, profile.startTriggers.schedule {
        allDays.formUnion(start.days)
      }
      if let stop = profile.stopSchedule, profile.stopConditions.schedule {
        allDays.formUnion(stop.days)
      }
      return allDays.sorted { $0.rawValue < $1.rawValue }
        .map { $0.shortLabel }
        .joined(separator: " ")
    }
    guard let schedule = profile.schedule, schedule.isActive else { return "" }
    return schedule.days
      .sorted { $0.rawValue < $1.rawValue }
      .map { $0.shortLabel }
      .joined(separator: " ")
  }

  private var timeLine: String? {
    if hasV2Schedule {
      let startText = profile.startTriggers.schedule
        ? profile.startSchedule?.formattedTime : nil
      let stopText = profile.stopConditions.schedule
        ? profile.stopSchedule?.formattedTime : nil
      if let s = startText, let e = stopText {
        return "\(s) - \(e)"
      } else if let s = startText {
        return "Start: \(s)"
      } else if let e = stopText {
        return "Stop: \(e)"
      }
      return nil
    }
    guard let schedule = profile.schedule, schedule.isActive else { return nil }
    let start = formattedTimeString(hour24: schedule.startHour, minute: schedule.startMinute)
    let end = formattedTimeString(hour24: schedule.endHour, minute: schedule.endMinute)
    return "\(start) - \(end)"
  }

  private func formattedTimeString(hour24: Int, minute: Int) -> String {
    var hour = hour24 % 12
    if hour == 0 { hour = 12 }
    let isPM = hour24 >= 12
    return "\(hour):\(String(format: "%02d", minute)) \(isPM ? "PM" : "AM")"
  }

  var body: some View {
    HStack(spacing: 4) {
      // Icon
      Group {
        if profile.scheduleIsOutOfSync || (hasSchedule && isTimerStrategy) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundColor(.red)
        }
      }
      .font(.body)

      VStack(alignment: .leading, spacing: 2) {
        if profile.scheduleIsOutOfSync {
          Text("Schedule Out of Sync")
            .font(.caption2)
            .lineLimit(2)
            .minimumScaleFactor(0.8)
            .fixedSize(horizontal: false, vertical: true)
        } else if !hasSchedule && isActive && isTimerStrategy {
          Text("Duration")
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundColor(.primary)

          if let duration = timerDuration {
            Text("\(DateFormatters.formatMinutes(duration))")
              .font(.caption2)
              .foregroundColor(.secondary)
          }
        } else if hasSchedule && isTimerStrategy {
          Text("Unstable Profile with Schedule")
            .font(.caption2)
            .lineLimit(2)
            .minimumScaleFactor(0.8)
            .fixedSize(horizontal: false, vertical: true)
        } else if !hasSchedule {
          Text("No Schedule Set")
            .font(.caption)
            .foregroundColor(.secondary)
        } else if hasSchedule {
          Text(daysLine)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundColor(.primary)

          if let timeLine = timeLine {
            Text(timeLine)
              .font(.caption2)
              .foregroundColor(.secondary)
          }
        }
      }

      Spacer(minLength: 0)
    }
  }
}

#Preview {
  VStack(spacing: 20) {
    ProfileScheduleRow(
      profile: BlockedProfiles(
        name: "Test",
        blockingStrategyId: NFCBlockingStrategy.id,
        schedule: .init(
          days: [.monday, .wednesday, .friday],
          startHour: 9,
          startMinute: 0,
          endHour: 17,
          endMinute: 0,
          updatedAt: Date()
        )
      ),
      isActive: false
    )
  }
  .padding()
  .background(Color(.systemGroupedBackground))
}
