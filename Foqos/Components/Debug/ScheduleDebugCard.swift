import SwiftUI

struct ScheduleDebugCard: View {
  let schedule: BlockedProfileSchedule?
  let startSchedule: ProfileScheduleTime?
  let stopSchedule: ProfileScheduleTime?
  let startTriggersSchedule: Bool
  let stopConditionsSchedule: Bool

  init(
    schedule: BlockedProfileSchedule? = nil,
    startSchedule: ProfileScheduleTime? = nil,
    stopSchedule: ProfileScheduleTime? = nil,
    startTriggersSchedule: Bool = false,
    stopConditionsSchedule: Bool = false
  ) {
    self.schedule = schedule
    self.startSchedule = startSchedule
    self.stopSchedule = stopSchedule
    self.startTriggersSchedule = startTriggersSchedule
    self.stopConditionsSchedule = stopConditionsSchedule
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      // V2 Schedule Info
      if startTriggersSchedule || stopConditionsSchedule {
        Group {
          DebugRow(label: "V2 Start Trigger", value: "\(startTriggersSchedule)")
          DebugRow(label: "V2 Stop Condition", value: "\(stopConditionsSchedule)")
        }

        if let start = startSchedule, startTriggersSchedule {
          Divider()
          Group {
            DebugRow(label: "Start Schedule Active", value: "\(start.isActive)")
            DebugRow(label: "Start Time", value: start.formattedTime)
            DebugRow(label: "Start Days", value: start.daysText)
            DebugRow(label: "Start Updated At", value: DateFormatters.formatDate(start.updatedAt))
            DebugRow(label: "Start Today Scheduled", value: "\(start.isTodayScheduled())")
            DebugRow(label: "Start Older Than 15m", value: "\(start.olderThan15Minutes())")
          }
        }

        if let stop = stopSchedule, stopConditionsSchedule {
          Divider()
          Group {
            DebugRow(label: "Stop Schedule Active", value: "\(stop.isActive)")
            DebugRow(label: "Stop Time", value: stop.formattedTime)
            DebugRow(label: "Stop Days", value: stop.daysText)
            DebugRow(label: "Stop Updated At", value: DateFormatters.formatDate(stop.updatedAt))
            DebugRow(label: "Stop Today Scheduled", value: "\(stop.isTodayScheduled())")
          }
        }
      }

      // Legacy Schedule Info
      if let schedule = schedule {
        if startTriggersSchedule || stopConditionsSchedule {
          Divider()
          DebugRow(label: "Legacy Schedule", value: "")
        }

        Group {
          DebugRow(label: "Is Active", value: "\(schedule.isActive)")
          DebugRow(label: "Summary", value: schedule.summaryText)
          DebugRow(label: "Updated At", value: DateFormatters.formatDate(schedule.updatedAt))
        }

        Divider()

        Group {
          DebugRow(
            label: "Days",
            value: schedule.days.map { $0.name }.joined(separator: ", ")
          )
          DebugRow(
            label: "Start Time",
            value: "\(schedule.startHour):\(String(format: "%02d", schedule.startMinute))"
          )
          DebugRow(
            label: "End Time",
            value: "\(schedule.endHour):\(String(format: "%02d", schedule.endMinute))"
          )
          DebugRow(label: "Duration (seconds)", value: "\(schedule.totalDurationInSeconds)")
        }

        Divider()

        Group {
          DebugRow(label: "Is Today Scheduled", value: "\(schedule.isTodayScheduled())")
          DebugRow(label: "Older Than 15 Minutes", value: "\(schedule.olderThan15Minutes())")
        }
      }

      if schedule == nil && !startTriggersSchedule && !stopConditionsSchedule {
        Text("No schedule configured")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}

#Preview {
  ScheduleDebugCard(
    schedule: BlockedProfileSchedule(
      days: [.monday, .tuesday, .wednesday, .thursday, .friday],
      startHour: 9,
      startMinute: 0,
      endHour: 17,
      endMinute: 30,
      updatedAt: Date()
    )
  )
  .padding()
}

#Preview("V2 Schedule") {
  ScheduleDebugCard(
    startSchedule: ProfileScheduleTime(
      days: [.monday, .wednesday, .friday],
      hour: 9, minute: 0, updatedAt: Date()
    ),
    stopSchedule: ProfileScheduleTime(
      days: [.monday, .wednesday, .friday],
      hour: 17, minute: 0, updatedAt: Date()
    ),
    startTriggersSchedule: true,
    stopConditionsSchedule: true
  )
  .padding()
}
