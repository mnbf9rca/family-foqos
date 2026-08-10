import FoqosShared
import Foundation
import SwiftData

#if DEBUG
  /// Seeds the in-memory demo container and stages published singleton state for
  /// screenshot scenarios. Only ever writes to the passed (in-memory) container —
  /// never the on-disk store, SharedData suite, or CloudKit (all guarded off in demo mode).
  @MainActor
  enum ScreenshotDemoSeeder {
    static func seed(container: ModelContainer, now: Date = Date()) throws {
      guard ScreenshotDemoMode.isActive else { return }
      let context = container.mainContext

      let school = BlockedProfiles(
        name: "School Nights", enableLiveActivity: true, reminderTimeInSeconds: 3600, order: 0)
      school.startTriggers = ProfileStartTriggers(manual: true, schedule: true)
      school.stopConditions = ProfileStopConditions(manual: true, schedule: true)
      school.startSchedule = ProfileScheduleTime(
        days: [.sunday, .monday, .tuesday, .wednesday, .thursday], hour: 19, minute: 0,
        updatedAt: now)
      school.stopSchedule = ProfileScheduleTime(
        days: [.sunday, .monday, .tuesday, .wednesday, .thursday], hour: 21, minute: 0,
        updatedAt: now)

      let homework = BlockedProfiles(
        name: "Homework", enableBreaks: true, order: 1, isManaged: true,
        managedByChildId: "_demo-emma")
      homework.startTriggers = ProfileStartTriggers(manual: true)
      homework.stopConditions = ProfileStopConditions(manual: true, timer: true)

      let bedtime = BlockedProfiles(name: "Bedtime", order: 2)
      bedtime.startTriggers = ProfileStartTriggers(schedule: true)
      bedtime.stopConditions = ProfileStopConditions(schedule: true)

      let focus = BlockedProfiles(name: "Deep Focus", enableStrictMode: true, order: 3)
      focus.startTriggers = ProfileStartTriggers(manual: true, anyNFC: true)
      focus.stopConditions = ProfileStopConditions(anyNFC: true)

      for profile in [school, homework, bedtime, focus] {
        context.insert(profile)
      }
      seedHistory(
        profiles: [school, homework, bedtime, focus], context: context, now: now)

      if ScreenshotDemoMode.scenario == .homeActive {
        // Direct init (NOT createSession) so no SharedData/app-group write occurs.
        let session = BlockedProfileSession(
          tag: "manual", blockedProfile: homework, startTime: now.addingTimeInterval(-2400))
        context.insert(session)
      }
      try context.save()

      CloudKitManager.shared.isSignedIn = true
      CloudKitManager.shared.isConnectedToFamily = true
      CloudKitManager.shared.isShareOwner = true
      CloudKitManager.shared.familyMembers = [
        FamilyMember(
          userRecordName: "_demo-alex", displayName: "Alex", role: .parent,
          enrolledAt: now.addingTimeInterval(-86400 * 190)),
        FamilyMember(
          userRecordName: "_demo-emma", displayName: "Emma", role: .child,
          enrolledAt: now.addingTimeInterval(-86400 * 188)),
        FamilyMember(
          userRecordName: "_demo-sam", displayName: "Sam", role: .child,
          enrolledAt: now.addingTimeInterval(-86400 * 92)),
      ]
      LockCodeManager.shared.seedForScreenshots([FamilyLockCode(code: "0000")])
      HeartbeatManager.shared.monitoredDevices = [
        MonitoredDevice(
          deviceIdentifier: "demo-device-emma", deviceName: "Emma's iPhone",
          childUserRecordName: "_demo-emma", lastSeenAt: now.addingTimeInterval(-300),
          isSuppressed: false, notificationIdentifier: nil, authorizationStatus: "approved",
          authRevokedNotifiedAt: nil),
        MonitoredDevice(
          deviceIdentifier: "demo-device-sam", deviceName: "Sam's iPhone",
          childUserRecordName: "_demo-sam", lastSeenAt: now.addingTimeInterval(-1500),
          isSuppressed: false, notificationIdentifier: nil, authorizationStatus: "approved",
          authRevokedNotifiedAt: nil),
      ]

      let mode: AppMode = ScreenshotDemoMode.scenario == .parentDashboard ? .parent : .individual
      AppModeManager.shared.selectMode(mode)
      UserDefaults.standard.set(true, forKey: "family_foqos_has_completed_onboarding")
      UserDefaults.standard.set(false, forKey: "family_foqos_show_intro_screen")
      UserDefaults.standard.set(false, forKey: "family_foqos_show_mode_selection")
    }

    private static func seedHistory(
      profiles: [BlockedProfiles], context: ModelContext, now: Date
    ) {
      let dayOffsets = [1, 2, 3, 5, 6, 7, 8, 10, 11, 12, 13, 15, 16, 18, 19, 21]
      let durations: [TimeInterval] = [1800, 5400, 12600, 19800]

      for (index, dayOffset) in dayOffsets.enumerated() {
        let endTime = now.addingTimeInterval(-TimeInterval(dayOffset) * 86400)
        let duration = durations[(index + index / profiles.count) % durations.count]
        let session = BlockedProfileSession(
          tag: "demo-history",
          blockedProfile: profiles[index % profiles.count],
          startTime: endTime.addingTimeInterval(-duration))
        session.endTime = endTime
        context.insert(session)
      }
    }
  }
#endif
