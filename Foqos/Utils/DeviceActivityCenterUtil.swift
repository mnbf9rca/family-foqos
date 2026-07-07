import DeviceActivity
import FamilyControls
import ManagedSettings
import SwiftUI

class DeviceActivityCenterUtil {
  static func scheduleTimerActivity(for profile: BlockedProfiles) {
    // Always cancel any existing pre-activation reminders first
    TimersUtil.cancelAllPreActivationReminders(for: profile.id)

    let center = DeviceActivityCenter()
    let scheduleTimerActivity = ScheduleTimerActivity()
    let deviceActivityName = scheduleTimerActivity.getDeviceActivityName(
      from: profile.id.uuidString
    )

    // Determine if we have a V2 start schedule
    let hasV2StartSchedule =
      profile.startTriggers.schedule
      && profile.startSchedule?.isActive == true

    // Legacy fallback: use profile.schedule if V2 start schedule not configured
    let hasLegacySchedule = profile.schedule?.isActive == true

    guard hasV2StartSchedule || hasLegacySchedule else {
      // No start schedule — remove any existing schedule activity
      stopActivities(for: [deviceActivityName], with: center)
      // Still check for stop-only schedule
      scheduleStopActivity(for: profile)
      return
    }

    // Build interval from V2 or legacy
    let intervalStart: DateComponents
    let intervalEnd: DateComponents

    if hasV2StartSchedule {
      let startSched = profile.startSchedule!
      intervalStart = DateComponents(hour: startSched.hour, minute: startSched.minute)

      // For interval end: use V2 stop schedule if available, otherwise use start time + 23:59
      if profile.stopConditions.schedule,
        let stopSched = profile.stopSchedule, stopSched.isActive
      {
        intervalEnd = DateComponents(hour: stopSched.hour, minute: stopSched.minute)
      } else {
        // No scheduled stop — set end to exactly 1 minute before start (full day window)
        if startSched.minute > 0 {
          intervalEnd = DateComponents(hour: startSched.hour, minute: startSched.minute - 1)
        } else {
          intervalEnd = DateComponents(hour: (startSched.hour + 23) % 24, minute: 59)
        }
      }
    } else {
      // Legacy path
      let schedule = profile.schedule!
      intervalStart = DateComponents(hour: schedule.startHour, minute: schedule.startMinute)
      intervalEnd = DateComponents(hour: schedule.endHour, minute: schedule.endMinute)
    }

    let deviceActivitySchedule = DeviceActivitySchedule(
      intervalStart: intervalStart,
      intervalEnd: intervalEnd,
      repeats: true
    )

    do {
      // Remove any existing schedule and create a new one
      stopActivities(for: [deviceActivityName], with: center)
      try center.startMonitoring(deviceActivityName, during: deviceActivitySchedule)
      Log.info("Scheduled restrictions from \(intervalStart) to \(intervalEnd) daily", category: .timer)

      // Schedule pre-activation reminder if enabled
      if hasV2StartSchedule, let startSchedule = profile.startSchedule {
        schedulePreActivationReminderV2(for: profile, startSchedule: startSchedule)
      } else if let schedule = profile.schedule {
        schedulePreActivationReminder(for: profile, schedule: schedule)
      }
    } catch {
      Log.info("Failed to start monitoring: \(error.localizedDescription)", category: .timer)
    }

    // Also register stop-only activity if stop schedule is independent
    scheduleStopActivity(for: profile)
  }

  /// Schedule pre-activation reminder notifications for a legacy-schedule profile
  private static func schedulePreActivationReminder(
    for profile: BlockedProfiles,
    schedule: BlockedProfileSchedule
  ) {
    guard profile.preActivationReminderEnabled else { return }
    guard schedule.isTodayScheduled() else { return }
    schedulePreActivationNotifications(
      for: profile, startHour: schedule.startHour, startMinute: schedule.startMinute
    )
  }

