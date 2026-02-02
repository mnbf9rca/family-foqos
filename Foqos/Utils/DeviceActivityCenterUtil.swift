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

        // Only schedule if the schedule is active
        guard let schedule = profile.schedule else { return }

        let center = DeviceActivityCenter()
        let scheduleTimerActivity = ScheduleTimerActivity()
        let deviceActivityName = scheduleTimerActivity.getDeviceActivityName(
            from: profile.id.uuidString
        )

        // If the schedule is not active, remove any existing schedule
        if !schedule.isActive {
            stopActivities(for: [deviceActivityName], with: center)
            return
        }

        let (intervalStart, intervalEnd) = scheduleTimerActivity.getScheduleInterval(from: schedule)
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
            schedulePreActivationReminder(for: profile, schedule: schedule)
        } catch {
            Log.info("Failed to start monitoring: \(error.localizedDescription)", category: .timer)
        }
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
