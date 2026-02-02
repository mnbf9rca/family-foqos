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
        guard profile.preActivationReminderEnabled,
          let schedule = profile.schedule,
          schedule.isActive
        else {
          continue
        }

        // Reschedule via DeviceActivityCenterUtil which handles the notification
        DeviceActivityCenterUtil.scheduleTimerActivity(for: profile)
      }

      Log.debug("Rescheduled pre-activation reminders for all eligible profiles", category: .timer)
    } catch {
      Log.error(
        "Failed to reschedule pre-activation reminders: \(error.localizedDescription)",
        category: .timer)
    }
  }
}