  /// Register a stop-only DeviceActivity for profiles with scheduled stop but no scheduled start.
  /// Uses StopScheduleTimerActivity which fires intervalDidEnd at the stop time.
  static func scheduleStopActivity(for profile: BlockedProfiles) {
    let stopTimerActivity = StopScheduleTimerActivity()
    let deviceActivityName = stopTimerActivity.getDeviceActivityName(
      from: profile.id.uuidString
    )
    let center = DeviceActivityCenter()

    // Only register if stop schedule is active AND start is NOT scheduled
    // (if both are scheduled, ScheduleTimerActivity handles the end via intervalDidEnd)
    let hasScheduledStart =
      profile.startTriggers.schedule
      && profile.startSchedule?.isActive == true
    let hasScheduledStop =
      profile.stopConditions.schedule
      && profile.stopSchedule?.isActive == true

    guard hasScheduledStop && !hasScheduledStart else {
      stopActivities(for: [deviceActivityName], with: center)
      return
    }

    let stopSchedule = profile.stopSchedule!
    let (intervalStart, intervalEnd) = stopScheduleInterval(
      stopHour: stopSchedule.hour, stopMinute: stopSchedule.minute
    )

    let deviceActivitySchedule = DeviceActivitySchedule(
      intervalStart: intervalStart,
      intervalEnd: intervalEnd,
      repeats: true
    )

    do {
      stopActivities(for: [deviceActivityName], with: center)
      try center.startMonitoring(deviceActivityName, during: deviceActivitySchedule)
      Log.info(
        "Scheduled stop-only activity at \(stopSchedule.hour):\(String(format: "%02d", stopSchedule.minute))",
        category: .timer
      )
    } catch {
      Log.error(
        "Failed to schedule stop activity: \(error.localizedDescription)",
        category: .timer
      )
    }
  }

  static func removeStopScheduleActivity(for profile: BlockedProfiles) {
    let stopTimerActivity = StopScheduleTimerActivity()
    let deviceActivityName = stopTimerActivity.getDeviceActivityName(
      from: profile.id.uuidString
    )
    stopActivities(for: [deviceActivityName])
  }

  private static func schedulePreActivationReminderV2(
    for profile: BlockedProfiles,
    startSchedule: ProfileScheduleTime
  ) {
    guard profile.preActivationReminderEnabled else { return }
    guard startSchedule.isTodayScheduled() else { return }
    schedulePreActivationNotifications(
      for: profile, startHour: startSchedule.hour, startMinute: startSchedule.minute
    )
  }

  /// Shared helper: schedules one notification per selected reminder time before the given start.
  /// Caller is responsible for guard checks (preActivationReminderEnabled, isTodayScheduled).
  /// Cancellation is handled by scheduleTimerActivity before calling this.
  private static func schedulePreActivationNotifications(
    for profile: BlockedProfiles,
    startHour: Int,
    startMinute: Int
  ) {
    let timersUtil = TimersUtil()
    var scheduledCount = 0
    let reminderTimes = profile.preActivationReminderTimes
    let calendar = Calendar.current
    let now = Date()

    guard
      let scheduledStart = calendar.date(
        bySettingHour: startHour,
        minute: startMinute,
        second: 0,
        of: now
      )
    else { return }

    for minutes in reminderTimes {
      let reminderMinutes = Int(minutes)
      guard
        let reminderTime = calendar.date(
          byAdding: .minute, value: -reminderMinutes, to: scheduledStart
        )
      else { continue }

      let secondsUntilReminder = reminderTime.timeIntervalSince(now)
      guard secondsUntilReminder > 0 else { continue }

      let title =
        "\(profile.name) starts in \(reminderMinutes) minute\(reminderMinutes == 1 ? "" : "s")"
      let message = "Your scheduled focus session is about to begin."
      let notificationId = TimersUtil.preActivationReminderIdentifier(
        for: profile.id, minutes: reminderMinutes
      )

      let threadId = TimersUtil.preActivationReminderThreadIdentifier(for: profile.id)

      timersUtil.scheduleNotification(
        title: title, message: message,
        seconds: secondsUntilReminder, identifier: notificationId,
        threadIdentifier: threadId
      )
      scheduledCount += 1
    }

    if scheduledCount > 0 {
      Log.info(
        "Scheduled \(scheduledCount) pre-activation reminder(s) for \(profile.name)",
        category: .timer
      )
    }
  }

