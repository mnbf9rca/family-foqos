import DeviceActivity
import FamilyControls
import ManagedSettings
import SwiftUI

class DeviceActivityCenterUtil {
  /// Required device-local names, shared by registration and missing-registration warnings.
  static func requiredActivities(for profile: BlockedProfiles) -> [DeviceActivityName] {
    guard !profile.isNewerSchemaVersion else { return [] }
    var names: [DeviceActivityName] = []
    let hasStart =
      profile.profileSchemaVersion < 2
      ? profile.schedule?.isActive == true
      : profile.startTriggers.schedule && profile.startSchedule?.isValid == true
    if hasStart && !profile.needsAppSelection {
      names.append(ScheduleTimerActivity().getDeviceActivityName(from: profile.id.uuidString))
    }
    if profile.stopConditions.schedule && profile.stopSchedule?.isValid == true {
      names.append(StopScheduleTimerActivity().getDeviceActivityName(from: profile.id.uuidString))
    }
    return names
  }

  @MainActor
  static func scheduleTimerActivity(
    for profile: BlockedProfiles, now: Date = Date(),
    scheduleFor: (DeviceActivityName) -> DeviceActivitySchedule? = { DeviceActivityCenter().schedule(for: $0) },
    startMonitoring: (DeviceActivityName, DeviceActivitySchedule) throws -> Void = { try DeviceActivityCenter().startMonitoring($0, during: $1) },
    stopMonitoring: ([DeviceActivityName]) -> Void = { DeviceActivityCenter().stopMonitoring($0) },
    publishStartCutoff: (UUID, Date) -> Bool = { SharedData.setStartRegistrationNotBefore($1, for: $0) }
  ) -> [String] {
    guard !profile.isNewerSchemaVersion else { return [] }
    var failures: [String] = []
    // Always cancel any existing pre-activation reminders first
    TimersUtil.cancelAllPreActivationReminders(for: profile.id)

    let scheduleTimerActivity = ScheduleTimerActivity()
    let deviceActivityName = scheduleTimerActivity.getDeviceActivityName(
      from: profile.id.uuidString
    )

    // Determine if we have a V2 start schedule
    let hasV2StartSchedule =
      profile.profileSchemaVersion >= 2 && profile.startTriggers.schedule
      && profile.startSchedule?.isValid == true

    guard requiredActivities(for: profile).contains(deviceActivityName) else {
      // No start schedule — remove any existing schedule activity
      if scheduleFor(deviceActivityName) != nil { stopMonitoring([deviceActivityName]) }
      SharedData.setStartRegistrationNotBefore(nil, for: profile.id)
      // Still check for stop-only schedule
      return scheduleStopActivity(for: profile, scheduleFor: scheduleFor, startMonitoring: startMonitoring, stopMonitoring: stopMonitoring)
    }

    // Build interval from V2 or legacy
    let intervalStart: DateComponents
    let intervalEnd: DateComponents

    if hasV2StartSchedule {
      let startSched = profile.startSchedule!
      intervalStart = DateComponents(hour: startSched.hour, minute: startSched.minute)

      // The end is artificial; the independent stop activity owns completion.
      let endMinute = (startSched.hour * 60 + startSched.minute + 1439) % 1440
      intervalEnd = DateComponents(hour: endMinute / 60, minute: endMinute % 60)
    } else if profile.profileSchemaVersion < 2, let schedule = profile.schedule {
      intervalStart = DateComponents(hour: schedule.startHour, minute: schedule.startMinute)
      intervalEnd = DateComponents(hour: schedule.endHour, minute: schedule.endMinute)
    } else {
      return scheduleStopActivity(for: profile, scheduleFor: scheduleFor, startMonitoring: startMonitoring, stopMonitoring: stopMonitoring)
    }

    let deviceActivitySchedule = DeviceActivitySchedule(
      intervalStart: intervalStart,
      intervalEnd: intervalEnd,
      repeats: true
    )

    if !sameClockSchedule(scheduleFor(deviceActivityName), deviceActivitySchedule) {
      // Publish before replacing monitoring: its immediate callback may describe an old start.
      if hasV2StartSchedule && !publishStartCutoff(profile.id, now) {
        failures.append("These settings couldn’t be saved. Please check this profile and try again.")
        Log.error("Failed to publish scheduled start registration cutoff", category: .timer)
      } else {
        do {
          if scheduleFor(deviceActivityName) != nil { stopMonitoring([deviceActivityName]) }
          try startMonitoring(deviceActivityName, deviceActivitySchedule)
          Log.info("Scheduled daily restrictions", category: .timer)
        } catch {
          failures.append("Start schedule: \(error.localizedDescription)")
          Log.error("Start schedule: \(error.localizedDescription)", category: .timer)
        }
      }
    }
    if failures.isEmpty {
      if hasV2StartSchedule, let startSchedule = profile.startSchedule {
        schedulePreActivationReminderV2(for: profile, startSchedule: startSchedule)
      } else if profile.profileSchemaVersion < 2, let schedule = profile.schedule {
        schedulePreActivationReminder(for: profile, schedule: schedule)
      }
    }

    // A failed start must not prevent an independent stop from registering.
    failures += scheduleStopActivity(for: profile, scheduleFor: scheduleFor, startMonitoring: startMonitoring, stopMonitoring: stopMonitoring)
    return failures
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
  @MainActor
  static func scheduleStopActivity(
    for profile: BlockedProfiles,
    scheduleFor: (DeviceActivityName) -> DeviceActivitySchedule? = { DeviceActivityCenter().schedule(for: $0) },
    startMonitoring: (DeviceActivityName, DeviceActivitySchedule) throws -> Void = { try DeviceActivityCenter().startMonitoring($0, during: $1) },
    stopMonitoring: ([DeviceActivityName]) -> Void = { DeviceActivityCenter().stopMonitoring($0) }
  ) -> [String] {
    defer { ScheduleRegistrationRefreshNotifier.post() }
    guard !profile.isNewerSchemaVersion else { return [] }
    let stopTimerActivity = StopScheduleTimerActivity()
    let deviceActivityName = stopTimerActivity.getDeviceActivityName(
      from: profile.id.uuidString
    )

    // A selection-pending V2 start does not own the stop callback.
    guard requiredActivities(for: profile).contains(deviceActivityName) else {
      if scheduleFor(deviceActivityName) != nil { stopMonitoring([deviceActivityName]) }
      return []
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

    guard !sameClockSchedule(scheduleFor(deviceActivityName), deviceActivitySchedule) else { return [] }
    do {
      if scheduleFor(deviceActivityName) != nil { stopMonitoring([deviceActivityName]) }
      try startMonitoring(deviceActivityName, deviceActivitySchedule)
      Log.info(
        "Scheduled stop-only activity at \(stopSchedule.hour):\(String(format: "%02d", stopSchedule.minute))",
        category: .timer
      )
    } catch {
      let message = "Stop schedule: \(error.localizedDescription)"
      Log.error("Stop schedule: \(error.localizedDescription)", category: .timer)
      return [message]
    }
    return []
  }

  private static func sameClockSchedule(_ existing: DeviceActivitySchedule?, _ desired: DeviceActivitySchedule) -> Bool {
    guard let existing else { return false }
    return existing.repeats == desired.repeats
      && existing.intervalStart.hour == desired.intervalStart.hour
      && existing.intervalStart.minute == desired.intervalStart.minute
      && existing.intervalEnd.hour == desired.intervalEnd.hour
      && existing.intervalEnd.minute == desired.intervalEnd.minute
  }

  static func removeStopScheduleActivity(for profile: BlockedProfiles) {
    // A V2 stop recurrence remains registered between sessions, regardless of their origin.
    if profile.profileSchemaVersion >= 2 && profile.stopConditions.schedule && profile.stopSchedule?.isValid == true { return }
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
      Log.info("Scheduled break timer activity", category: .timer)
    } catch {
      Log.info("Failed to start break timer activity: \(error.localizedDescription)", category: .timer)
    }
  }

  /// Registers and publishes only to the session created by the caller; grant fields stay intact.
  static func startStrategyTimerActivity(
    for profile: BlockedProfiles,
    session: BlockedProfileSession,
    durationInMinutes: Int? = nil,
    now: Date = Date(),
    register: (UUID, Int, Date) throws -> Date = registerStrategyTimer
  ) -> String? {
    let duration =
      durationInMinutes
      ?? profile.strategyData.map {
        StrategyTimerData.toStrategyTimerData(from: $0).durationInMinutes
      }
    guard let duration else { return "no timer duration was specified." }
    guard session.isActive, SharedData.getActiveSharedSession()?.id == session.id else {
      return "the session changed before its timer could be registered."
    }
    var registrationError: Error?
    let deadline: Date?
    do {
      deadline = try register(profile.id, duration, now)
    } catch {
      deadline = nil
      registrationError = error
    }
    guard session.isActive,
      SharedData.updateSessionTiming(
        expectedSessionId: session.id, startTime: session.startTime, timerEndTime: deadline
      )
    else { return "the session changed or its timer timing could not be saved." }
    session.timerEndTime = deadline
    do {
      guard let context = session.modelContext else { return "its timer timing could not be saved." }
      try context.save()
    } catch {
      Log.error("Failed to save session timer timing", category: .timer)
      return "its timer timing could not be saved."
    }
    if registrationError != nil {
      Log.error("Failed to register session countdown", category: .timer)
      return "its timer could not be registered. Open the app to stop or configure the session."
    }
    return nil
  }

  static func registerStrategyTimer(profileId: UUID, sessionId: String, minutes: Int, now: Date) throws -> Date {
    try StrategyTimerActivity.register(profileId: profileId, sessionId: sessionId, minutes: minutes, now: now)
  }

  static func removeStrategyTimerActivity(profileId: UUID, sessionId: String) {
    StrategyTimerActivity.cancel(profileId: profileId, sessionId: sessionId)
  }

  static func registerStrategyTimer(profileId: UUID, minutes: Int, now: Date) throws -> Date {
    let center = DeviceActivityCenter()
    let name = StrategyTimerActivity().getDeviceActivityName(from: profileId.uuidString)
    let interval = timerInterval(from: minutes, now: now)
    let schedule = DeviceActivitySchedule(
      intervalStart: interval.start, intervalEnd: interval.end, repeats: false)
    stopActivities(for: [name], with: center)
    try center.startMonitoring(name, during: schedule)
    return interval.deadline
  }

  static func removeScheduleTimerActivities(for profile: BlockedProfiles) {
    SharedData.setStartRegistrationNotBefore(nil, for: profile.id)
    let scheduleTimerActivity = ScheduleTimerActivity()
    let deviceActivityName = scheduleTimerActivity.getDeviceActivityName(
      from: profile.id.uuidString
    )
    stopActivities(for: [deviceActivityName])
  }

  static func removeScheduleTimerActivities(for activity: DeviceActivityName) {
    if let id = UUID(uuidString: activity.rawValue) { SharedData.setStartRegistrationNotBefore(nil, for: id) }
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
    Log.info("Scheduled one more minute activity", category: .timer)
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

  static func removeStrategyTimerActivity(profileId: UUID) {
    stopActivities(for: [StrategyTimerActivity().getDeviceActivityName(from: profileId.uuidString)])
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
    let interval = timerInterval(from: minutes, now: now)
    return (interval.start, interval.end)
  }

  static func timerInterval(from minutes: Int, now: Date, calendar: Calendar = .current) -> (
    start: DateComponents, end: DateComponents, deadline: Date
  ) {
    // Keep the existing upper clamp and minute precision, including across midnight.
    let end = now.addingTimeInterval(Double(min(minutes, DeviceActivityLimits.maximumTimerMinutes)) * 60)
    let deadline = calendar.dateInterval(of: .minute, for: end)!.start
    return (
      calendar.dateComponents([.hour, .minute], from: now),
      calendar.dateComponents([.hour, .minute], from: deadline), deadline
    )
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

  // MARK: - C2 deadline backstops

  private static func breakBackstopName(_ profileId: UUID) -> DeviceActivityName {
    DeviceActivityName(rawValue: "\(BreakDeadlineBackstopActivity.id):\(profileId.uuidString)")
  }

  private static func ommBackstopName(_ profileId: UUID) -> DeviceActivityName {
    DeviceActivityName(rawValue: "\(OneMoreMinuteDeadlineBackstopActivity.id):\(profileId.uuidString)")
  }

  private static func backstopSchedule(deadline: Date, now: Date) -> DeviceActivitySchedule {
    let (start, end) = wrapAnchorInterval(endingAt: deadline, now: now)
    return DeviceActivitySchedule(intervalStart: start, intervalEnd: end, repeats: true)
  }

  static func replaceBreakBackstop(profileId: UUID, deadline: Date, now: Date) throws {
    let name = breakBackstopName(profileId)
    let center = DeviceActivityCenter()
    center.stopMonitoring([name])
    try center.startMonitoring(name, during: backstopSchedule(deadline: deadline, now: now))
  }

  static func replaceOneMoreMinuteBackstop(profileId: UUID, deadline: Date, now: Date) throws {
    let name = ommBackstopName(profileId)
    let center = DeviceActivityCenter()
    center.stopMonitoring([name])
    try center.startMonitoring(name, during: backstopSchedule(deadline: deadline, now: now))
  }

  static func registerBreakBackstopIfAbsent(
    profileId: UUID,
    deadline: Date,
    now: Date
  ) throws -> Bool {
    let name = breakBackstopName(profileId)
    let center = DeviceActivityCenter()
    if center.activities.contains(name) { return false }
    try center.startMonitoring(name, during: backstopSchedule(deadline: deadline, now: now))
    return true
  }

  static func registerOneMoreMinuteBackstopIfAbsent(
    profileId: UUID,
    deadline: Date,
    now: Date
  ) throws -> Bool {
    let name = ommBackstopName(profileId)
    let center = DeviceActivityCenter()
    if center.activities.contains(name) { return false }
    try center.startMonitoring(name, during: backstopSchedule(deadline: deadline, now: now))
    return true
  }

  static func removeBreakBackstop(profileId: UUID) {
    DeviceActivityCenter().stopMonitoring([breakBackstopName(profileId)])
  }

  static func removeOneMoreMinuteBackstop(profileId: UUID) {
    DeviceActivityCenter().stopMonitoring([ommBackstopName(profileId)])
  }

  static func hasBreakBackstop(profileId: UUID) -> Bool {
    DeviceActivityCenter().activities.contains(breakBackstopName(profileId))
  }

  static func hasOneMoreMinuteBackstop(profileId: UUID) -> Bool {
    DeviceActivityCenter().activities.contains(ommBackstopName(profileId))
  }

  static func removeC2BackstopsExcept(profileId: UUID) {
    let keepBreak = "\(BreakDeadlineBackstopActivity.id):\(profileId.uuidString)"
    let keepOMM = "\(OneMoreMinuteDeadlineBackstopActivity.id):\(profileId.uuidString)"
    let center = DeviceActivityCenter()
    let stale = center.activities.filter {
      let raw = $0.rawValue
      let isC2 =
        raw.starts(with: BreakDeadlineBackstopActivity.id)
        || raw.starts(with: OneMoreMinuteDeadlineBackstopActivity.id)
      return isC2 && raw != keepBreak && raw != keepOMM
    }
    if !stale.isEmpty {
      center.stopMonitoring(Array(stale))
    }
  }
}
