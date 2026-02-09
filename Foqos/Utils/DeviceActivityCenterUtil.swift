import DeviceActivity
import FamilyControls
import ManagedSettings
import SwiftUI

class DeviceActivityCenterUtil {
    static func scheduleTimerActivity(for profile: BlockedProfiles) {
        let timersUtil = TimersUtil()
        let notificationId = TimersUtil.preActivationReminderIdentifier(for: profile.id)

        // Always cancel any existing pre-activation reminder first
        timersUtil.cancelNotification(identifier: notificationId)

        let center = DeviceActivityCenter()
        let scheduleTimerActivity = ScheduleTimerActivity()
        let deviceActivityName = scheduleTimerActivity.getDeviceActivityName(
            from: profile.id.uuidString
        )

        // Determine if we have a V2 start schedule
        let hasV2StartSchedule = profile.startTriggers.schedule
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
               let stopSched = profile.stopSchedule, stopSched.isActive {
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

    /// Schedule a notification before the profile's scheduled activation time
    private static func schedulePreActivationReminder(
        for profile: BlockedProfiles,
        schedule: BlockedProfileSchedule
    ) {
        guard profile.preActivationReminderEnabled else { return }
        guard schedule.isTodayScheduled() else { return }

        let timersUtil = TimersUtil()
        let notificationId = TimersUtil.preActivationReminderIdentifier(for: profile.id)

        // Calculate seconds until the scheduled start time
        let calendar = Calendar.current
        let now = Date()

        guard let scheduledStart = calendar.date(
            bySettingHour: schedule.startHour,
            minute: schedule.startMinute,
            second: 0,
            of: now
        ) else { return }

        // Calculate reminder time (start time minus reminder minutes)
        let reminderMinutes = Int(profile.preActivationReminderMinutes)
        guard let reminderTime = calendar.date(
            byAdding: .minute,
            value: -reminderMinutes,
            to: scheduledStart
        ) else { return }

        let secondsUntilReminder = reminderTime.timeIntervalSince(now)

        // Only schedule if the reminder time is in the future
        guard secondsUntilReminder > 0 else {
            Log.debug("Pre-activation reminder time has passed for profile: \(profile.name)", category: .timer)
            return
        }

        let title = "\(profile.name) starts in \(reminderMinutes) minute\(reminderMinutes == 1 ? "" : "s")"
        let message = "Your scheduled focus session is about to begin."

        timersUtil.scheduleNotification(
            title: title,
            message: message,
            seconds: secondsUntilReminder,
            identifier: notificationId
        )

        Log.info("Scheduled pre-activation reminder for \(profile.name) in \(Int(secondsUntilReminder)) seconds", category: .timer)
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
        let hasScheduledStart = profile.startTriggers.schedule
            && profile.startSchedule?.isActive == true
        let hasScheduledStop = profile.stopConditions.schedule
            && profile.stopSchedule?.isActive == true

        guard hasScheduledStop && !hasScheduledStart else {
            stopActivities(for: [deviceActivityName], with: center)
            return
        }

        let stopSchedule = profile.stopSchedule!
        let intervalStart = DateComponents(hour: 0, minute: 0)
        let intervalEnd = DateComponents(hour: stopSchedule.hour, minute: stopSchedule.minute)

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

        let timersUtil = TimersUtil()
        let notificationId = TimersUtil.preActivationReminderIdentifier(for: profile.id)

        let calendar = Calendar.current
        let now = Date()

        guard let scheduledStart = calendar.date(
            bySettingHour: startSchedule.hour,
            minute: startSchedule.minute,
            second: 0,
            of: now
        ) else { return }

        let reminderMinutes = Int(profile.preActivationReminderMinutes)
        guard let reminderTime = calendar.date(
            byAdding: .minute, value: -reminderMinutes, to: scheduledStart
        ) else { return }

        let secondsUntilReminder = reminderTime.timeIntervalSince(now)
        guard secondsUntilReminder > 0 else { return }

        let title = "\(profile.name) starts in \(reminderMinutes) minute\(reminderMinutes == 1 ? "" : "s")"
        let message = "Your scheduled focus session is about to begin."

        timersUtil.scheduleNotification(
            title: title, message: message,
            seconds: secondsUntilReminder, identifier: notificationId
        )

        Log.info(
            "Scheduled pre-activation reminder for \(profile.name) in \(Int(secondsUntilReminder)) seconds",
            category: .timer
        )
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

    private static func getTimeIntervalStartAndEnd(from minutes: Int) -> (
        intervalStart: DateComponents, intervalEnd: DateComponents
    ) {
        let intervalStart = DateComponents(hour: 0, minute: 0)

        // Get current time
        let now = Date()
        let currentComponents = Calendar.current.dateComponents([.hour, .minute], from: now)
        let currentHour = currentComponents.hour ?? 0
        let currentMinute = currentComponents.minute ?? 0

        // Calculate end time by adding minutes to current time
        let totalMinutes = currentMinute + minutes
        var endHour = currentHour + (totalMinutes / 60)
        var endMinute = totalMinutes % 60

        // Cap at 23:59 if it would roll over past midnight
        if endHour >= 24 || (endHour == 23 && endMinute >= 59) {
            endHour = 23
            endMinute = 59
        }

        let intervalEnd = DateComponents(hour: endHour, minute: endMinute)
        return (intervalStart: intervalStart, intervalEnd: intervalEnd)
    }
}