  static func startBreakTimerActivity(for profile: BlockedProfiles) {
    let center = DeviceActivityCenter()
    let breakTimerActivity = BreakTimerActivity()
    let deviceActivityName = breakTimerActivity.getDeviceActivityName(from: profile.id.uuidString)

    let (intervalStart, intervalEnd) = getTimeIntervalStartAndEnd(
      from: profile.breakTimeInMinutes
    )
    let deviceActivitySchedule = DeviceActivitySchedule(
      intervalStart: intervalStart,
      intervalEnd: intervalEnd,
      repeats: false
    )

    do {
      // Remove any existing schedule and create a new one
      stopActivities(for: [deviceActivityName], with: center)
      try center.startMonitoring(deviceActivityName, during: deviceActivitySchedule)
      Log.info("Scheduled break timer activity from \(intervalStart) to \(intervalEnd) daily", category: .timer)
    } catch {
      Log.info("Failed to start break timer activity: \(error.localizedDescription)", category: .timer)
    }
  }

  static func startStrategyTimerActivity(for profile: BlockedProfiles) {
    guard let strategyData = profile.strategyData else {
      Log.info("No strategy data found for profile: \(profile.id.uuidString)", category: .timer)
      return
    }
    let timerData = StrategyTimerData.toStrategyTimerData(from: strategyData)

    let center = DeviceActivityCenter()
    let strategyTimerActivity = StrategyTimerActivity()
    let deviceActivityName = strategyTimerActivity.getDeviceActivityName(
      from: profile.id.uuidString
    )

    let (intervalStart, intervalEnd) = getTimeIntervalStartAndEnd(
      from: timerData.durationInMinutes
    )

    let deviceActivitySchedule = DeviceActivitySchedule(
      intervalStart: intervalStart,
      intervalEnd: intervalEnd,
      repeats: false
    )

    do {
      // Remove any existing activity and create a new one
      stopActivities(for: [deviceActivityName], with: center)
      try center.startMonitoring(deviceActivityName, during: deviceActivitySchedule)
      Log.info("Scheduled strategy timer activity from \(intervalStart) to \(intervalEnd) daily", category: .timer)
    } catch {
      Log.info("Failed to start strategy timer activity: \(error.localizedDescription)", category: .timer)
    }
  }

  static func removeScheduleTimerActivities(for profile: BlockedProfiles) {
    let scheduleTimerActivity = ScheduleTimerActivity()
    let deviceActivityName = scheduleTimerActivity.getDeviceActivityName(
      from: profile.id.uuidString
    )
    stopActivities(for: [deviceActivityName])
  }

  static func removeScheduleTimerActivities(for activity: DeviceActivityName) {
    stopActivities(for: [activity])
  }

  static func removeAllBreakTimerActivities() {
    let center = DeviceActivityCenter()
    let activities = center.activities
    let breakTimerActivity = BreakTimerActivity()
    let breakTimerActivities = breakTimerActivity.getAllBreakTimerActivities(from: activities)
    stopActivities(for: breakTimerActivities, with: center)
  }

  static func removeBreakTimerActivity(for profile: BlockedProfiles) {
    let breakTimerActivity = BreakTimerActivity()
    let deviceActivityName = breakTimerActivity.getDeviceActivityName(from: profile.id.uuidString)
    stopActivities(for: [deviceActivityName])
  }

