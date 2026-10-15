import DeviceActivity
import FoqosShared
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class DeleteProfileCleanupTests: XCTestCase {
  private var suiteName: String!

  override func setUp() async throws {
    suiteName = "DeleteProfileCleanupTests-\(UUID())"
    SharedData.configure(suite: UserDefaults(suiteName: suiteName)!)
  }

  override func tearDown() async throws {
    SharedData.resetLockPath()
    UserDefaults().removePersistentDomain(forName: suiteName)
  }

  func testDeletingBeforeImportingScheduledSessionAllowsNextSchedule() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 10))!
    let container = try TestModelContainer.create()
    let context = container.mainContext
    let deleted = BlockedProfiles(name: "Deleted", createdAt: now, updatedAt: now)
    let next = BlockedProfiles(name: "Next", createdAt: now, updatedAt: now)
    for profile in [deleted, next] {
      profile.startTriggers = .init(schedule: true)
      profile.startSchedule = .init(days: [.monday], hour: 9, minute: 0, updatedAt: now.addingTimeInterval(-7200))
      profile.stopConditions = .init(manual: true)
      context.insert(profile)
      BlockedProfiles.updateSnapshot(for: profile)
    }
    try context.save()
    let scheduler = ScheduleTimerActivity(applier: RecordingRestrictionApplier(), cancelReminders: { _ in })
    let deletedSnapshot = BlockedProfiles.getSnapshot(for: deleted)
    scheduler.start(for: deletedSnapshot, now: now, calendar: calendar)
    XCTAssertEqual(SharedData.getActiveSharedSession()?.blockedProfileId, deleted.id)
    XCTAssertTrue(deleted.sessions.isEmpty, "The extension started before the app imported its session")

    try BlockedProfiles.deleteProfile(deleted, in: context)
    try context.save()

    XCTAssertNil(SharedData.getActiveSharedSession())
    XCTAssertTrue(SharedData.completedSessionsInScheduler.isEmpty)
    scheduler.start(for: deletedSnapshot, now: now.addingTimeInterval(60), calendar: calendar)
    XCTAssertNil(SharedData.getActiveSharedSession(), "A callback holding the old snapshot cannot recreate the ghost")
    scheduler.start(for: BlockedProfiles.getSnapshot(for: next), now: now.addingTimeInterval(120), calendar: calendar)
    XCTAssertEqual(SharedData.getActiveSharedSession()?.blockedProfileId, next.id)
  }

  func testDeletionRemovesCompletedSharedSessionsAndPreservesUnrelatedActiveSession() throws {
    let now = Date()
    let container = try TestModelContainer.create()
    let context = container.mainContext
    let deleted = BlockedProfiles(name: "Deleted", createdAt: now, updatedAt: now)
    let other = BlockedProfiles(name: "Other", createdAt: now, updatedAt: now)
    context.insert(deleted)
    context.insert(other)
    try context.save()
    let live = SharedData.SessionSnapshot(id: UUID().uuidString, tag: "manual", blockedProfileId: other.id, startTime: now, forceStarted: false)
    let ended = SharedData.SessionSnapshot(id: UUID().uuidString, tag: "schedule", blockedProfileId: deleted.id, startTime: now.addingTimeInterval(-100), endTime: now, forceStarted: true)
    SharedData.createActiveSharedSession(for: live)
    SharedData.completedSessionsInScheduler = [ended]

    try BlockedProfiles.deleteProfile(deleted, in: context)
    try context.save()

    XCTAssertEqual(SharedData.getActiveSharedSession(), live)
    XCTAssertTrue(SharedData.completedSessionsInScheduler.isEmpty)
  }

  func testDeletionRefusesUnavailableLockAndCorruptSharedStorageBeforeLocalMutation() throws {
    let now = Date()
    let container = try TestModelContainer.create()
    let context = container.mainContext
    let profile = BlockedProfiles(name: "Keep", createdAt: now, updatedAt: now)
    context.insert(profile)
    let session = BlockedProfileSession(tag: "manual", blockedProfile: profile, startTime: now)
    context.insert(session)
    try context.save()
    BlockedProfiles.updateSnapshot(for: profile)
    SharedData.createActiveSharedSession(for: session.toSnapshot())
    SharedData.configureLockPath(nil)

    XCTAssertThrowsError(try BlockedProfiles.deleteProfile(profile, in: context))
    XCTAssertNotNil(try BlockedProfiles.findProfile(byID: profile.id, in: context))
    XCTAssertNil(session.endTime)
    XCTAssertEqual(SharedData.getActiveSharedSession()?.id, session.id)
    XCTAssertNotNil(SharedData.snapshot(for: profile.id.uuidString))

    SharedData.resetLockPath()
    let corrupt = Data("corrupt".utf8)
    UserDefaults(suiteName: suiteName)!.set(corrupt, forKey: "family_foqos_completed_schedule_sessions")
    XCTAssertThrowsError(try BlockedProfiles.deleteProfile(profile, in: context))
    XCTAssertNotNil(try BlockedProfiles.findProfile(byID: profile.id, in: context))
    XCTAssertNil(session.endTime)
    XCTAssertEqual(SharedData.getActiveSharedSession()?.id, session.id)
  }

  func testRemovalCancelsAllOwnedActivityKindsAndPreservesOtherOwners() {
    let id = UUID()
    let other = UUID()
    let sessionId = UUID().uuidString
    let owned: [DeviceActivityName] = [
      ScheduleTimerActivity().getDeviceActivityName(from: id.uuidString),
      StopScheduleTimerActivity().getDeviceActivityName(from: id.uuidString),
      BreakTimerActivity().getDeviceActivityName(from: id.uuidString),
      OneMoreMinuteTimerActivity().getDeviceActivityName(from: id.uuidString),
      BreakDeadlineBackstopActivity().getDeviceActivityName(from: id.uuidString),
      OneMoreMinuteDeadlineBackstopActivity().getDeviceActivityName(from: id.uuidString),
      StrategyTimerActivity().getDeviceActivityName(from: id.uuidString),
      StrategyTimerActivity().getDeviceActivityName(profileId: id, sessionId: sessionId),
    ]
    let unrelated = [
      StrategyTimerActivity().getDeviceActivityName(profileId: other, sessionId: id.uuidString),
      ScheduleTimerActivity().getDeviceActivityName(from: other.uuidString),
      DeviceActivityName("unrelated:\(id)-suffix"),
    ]
    var removed: [DeviceActivityName] = []
    DeviceActivityCenterUtil.removeActivities(for: id, activities: owned + unrelated, stopMonitoring: { removed = $0 })
    XCTAssertEqual(removed, owned)
  }

  func testRemovalWaitsForExtensionTransitionLock() throws {
    let now = Date()
    let id = UUID()
    let snapshot = SharedData.SessionSnapshot(id: UUID().uuidString, tag: "schedule", blockedProfileId: id, startTime: now, forceStarted: true)
    SharedData.createActiveSharedSession(for: snapshot)
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    let fd = open(path, O_CREAT | O_RDWR, 0o600)
    XCTAssertGreaterThanOrEqual(fd, 0)
    guard fd >= 0 else { return }
    defer {
      close(fd)
      unlink(path)
    }
    XCTAssertEqual(flock(fd, LOCK_EX), 0)
    SharedData.configureLockPath(path)
    let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      _ = SharedData.removeProfileSessions(where: { $0 == id })
      finished.signal()
    }
    XCTAssertEqual(finished.wait(timeout: .now() + 0.1), .timedOut)
    XCTAssertEqual(flock(fd, LOCK_UN), 0)
    XCTAssertEqual(finished.wait(timeout: .now() + 3), .success)
    XCTAssertNil(SharedData.getActiveSharedSession())
  }

  func testDeletionClearsOnlyOwnedShieldsAndPublishedSession() throws {
    let now = Date()
    for deletingActive in [true, false] {
      let container = try TestModelContainer.create()
      let context = container.mainContext
      let deleted = BlockedProfiles(name: "Deleted", createdAt: now, updatedAt: now)
      let other = BlockedProfiles(name: "Other", createdAt: now, updatedAt: now)
      context.insert(deleted)
      context.insert(other)
      let session = BlockedProfileSession(tag: "manual", blockedProfile: deletingActive ? deleted : other, startTime: now)
      context.insert(session)
      try context.save()
      SharedData.createActiveSharedSession(for: session.toSnapshot())
      let manager = StrategyManager()
      manager.activeSession = session
      var deactivations = 0
      let cleanup = BlockedProfiles.DeleteCleanup(
        removeStartSchedule: { _ in }, removeStopSchedule: { _ in },
        cancelPreActivationReminders: { _ in }, cancelSessionAndBreakReminders: { _ in },
        removeBreakBackstop: { _ in }, removeOneMoreMinuteBackstop: { _ in },
        cancelStrategyTimer: { _, _ in }, removeProfileActivities: { _ in },
        deactivateRestrictions: { deactivations += 1 },
        discardLocalSession: { manager.discardDeletedProfileSession(profileId: $0) })

      try BlockedProfiles.deleteProfile(deleted, in: context, cleanup: cleanup)
      try context.save()

      XCTAssertEqual(deactivations, deletingActive ? 1 : 0)
      XCTAssertEqual(manager.activeSession?.id, deletingActive ? nil : session.id)
      XCTAssertEqual(SharedData.getActiveSharedSession()?.id, deletingActive ? nil : session.id)
    }
  }

  func testGivenProfileDelete_WhenDeleting_ThenRemovesSchedulesRemindersAndDeadlineBackstops()
    throws
  {
    let container = try TestModelContainer.create()
    let context = container.mainContext
    let profile = BlockedProfiles(name: "Homework")
    context.insert(profile)
    try context.save()

    var cleanupActions: [String] = []
    let cleanup = BlockedProfiles.DeleteCleanup(
      removeStartSchedule: { _ in cleanupActions.append("removeStartSchedule") },
      removeStopSchedule: { _ in cleanupActions.append("removeStopSchedule") },
      cancelPreActivationReminders: { _ in
        cleanupActions.append("cancelPreActivationReminders")
      },
      cancelSessionAndBreakReminders: { profileId in
        XCTAssertEqual(profileId, profile.id)
        cleanupActions.append("cancelSessionAndBreakReminders")
      },
      removeBreakBackstop: { profileId in
        XCTAssertEqual(profileId, profile.id)
        cleanupActions.append("removeBreakBackstop")
      },
      removeOneMoreMinuteBackstop: { profileId in
        XCTAssertEqual(profileId, profile.id)
        cleanupActions.append("removeOneMoreMinuteBackstop")
      }
    )

    try BlockedProfiles.deleteProfile(profile, in: context, cleanup: cleanup)

    XCTAssertEqual(
      cleanupActions,
      [
        "removeStartSchedule", "removeStopSchedule", "cancelPreActivationReminders",
        "cancelSessionAndBreakReminders", "removeBreakBackstop", "removeOneMoreMinuteBackstop",
      ]
    )
    XCTAssertNil(try BlockedProfiles.findProfile(byID: profile.id, in: context))
  }
  func testDeletingProfileCancelsOnlyItsActiveExactTimer() throws {
    let now = Date()
    let container = try TestModelContainer.create()
    let context = container.mainContext
    let profile = BlockedProfiles(name: "Timed", createdAt: now, updatedAt: now)
    context.insert(profile)
    let active = BlockedProfileSession(
      tag: "manual", blockedProfile: profile, startTime: now,
      origin: .init(kind: .manual))
    context.insert(active)
    let ended = BlockedProfileSession(tag: "old", blockedProfile: profile, startTime: now.addingTimeInterval(-100))
    ended.endTime = now.addingTimeInterval(-10)
    context.insert(ended)
    try context.save()
    let activeId = active.id
    var cancellations: [String] = []
    let cleanup = BlockedProfiles.DeleteCleanup(
      removeStartSchedule: { _ in }, removeStopSchedule: { _ in },
      cancelPreActivationReminders: { _ in }, cancelSessionAndBreakReminders: { _ in },
      removeBreakBackstop: { _ in }, removeOneMoreMinuteBackstop: { _ in },
      cancelStrategyTimer: { id, sessionId in
        XCTAssertEqual(id, profile.id)
        cancellations.append(sessionId)
      })
    try BlockedProfiles.deleteProfile(profile, in: context, cleanup: cleanup)
    XCTAssertEqual(cancellations, [activeId])
  }

}
