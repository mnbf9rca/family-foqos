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
          register: {
            registeredProfileIds.append($0.id)
            return []
          }
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

  // #237 / Design Q1: a stale Stop must not complete a different shared owner.
  func testGivenSharedSessionSwapped_WhenToggleStop_ThenReplacementRemainsAndChangeIsSurfaced() throws {
    let now = Date()
    let profileA = BlockedProfiles(name: "A")
    let profileB = BlockedProfiles(name: "B")
    context.insert(profileA)
    context.insert(profileB)
    let sessionA = BlockedProfileSession(tag: "A", blockedProfile: profileA, startTime: now.addingTimeInterval(-60))
    context.insert(sessionA)
    try context.save()
    manager.activeSession = sessionA
    let replacement = SharedData.SessionSnapshot(
      id: UUID().uuidString, tag: "schedule", blockedProfileId: profileB.id, startTime: now,
      forceStarted: true, origin: .init(kind: .schedule))
    SharedData.createActiveSharedSession(for: replacement)

    manager.toggleBlocking(context: context, activeProfile: profileA)

    XCTAssertEqual(SharedData.getActiveSharedSession(), replacement, "#237 / Q1")
    XCTAssertEqual(manager.activeSession?.id, replacement.id)
    XCTAssertNil(manager.activeSession?.endTime)
    XCTAssertTrue(SharedData.completedSessionsInScheduler.isEmpty)
    XCTAssertEqual(sessionA.endTime, now, "The obsolete row is archived at the replacement start")
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

  // An idle shared store must not make a local session impossible to stop.
  func testGivenNoSharedSession_WhenToggleStop_ThenLocalSessionEnds() throws {
    let profile = BlockedProfiles(name: "Focus")
    context.insert(profile)
    let session = BlockedProfileSession(tag: "manual", blockedProfile: profile)
    context.insert(session)
    try context.save()
    manager.activeSession = session
    XCTAssertNil(SharedData.getActiveSharedSession(), "precondition: no shared session exists")

    manager.toggleBlocking(context: context, activeProfile: profile)

    XCTAssertNotNil(session.endTime)
    XCTAssertNil(manager.activeSession)
    XCTAssertNil(manager.errorMessage)
  }
}
