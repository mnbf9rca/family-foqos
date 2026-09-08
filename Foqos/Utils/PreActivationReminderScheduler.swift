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
    do {
      let profiles = try BlockedProfiles.fetchProfiles(in: context).valid
      for profile in profiles where SharedData.snapshot(for: profile.id.uuidString) == nil {
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

        Log.info("Catching up missed schedule start for profile: \(profile.name)", category: .timer)
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
