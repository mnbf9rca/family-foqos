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

  /// #301: a profile is eligible for automatic DeviceActivity schedule registration iff it has
  /// an active start/legacy schedule AND its apps are selected on THIS device. The
  /// needsAppSelection gate is the semantic default: FamilyControls tokens are device-local,
  /// so a freshly-synced profile registers only after its apps are selected on this device.
  static func isEligibleForScheduleReconcile(_ profile: BlockedProfiles) -> Bool {
    let hasActiveSchedule =
      (profile.startTriggers.schedule && profile.startSchedule?.isActive == true)
      || profile.schedule?.isActive == true
    return hasActiveSchedule && !profile.needsAppSelection
  }

  /// #301: register DeviceActivity schedules for eligible profiles independent of whether
  /// pre-activation reminders are enabled.
  /// Old reminder-gated name `rescheduleAllReminders` caused #301 by hiding registration.
  @MainActor
  static func reconcileScheduleRegistrations(
    context: ModelContext,
    notificationCenter: NotificationCenter = .default,
    register: (BlockedProfiles) -> Void = { DeviceActivityCenterUtil.scheduleTimerActivity(for: $0) }
  ) {
    do {
      let profiles = try BlockedProfiles.fetchProfiles(in: context)

      for profile in profiles where isEligibleForScheduleReconcile(profile) {
        register(profile)
      }

      Log.debug("Reconciled DeviceActivity schedule registrations", category: .timer)
      notificationCenter.post(name: .scheduleRegistrationsDidReconcile, object: nil)
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
