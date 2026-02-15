import Foundation
import SwiftData

/// Schedules pre-activation reminders for all profiles with active schedules.
/// Call this on app launch and when returning to foreground to ensure
/// daily notifications are scheduled.
enum PreActivationReminderScheduler {
  /// Reschedule all pre-activation reminders for profiles with active schedules.
  /// This should be called on app launch to ensure today's reminders are set.
  static func rescheduleAllReminders(context: ModelContext) {
    do {
      let profiles = try BlockedProfiles.fetchProfiles(in: context)

      for profile in profiles {
        let hasActiveSchedule =
          (profile.startTriggers.schedule && profile.startSchedule?.isActive == true)
          || profile.schedule?.isActive == true
        guard profile.preActivationReminderEnabled, hasActiveSchedule else {
          continue
        }

        // Reschedule via DeviceActivityCenterUtil which handles the notification
        DeviceActivityCenterUtil.scheduleTimerActivity(for: profile)
      }

      Log.debug("Rescheduled pre-activation reminders for all eligible profiles", category: .timer)
    } catch {
      Log.error(
        "Failed to reschedule pre-activation reminders: \(error.localizedDescription)",
        category: .timer
      )
    }
  }

  /// Catch-up: if a V2 schedule should be active but no session is running, start it directly.
  /// Called on foreground to handle cases where DeviceActivity didn't fire intervalDidStart.
  static func catchUpMissedScheduleStarts(context: ModelContext) {
    do {
      let profiles = try BlockedProfiles.fetchProfiles(in: context)

      for profile in profiles {
        guard profile.startTriggers.schedule,
          let startSchedule = profile.startSchedule,
          startSchedule.isActive
        else { continue }

        let activeStopSchedule =
          (profile.stopConditions.schedule && profile.stopSchedule?.isActive == true)
          ? profile.stopSchedule : nil

        guard
          startSchedule.shouldBeActiveNow(
            stopSchedule: activeStopSchedule,
            lastStoppedAt: profile.scheduleLastStoppedAt)
        else { continue }

        let snapshot = BlockedProfiles.getSnapshot(for: profile)
        ScheduleTimerActivity().start(for: snapshot)
      }
    } catch {
      Log.error(
        "Failed to catch up missed schedule starts: \(error.localizedDescription)",
        category: .timer
      )
    }
  }
}
