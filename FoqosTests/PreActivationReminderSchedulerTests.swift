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

    XCTAssertTrue(PreActivationReminderScheduler.isEligibleForScheduleReconcile(profile))
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

    XCTAssertFalse(PreActivationReminderScheduler.isEligibleForScheduleReconcile(profile))
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
      register: { registeredIds.append($0.id) })

    XCTAssertEqual(registeredIds, [profile.id])
  }

  func testGivenScheduledButNeedsAppSelection_WhenReconciling_ThenSkipsRegistration() throws {
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
      register: { registeredIds.append($0.id) })

    XCTAssertEqual(registeredIds, [])
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
      register: { _ in })

    wait(for: [posted], timeout: 0.1)
  }
}
