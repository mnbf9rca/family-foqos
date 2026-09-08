import DeviceActivity
import FoqosShared
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class PreActivationReminderSchedulerTests: XCTestCase {
  private var container: ModelContainer!
  private var context: ModelContext!
  private var suiteName: String!
  private var defaults: UserDefaults!

  override func setUp() async throws {
    try await super.setUp()
    suiteName = "PreActivationReminderSchedulerTests-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)!
    SharedData.configure(suite: defaults)
    container = try TestModelContainer.create()
    context = container.mainContext
  }

  override func tearDown() async throws {
    defaults.removePersistentDomain(forName: suiteName)
    try await super.tearDown()
  }

  func testGivenProfileWithMissingSnapshot_WhenReconciling_ThenSnapshotRewritten() throws {
    let profile = BlockedProfiles(name: "Focus")
    context.insert(profile)
    try context.save()
    SharedData.removeSnapshot(for: profile.id.uuidString)

    PreActivationReminderScheduler.reconcileMissingSnapshots(context: context)

    XCTAssertNotNil(SharedData.snapshot(for: profile.id.uuidString))
  }

  func testGivenPendingDelete_WhenReconciling_ThenSnapshotNotResurrected() throws {
    let profile = BlockedProfiles(name: "Focus")
    context.insert(profile)
    try context.save()
    SharedData.removeSnapshot(for: profile.id.uuidString)
    context.delete(profile)

    PreActivationReminderScheduler.reconcileMissingSnapshots(context: context)

    XCTAssertNil(SharedData.snapshot(for: profile.id.uuidString))
  }

  func testGivenScheduledAppSelectedProfileNoReminders_WhenEligibility_ThenTrue() throws {
    let now = Date()
    let profile = BlockedProfiles(name: "Synced")
    profile.startTriggers.schedule = true
    profile.startSchedule = ProfileScheduleTime(
      days: [.monday, .tuesday],
      hour: 9,
      minute: 0,
      updatedAt: now)
    profile.needsAppSelection = false
    context.insert(profile)

    XCTAssertEqual(DeviceActivityCenterUtil.requiredActivities(for: profile).count, 1)
  }

  func testGivenScheduledButNeedsAppSelection_WhenEligibility_ThenFalse() throws {
    let now = Date()
    let profile = BlockedProfiles(name: "Unselected")
    profile.startTriggers.schedule = true
    profile.startSchedule = ProfileScheduleTime(
      days: [.monday],
      hour: 8,
      minute: 30,
      updatedAt: now)
    profile.needsAppSelection = true
    context.insert(profile)

    XCTAssertTrue(DeviceActivityCenterUtil.requiredActivities(for: profile).isEmpty)
  }

  func testGivenScheduledAppSelectedProfileNoReminders_WhenReconciling_ThenRegisters() throws {
    let now = Date()
    let profile = BlockedProfiles(name: "Synced")
    profile.startTriggers.schedule = true
    profile.startSchedule = ProfileScheduleTime(
      days: [.monday],
      hour: 9,
      minute: 0,
      updatedAt: now)
    profile.needsAppSelection = false
    context.insert(profile)
    try context.save()
    var registeredIds: [UUID] = []

    PreActivationReminderScheduler.reconcileScheduleRegistrations(
      context: context,
      register: {
        registeredIds.append($0.id)
        return []
      })

    XCTAssertEqual(registeredIds, [profile.id])
  }

  func testGivenScheduledButNeedsAppSelection_WhenReconciling_ThenVisitsForCleanup() throws {
    let now = Date()
    let profile = BlockedProfiles(name: "Unselected")
    profile.startTriggers.schedule = true
    profile.startSchedule = ProfileScheduleTime(
      days: [.monday],
      hour: 8,
      minute: 30,
      updatedAt: now)
    profile.needsAppSelection = true
    context.insert(profile)
    try context.save()
    var registeredIds: [UUID] = []

    PreActivationReminderScheduler.reconcileScheduleRegistrations(
      context: context,
      register: {
        registeredIds.append($0.id)
        return []
      })

    XCTAssertEqual(registeredIds, [profile.id])
  }

  func testGivenReconcileCompletes_WhenReconciling_ThenPostsRefreshNotification() throws {
    let notificationCenter = NotificationCenter()
    let posted = expectation(description: "schedule reconcile notification posted")
    let observer = notificationCenter.addObserver(
      forName: .scheduleRegistrationsDidReconcile,
      object: nil,
      queue: nil
    ) { _ in
      posted.fulfill()
    }
    defer { notificationCenter.removeObserver(observer) }

    PreActivationReminderScheduler.reconcileScheduleRegistrations(
      context: context,
      notificationCenter: notificationCenter,
      register: { _ in [] })

    wait(for: [posted], timeout: 0.1)
  }
  func testSelectionPendingStartDoesNotWarnAboutMissingRegistration() {
    let now = Date()
    let profile = BlockedProfiles(name: "Pending", domains: ["example.com"])
    profile.startTriggers.schedule = true
    profile.startSchedule = ProfileScheduleTime(
      days: [.monday], hour: 9, minute: 0, updatedAt: now)
    profile.needsAppSelection = true

    XCTAssertFalse(profile.scheduleIsOutOfSync)
  }

  func testStopOnlyAndDisabledProfilesAreReconciled() throws {
    let now = Date()
    let stopOnly = BlockedProfiles(name: "Stop")
    stopOnly.stopConditions.schedule = true
    stopOnly.stopSchedule = ProfileScheduleTime(
      days: [.monday], hour: 17, minute: 0, updatedAt: now)
    let disabled = BlockedProfiles(name: "Disabled")
    for profile in [stopOnly, disabled] { context.insert(profile) }
    try context.save()
    var visited: [UUID] = []

    PreActivationReminderScheduler.reconcileScheduleRegistrations(
      context: context,
      register: {
        visited.append($0.id)
        return []
      })

    XCTAssertEqual(Set(visited), Set([stopOnly.id, disabled.id]))
  }

  func testRequiredActivityPolicyAndWarnings() {
    let now = Date()
    // V2 start, legacy start, stop, pending selection, expected start, expected stop.
    let cases: [(Bool, Bool, Bool, Bool, Bool, Bool)] = [
      (false, false, false, false, false, false),
      (false, false, false, true, false, false),
      (true, false, false, false, true, false),
      (true, false, true, false, true, false),
      (true, false, false, true, false, false),
      (true, false, true, true, false, true),
      (false, false, true, false, false, true),
      (false, false, true, true, false, true),
      (false, true, false, false, true, false),
      (false, true, true, false, true, true),
      (false, true, false, true, false, false),
      (false, true, true, true, false, true),
    ]
    for (v2, legacy, stop, pending, wantsStart, wantsStop) in cases {
      let profile = BlockedProfiles(name: "Policy", createdAt: now, updatedAt: now)
      profile.startTriggers.schedule = v2
      profile.startSchedule = ProfileScheduleTime(
        days: [.monday], hour: 9, minute: 0, updatedAt: now)
      if legacy {
        profile.schedule = BlockedProfileSchedule(
          days: [.monday], startHour: 9, startMinute: 0, endHour: 17, endMinute: 0, updatedAt: now)
      }
      profile.stopConditions.schedule = stop
      profile.stopSchedule = ProfileScheduleTime(
        days: [.monday], hour: 17, minute: 0, updatedAt: now)
      profile.needsAppSelection = pending
      let startName = ScheduleTimerActivity().getDeviceActivityName(from: profile.id.uuidString)
      let stopName = StopScheduleTimerActivity().getDeviceActivityName(from: profile.id.uuidString)
      let expected = (wantsStart ? [startName] : []) + (wantsStop ? [stopName] : [])
      XCTAssertEqual(DeviceActivityCenterUtil.requiredActivities(for: profile), expected)
      for inventory in [[], [startName], [stopName], [startName, stopName]] {
        let missing =
          (wantsStart && !inventory.contains(startName))
          || (wantsStop && !inventory.contains(stopName))
        let check: (BlockedProfiles) -> Bool = { $0.scheduleIsOutOfSync(activities: inventory) }
        XCTAssertEqual(check(profile), missing)
        var card = ScheduleOutOfSyncCardState()
        card.refresh(profiles: [profile], isOutOfSync: check)
        var editor = ScheduleOutOfSyncBannerState()
        editor.refresh(profile: profile, isOutOfSync: check)
        XCTAssertEqual(card.isOutOfSync(for: profile), missing)
        XCTAssertEqual(editor.isVisible, missing)
      }
    }
  }

  func testRegistrationFailureContinuesAndRefreshesThenSuccessfulRetryClearsWarning() throws {
    let now = Date()
    let profiles = (0..<2).map { index in
      let profile = BlockedProfiles(name: "Scheduled", order: index)
      profile.startTriggers.schedule = true
      profile.startSchedule = ProfileScheduleTime(
        days: [.monday], hour: 9, minute: 0, updatedAt: now)
      context.insert(profile)
      return profile
    }
    try context.save()
    let center = NotificationCenter()
    let refreshed = expectation(description: "refresh after failure and retry")
    refreshed.expectedFulfillmentCount = 2
    let observer = center.addObserver(
      forName: .scheduleRegistrationsDidReconcile, object: nil, queue: nil
    ) { _ in refreshed.fulfill() }
    defer { center.removeObserver(observer) }
    var visited: [UUID] = []
    PreActivationReminderScheduler.reconcileScheduleRegistrations(
      context: context, notificationCenter: center,
      register: { profile in
        visited.append(profile.id)
        return profile.id == profiles[0].id ? ["Start schedule: capacity exceeded"] : []
      })
    XCTAssertEqual(visited, profiles.map(\.id))
    XCTAssertTrue(profiles[0].scheduleIsOutOfSync(activities: []))
    var inventory: [DeviceActivityName] = []
    PreActivationReminderScheduler.reconcileScheduleRegistrations(
      context: context, notificationCenter: center,
      register: { profile in
        inventory.append(ScheduleTimerActivity().getDeviceActivityName(from: profile.id.uuidString))
        return []
      })
    XCTAssertFalse(profiles[0].scheduleIsOutOfSync(activities: inventory))
    wait(for: [refreshed], timeout: 0.1)
  }

  func testInactiveSchedulesRequireNothingAndUnsupportedProfilesAreNotReconciled() throws {
    let now = Date()
    let inactive = BlockedProfiles(name: "Inactive")
    inactive.startTriggers.schedule = true
    inactive.stopConditions.schedule = true
    inactive.startSchedule = ProfileScheduleTime(days: [], hour: 9, minute: 0, updatedAt: now)
    inactive.stopSchedule = ProfileScheduleTime(days: [], hour: 17, minute: 0, updatedAt: now)
    context.insert(inactive)
    let newer = BlockedProfiles(name: "Newer")
    newer.profileSchemaVersion = BlockedProfiles.currentSchemaVersion + 1
    context.insert(newer)
    let deleted = BlockedProfiles(name: "Deleted")
    context.insert(deleted)
    try context.save()
    context.delete(deleted)
    var visited: [UUID] = []

    PreActivationReminderScheduler.reconcileScheduleRegistrations(
      context: context,
      register: {
        visited.append($0.id)
        return []
      })

    XCTAssertEqual(visited, [inactive.id])
    XCTAssertTrue(DeviceActivityCenterUtil.requiredActivities(for: inactive).isEmpty)
    XCTAssertFalse(inactive.scheduleIsOutOfSync(activities: []))
  }

}
