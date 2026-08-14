import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class StrategyManagerReconcileTests: XCTestCase {
  private var container: ModelContainer!
  private var context: ModelContext!
  private var manager: StrategyManager!
  private var suiteName: String!

  override func setUp() async throws {
    try await super.setUp()
    suiteName = "StrategyManagerReconcileTests-\(UUID().uuidString)"
    SharedData.configure(suite: UserDefaults(suiteName: suiteName)!)
    container = try TestModelContainer.create()
    context = container.mainContext
    manager = StrategyManager()
  }

  override func tearDown() async throws {
    manager.stopTimer()
    UserDefaults().removePersistentDomain(forName: suiteName)
    try await super.tearDown()
  }

  func testGivenDeferredProfileMigration_WhenLoadingWithoutActiveSession_ThenScheduleReconciled()
    throws
  {
    let now = Date()
    let profile = BlockedProfiles(
      name: "School",
      blockingStrategyId: ManualBlockingStrategy.id,
      schedule: BlockedProfileSchedule(
        days: [.monday],
        startHour: 9,
        startMinute: 0,
        endHour: 15,
        endMinute: 30,
        updatedAt: now
      )
    )
    profile.profileSchemaVersion = 1
    context.insert(profile)
    try context.save()

    var registeredProfileIds: [UUID] = []
    manager = StrategyManager(
      scheduleReconciler: { context in
        PreActivationReminderScheduler.reconcileScheduleRegistrations(
          context: context,
          notificationCenter: NotificationCenter(),
          register: { registeredProfileIds.append($0.id) }
        )
      })

    try manager.loadActiveSession(context: context)

    XCTAssertFalse(profile.needsMigration)
    XCTAssertEqual(registeredProfileIds, [profile.id])
  }

  func testGivenNoProfileMigration_WhenLoadingWithoutActiveSession_ThenScheduleNotReconciled()
    throws
  {
    var reconciliationCount = 0
    manager = StrategyManager(scheduleReconciler: { _ in reconciliationCount += 1 })

    try manager.loadActiveSession(context: context)

    XCTAssertEqual(reconciliationCount, 0)
  }

  // #237 / Design Q1: tapping Stop while the shared active session was swapped by the extension
  // must NOT end the stale on-screen session -- it reloads and surfaces instead.
  func testGivenSharedSessionSwapped_WhenToggleStop_ThenStaleSessionNotEndedAndSurfaced() throws {
    let profileA = BlockedProfiles(name: "A")
    context.insert(profileA)
    let sessionA = BlockedProfileSession(tag: "A", blockedProfile: profileA)
    context.insert(sessionA)
    try context.save()
    manager.activeSession = sessionA  // stale on-screen session
    // Extension swapped the shared active session to a different one (fresh id != sessionA.id).
    SharedData.createSessionForScheduler(for: UUID())
    XCTAssertNotEqual(
      SharedData.getActiveSharedSession()?.id, sessionA.id, "precondition: shared session swapped")

    manager.toggleBlocking(context: context, activeProfile: profileA)

    XCTAssertNil(sessionA.endTime, "the stale session must NOT be ended (#237 / Q1)")
    XCTAssertNotNil(manager.errorMessage, "the state change is surfaced to the user")
  }

  // Control: when the shared session matches the on-screen session, Stop proceeds normally.
  func testGivenMatchingSharedSession_WhenToggleStop_ThenSessionEnds() throws {
    let profile = BlockedProfiles(name: "Focus")
    context.insert(profile)
    let session = BlockedProfileSession(tag: "manual", blockedProfile: profile)
    context.insert(session)
    try context.save()
    manager.activeSession = session
    SharedData.createActiveSharedSession(for: session.toSnapshot())  // shared id == session.id

    manager.toggleBlocking(context: context, activeProfile: profile)

    XCTAssertNotNil(session.endTime, "a matching-identity Stop ends the session")
  }

  // Control: a missing shared session means the displayed session is still safe to stop normally.
  func testGivenNoSharedSession_WhenToggleStop_ThenSessionEndsWithoutScheduledTimerError() throws {
    let profile = BlockedProfiles(name: "Focus")
    context.insert(profile)
    let session = BlockedProfileSession(tag: "manual", blockedProfile: profile)
    context.insert(session)
    try context.save()
    manager.activeSession = session
    XCTAssertNil(SharedData.getActiveSharedSession(), "precondition: no shared session exists")

    manager.toggleBlocking(context: context, activeProfile: profile)

    XCTAssertNotNil(session.endTime, "nil SharedData falls through to normal Stop")
    XCTAssertNil(manager.errorMessage, "nil SharedData should not surface the scheduled-timer error")
  }
}
