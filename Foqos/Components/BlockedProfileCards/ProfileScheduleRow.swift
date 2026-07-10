import SwiftUI

struct ProfileScheduleRow: View {
  let data: BlockedProfileCardData
  let isActive: Bool

  private var hasLegacySchedule: Bool { data.schedule?.isActive == true }

  private var hasV2Schedule: Bool {
    let hasStart =
      data.startTriggers.schedule
      && data.startSchedule?.isActive == true
    let hasStop =
      data.stopConditions.schedule
      && data.stopSchedule?.isActive == true
    return hasStart || hasStop
  }

  private var hasSchedule: Bool { hasLegacySchedule || hasV2Schedule }

  private var isTimerStrategy: Bool {
    if data.stopConditions.timer { return true }
    // Legacy fallback: V1 profiles have nil stopConditionsData, so
    // stopConditions.timer defaults false even for timer strategies.
    if data.profileSchemaVersion < 2 {
      let id = data.blockingStrategyId
      return id == NFCTimerBlockingStrategy.id
        || id == QRTimerBlockingStrategy.id
        || id == ShortcutTimerBlockingStrategy.id
    }
    return false
  }

  private var timerDuration: Int? {
    guard let strategyData = data.strategyData else { return nil }
    let timerData = StrategyTimerData.toStrategyTimerData(from: strategyData)
    return timerData.durationInMinutes
  }

  private var daysLine: String {
    if hasV2Schedule {
      var allDays = Set<Weekday>()
      if let start = data.startSchedule, data.startTriggers.schedule {
        allDays.formUnion(start.days)
      }
      if let stop = data.stopSchedule, data.stopConditions.schedule {
        allDays.formUnion(stop.days)
      }
      return Array(allDays).compactDaysText()
    }
    guard let schedule = data.schedule, schedule.isActive else { return "" }
    return schedule.days
      .compactDaysText()
  }

  private var timeLine: String? {
    if hasV2Schedule {
      let startText =
        data.startTriggers.schedule
        ? data.startSchedule?.formattedTime : nil
      let stopText =
        data.stopConditions.schedule
        ? data.stopSchedule?.formattedTime : nil
      if let s = startText, let e = stopText {
        return "\(s) - \(e)"
      } else if let s = startText {
        return "Start: \(s)"
      } else if let e = stopText {
        return "Stop: \(e)"
      }
      return nil
    }
    guard let schedule = data.schedule, schedule.isActive else { return nil }
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
        if data.scheduleIsOutOfSync || (hasSchedule && isTimerStrategy) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundColor(.red)
        }
      }
      .font(.body)

      VStack(alignment: .leading, spacing: 2) {
        if data.scheduleIsOutOfSync {
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
  let profile = BlockedProfiles(
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
  )

  VStack(spacing: 20) {
    ProfileScheduleRow(
      data: profile.cardData,
      isActive: false
    )
  }
  .padding()
  .background(Color(.systemGroupedBackground))
}
