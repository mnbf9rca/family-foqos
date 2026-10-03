import SwiftUI

struct ProfileScheduleRow: View {
  let data: BlockedProfileCardData
  let isActive: Bool

  var scheduleLines: [String] {
    if data.profileSchemaVersion >= 2 {
      var lines: [String] = []
      if data.startTriggers.schedule, let start = data.startSchedule, start.isActive {
        lines.append("Start: \(start.daysText) \(start.formattedTime)")
      }
      if data.stopConditions.schedule, let stop = data.stopSchedule, stop.isActive {
        lines.append("Stop: \(stop.daysText) \(stop.formattedTime)")
      }
      return lines
    }
    guard let schedule = data.schedule, schedule.isActive else { return [] }
    let start = formattedTimeString(hour24: schedule.startHour, minute: schedule.startMinute)
    let end = formattedTimeString(hour24: schedule.endHour, minute: schedule.endMinute)
    return [schedule.days.compactDaysText(), "\(start) - \(end)"]
  }

  var timerDurationMinutes: Int? {
    guard !isActive else { return nil }
    if data.profileSchemaVersion >= 2 {
      guard data.stopConditions.timer, let minutes = data.stopConditions.timerDurationMinutes,
        (DeviceActivityLimits.minimumIntervalMinutes...DeviceActivityLimits.maximumTimerMinutes).contains(minutes)
      else { return nil }
      return minutes
    }
    guard
      [NFCTimerBlockingStrategy.id, QRTimerBlockingStrategy.id, ShortcutTimerBlockingStrategy.id]
        .contains(data.blockingStrategyId ?? ""), let strategyData = data.strategyData
    else { return nil }
    return StrategyTimerData.toStrategyTimerData(from: strategyData).durationInMinutes
  }

  func countdownInterval(now: Date) -> ClosedRange<Date>? {
    guard isActive, let deadline = data.timerEndTime else { return nil }
    return min(now, deadline)...deadline
  }

  private func formattedTimeString(hour24: Int, minute: Int) -> String {
    var hour = hour24 % 12
    if hour == 0 { hour = 12 }
    let isPM = hour24 >= 12
    return "\(hour):\(String(format: "%02d", minute)) \(isPM ? "PM" : "AM")"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      if data.scheduleIsOutOfSync {
        Label("Schedule not registered on this device", systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
      }
      ForEach(scheduleLines, id: \.self) { line in
        Text(line)
      }
      if let interval = countdownInterval(now: Date()) {
        HStack(spacing: 4) {
          Image(systemName: "timer")
          Text(timerInterval: interval, countsDown: true)
            .monospacedDigit()
        }
      } else if let minutes = timerDurationMinutes {
        Text("Duration: \(DateFormatters.formatMinutes(minutes))")
      } else if scheduleLines.isEmpty && !data.scheduleIsOutOfSync {
        Text("No Schedule Set")
      }
    }
    .font(.caption2)
    .foregroundStyle(.secondary)
    .fixedSize(horizontal: false, vertical: true)
    .frame(maxWidth: .infinity, alignment: .leading)
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