  static func startOneMoreMinuteActivity(for profile: BlockedProfiles) throws {
    let center = DeviceActivityCenter()
    let oneMoreMinuteActivity = OneMoreMinuteTimerActivity()
    let deviceActivityName = oneMoreMinuteActivity.getDeviceActivityName(
      from: profile.id.uuidString
    )

    // Use second-level precision for the 60-second timer.
    // Compute exact start and end times with seconds.
    // Allow the interval to cross midnight if needed so the user always gets
    // a full 60 seconds.
    let now = Date()
    let calendar = Calendar.current
    let nowComponents = calendar.dateComponents([.hour, .minute, .second], from: now)
    let intervalStart = DateComponents(
      hour: nowComponents.hour,
      minute: nowComponents.minute,
      second: nowComponents.second
    )
    let endDate = now.addingTimeInterval(60)
    let endComponents = calendar.dateComponents([.hour, .minute, .second], from: endDate)
    let intervalEnd = DateComponents(
      hour: endComponents.hour,
      minute: endComponents.minute,
      second: endComponents.second
    )

    let deviceActivitySchedule = DeviceActivitySchedule(
      intervalStart: intervalStart,
      intervalEnd: intervalEnd,
      repeats: false
    )

    stopActivities(for: [deviceActivityName], with: center)
    try center.startMonitoring(deviceActivityName, during: deviceActivitySchedule)
    Log.info(
      "Scheduled one more minute activity from \(intervalStart) to \(intervalEnd)",
      category: .timer
    )
  }

  static func removeOneMoreMinuteActivity(for profile: BlockedProfiles) {
    let oneMoreMinuteActivity = OneMoreMinuteTimerActivity()
    let deviceActivityName = oneMoreMinuteActivity.getDeviceActivityName(
      from: profile.id.uuidString
    )
    stopActivities(for: [deviceActivityName])
  }

  static func removeAllOneMoreMinuteActivities() {
    let center = DeviceActivityCenter()
    let activities = center.activities
    let oneMoreMinuteActivity = OneMoreMinuteTimerActivity()
    let oneMoreMinuteActivities = oneMoreMinuteActivity.getAllOneMoreMinuteActivities(from: activities)
    stopActivities(for: oneMoreMinuteActivities, with: center)
  }

  static func removeAllStrategyTimerActivities() {
    let center = DeviceActivityCenter()
    let activities = center.activities
    let strategyTimerActivity = StrategyTimerActivity()
    let strategyTimerActivities = strategyTimerActivity.getAllStrategyTimerActivities(
      from: activities
    )
    stopActivities(for: strategyTimerActivities, with: center)
  }

  static func getActiveScheduleTimerActivity(for profile: BlockedProfiles) -> DeviceActivityName? {
    let center = DeviceActivityCenter()
    let scheduleTimerActivity = ScheduleTimerActivity()
    let activities = center.activities

    return activities.first(where: {
      $0 == scheduleTimerActivity.getDeviceActivityName(from: profile.id.uuidString)
    })
  }

  static func getActiveStopScheduleTimerActivity(for profile: BlockedProfiles) -> DeviceActivityName? {
    let center = DeviceActivityCenter()
    let stopTimerActivity = StopScheduleTimerActivity()
    let activities = center.activities

    return activities.first(where: {
      $0 == stopTimerActivity.getDeviceActivityName(from: profile.id.uuidString)
    })
  }

  static func getDeviceActivities() -> [DeviceActivityName] {
    let center = DeviceActivityCenter()
    return center.activities
  }

  private static func stopActivities(
    for activities: [DeviceActivityName], with center: DeviceActivityCenter? = nil
  ) {
    let center = center ?? DeviceActivityCenter()

    if activities.isEmpty {
      // No activities to stop
      Log.info("No activities to stop", category: .timer)
      return
    }

    center.stopMonitoring(activities)
  }

