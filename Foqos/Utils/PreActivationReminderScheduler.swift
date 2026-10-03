import FoqosShared
import Foundation
import SwiftData

extension Notification.Name {
  static let scheduleRegistrationsDidReconcile = Notification.Name(
    "scheduleRegistrationsDidReconcile")
}

/// Schedules pre-activation reminders for all profiles with active schedules.
/// Call this on app launch and when returning to foreground to ensure
/// daily notifications are scheduled.
enum PreActivationReminderScheduler {
  static func mergeExtensionScheduleSuppression(context: ModelContext) {
    do {
      let profiles = try BlockedProfiles.fetchProfiles(in: context)
      var changed = false
      for profile in profiles {
        guard
          let snapStopped = SharedData.snapshot(for: profile.id.uuidString)?.scheduleLastStoppedAt
        else { continue }
        let current = profile.scheduleLastStoppedAt
        if current == nil || snapStopped > current! {
          profile.scheduleLastStoppedAt = snapStopped
          changed = true
        }
      }
      if changed { try context.save() }
    } catch {
      Log.error(
        "Failed to merge extension schedule suppression: \(error.localizedDescription)",
        category: .timer)
    }
  }

  @MainActor
  static func reconcileMissingSnapshots(context: ModelContext) {
    mergeExtensionScheduleSuppression(context: context)
    do {
      let profiles = try BlockedProfiles.fetchProfiles(in: context).valid
      for profile in profiles {
        BlockedProfiles.updateSnapshot(for: profile)
      }
    } catch {
      Log.error(
        "Failed to reconcile profile snapshots: \(error.localizedDescription)",
        category: .timer)
    }
  }

  /// Re-register required schedules and clean up obsolete names, even without a start schedule.
  @MainActor
  static func reconcileScheduleRegistrations(
    context: ModelContext,
    notificationCenter: NotificationCenter = .default,
    register: (BlockedProfiles) -> [String] = { DeviceActivityCenterUtil.scheduleTimerActivity(for: $0) }
  ) {
    defer { ScheduleRegistrationRefreshNotifier.post(notificationCenter: notificationCenter) }
    do {
      let profiles = try BlockedProfiles.fetchProfiles(in: context).valid

      for profile in profiles where !profile.isNewerSchemaVersion {
        // The registrar logs each concrete OS failure; continue with the remaining profiles.
        _ = register(profile)
      }

      Log.debug("Finished DeviceActivity schedule registration attempts", category: .timer)
    } catch {
      Log.error(
        "Failed to reconcile schedule registrations: \(error.localizedDescription)",
        category: .timer
      )
    }
  }

}