  static func getTimeIntervalStartAndEnd(from minutes: Int, now: Date = Date()) -> (
    intervalStart: DateComponents, intervalEnd: DateComponents
  ) {
    // Clamp the upper bound so the computed interval can never collapse to a
    // zero-length window: exactly 1440 minutes (24h), or any larger multiple,
    // lands intervalEnd on the same wall-clock minute as intervalStart, which
    // DeviceActivity silently refuses to monitor and defers ~24h (#212).
    // NOTE: the lower bound is intentionally NOT clamped here — that would
    // silently rewrite user-chosen break durations (see MAINTAINER DECISION 3).
    let clampedMinutes = min(minutes, DeviceActivityLimits.maximumTimerMinutes)
    if clampedMinutes != minutes {
      Log.warning(
        "Timer duration \(minutes)m exceeds DeviceActivity's honorable maximum; "
          + "clamped to \(clampedMinutes)m",
        category: .timer
      )
    }

    let calendar = Calendar.current
    let startComponents = calendar.dateComponents([.hour, .minute], from: now)
    let intervalStart = DateComponents(hour: startComponents.hour, minute: startComponents.minute)

    let endDate = now.addingTimeInterval(Double(clampedMinutes) * 60)
    let endComponents = calendar.dateComponents([.hour, .minute], from: endDate)
    let intervalEnd = DateComponents(hour: endComponents.hour, minute: endComponents.minute)

    return (intervalStart: intervalStart, intervalEnd: intervalEnd)
  }

  /// Computes the DeviceActivity interval for a stop-only schedule.
  ///
  /// The stop-only activity only cares about `intervalDidEnd` firing at the stop
  /// time (`StopScheduleTimerActivity.start(for:)` is a no-op), so `intervalStart`
  /// is a free internal artifact. Anchoring it at 00:00 (the historical default)
  /// yields a window of `stopHour*60 + stopMinute` minutes — under DeviceActivity's
  /// 15-minute minimum, or zero-length when stop == 00:00, whenever the stop time
  /// is before 00:15. In that case we anchor `intervalStart` one minute AFTER the
  /// stop so the repeating window wraps ~24h and still delivers `intervalDidEnd`
  /// at the stop time (#228). For stop times at or after 00:15 the historical
  /// 00:00 anchor is preserved (no behavior change).
  static func stopScheduleInterval(stopHour: Int, stopMinute: Int) -> (
    intervalStart: DateComponents, intervalEnd: DateComponents
  ) {
    let intervalEnd = DateComponents(hour: stopHour, minute: stopMinute)
    let stopMinuteOfDay = stopHour * 60 + stopMinute

    let intervalStart: DateComponents
    if stopMinuteOfDay < DeviceActivityLimits.minimumIntervalMinutes {
      let anchor = (stopMinuteOfDay + 1) % 1440
      intervalStart = DateComponents(hour: anchor / 60, minute: anchor % 60)
    } else {
      intervalStart = DateComponents(hour: 0, minute: 0)
    }
    return (intervalStart: intervalStart, intervalEnd: intervalEnd)
  }

  /// D-C2-2 wrap-anchor backstop interval for an absolute deadline.
  /// Produces a repeating window whose end is ceil-to-minute of `deadline` and whose start is
  /// one minute later modulo 24h. Ceil guarantees callbacks can be late, never early.
  static func wrapAnchorInterval(
    endingAt deadline: Date,
    now: Date,
    calendar: Calendar = .current
  ) -> (intervalStart: DateComponents, intervalEnd: DateComponents) {
    if deadline <= now {
      Log.warning(
        "wrapAnchorInterval: deadline is not in the future; closer gate will expire it",
        category: .timer)
    }
    let hour = calendar.component(.hour, from: deadline)
    let minute = calendar.component(.minute, from: deadline)
    let second = calendar.component(.second, from: deadline)
    let nanosecond = calendar.component(.nanosecond, from: deadline)

    var endMinuteOfDay = hour * 60 + minute
    if second > 0 || nanosecond > 0 {
      endMinuteOfDay = (endMinuteOfDay + 1) % 1440
    }
    let anchor = (endMinuteOfDay + 1) % 1440
    let intervalEnd = DateComponents(hour: endMinuteOfDay / 60, minute: endMinuteOfDay % 60)
    let intervalStart = DateComponents(hour: anchor / 60, minute: anchor % 60)
    return (intervalStart: intervalStart, intervalEnd: intervalEnd)
  }
}
