import FoqosShared
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class OrphanedSessionCleanupTests: XCTestCase {
  private var suiteName: String!

  override func setUp() async throws {
    suiteName = "OrphanedSessionCleanupTests-\(UUID())"
    SharedData.configure(suite: UserDefaults(suiteName: suiteName)!)
  }

  override func tearDown() async throws {
    SharedData.resetLockPath()
    UserDefaults().removePersistentDomain(forName: suiteName)
  }

  func testFirstLoadRemovesGhostAndLaterLoadsDoNotRepeatRepair() throws {
    let now = Date()
    let container = try TestModelContainer.create()
    let missingProfile = UUID()
    let ghost = SharedData.SessionSnapshot(id: UUID().uuidString, tag: "schedule", blockedProfileId: missingProfile, startTime: now, forceStarted: true, origin: .init(kind: .schedule))
    SharedData.createActiveSharedSession(for: ghost)
    let manager = StrategyManager()
    defer { manager.stopTimer() }

    try manager.loadActiveSession(context: container.mainContext)

    XCTAssertNil(SharedData.getActiveSharedSession())
    XCTAssertNil(manager.activeSession)
    SharedData.createActiveSharedSession(for: ghost)
    try manager.loadActiveSession(context: container.mainContext)
    XCTAssertEqual(SharedData.getActiveSharedSession(), ghost, "Repair must not recur during a later transient empty generation")
    let relaunched = StrategyManager()
    defer { relaunched.stopTimer() }
    try relaunched.loadActiveSession(context: container.mainContext)
    XCTAssertNil(SharedData.getActiveSharedSession(), "A new app launch must repair new orphans too")
  }

  func testFailedRepairLeavesGhostAndRetriesOnNextLoad() throws {
    let now = Date()
    let container = try TestModelContainer.create()
    let ghost = SharedData.SessionSnapshot(id: UUID().uuidString, tag: "schedule", blockedProfileId: UUID(), startTime: now, forceStarted: true)
    SharedData.createActiveSharedSession(for: ghost)
    let manager = StrategyManager()
    defer { manager.stopTimer() }
    SharedData.configureLockPath(nil)

    XCTAssertThrowsError(try manager.loadActiveSession(context: container.mainContext))
    XCTAssertEqual(SharedData.getActiveSharedSession(), ghost)
    SharedData.resetLockPath()
    try manager.loadActiveSession(context: container.mainContext)
    XCTAssertNil(SharedData.getActiveSharedSession())
  }

  func testRepairPreservesLiveOwnerAndDeletesLocalAndCompletedOrphans() throws {
    let now = Date()
    let container = try TestModelContainer.create()
    let context = container.mainContext
    let retained = BlockedProfiles(name: "Keep", createdAt: now, updatedAt: now)
    let deleted = BlockedProfiles(name: "Gone", createdAt: now, updatedAt: now)
    context.insert(retained)
    context.insert(deleted)
    let live = BlockedProfileSession(tag: "manual", blockedProfile: retained, startTime: now)
    let orphan = BlockedProfileSession(tag: "schedule", blockedProfile: deleted, startTime: now)
    context.insert(live)
    context.insert(orphan)
    try context.save()
    let deletedId = deleted.id
    var ended = orphan.toSnapshot()
    ended.endTime = now
    SharedData.completedSessionsInScheduler = [ended]
    SharedData.createActiveSharedSession(for: live.toSnapshot())
    BlockedProfiles.updateSnapshot(for: deleted)
    BlockedProfiles.updateSnapshot(for: retained)
    context.delete(deleted)
    try context.save()
    var canceled: [UUID] = []
    var deactivations = 0

    try OrphanedSessionCleanup.run(
      context: context, removeActivities: { canceled.append($0) },
      deactivateRestrictions: { deactivations += 1 })

    XCTAssertEqual(try context.fetch(FetchDescriptor<BlockedProfileSession>()).map(\.id), [live.id])
    XCTAssertEqual(SharedData.getActiveSharedSession(), live.toSnapshot())
    XCTAssertTrue(SharedData.completedSessionsInScheduler.isEmpty)
    XCTAssertNil(SharedData.snapshot(for: deletedId.uuidString))
    XCTAssertNotNil(SharedData.snapshot(for: retained.id.uuidString))
    XCTAssertEqual(canceled, [deletedId])
    XCTAssertEqual(deactivations, 0)
  }

  func testSaveFailureIsReportedAndRepairCanRetry() throws {
    struct SaveFailure: Error {}
    let container = try TestModelContainer.create()
    XCTAssertThrowsError(try OrphanedSessionCleanup.run(context: container.mainContext, save: { _ in throw SaveFailure() }))
    try OrphanedSessionCleanup.run(context: container.mainContext)
  }

  func testLaunchCleanupDoesNotWaitForAnExtensionLock() throws {
    let container = try TestModelContainer.create()
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    let fd = open(path, O_CREAT | O_RDWR, 0o600)
    XCTAssertGreaterThanOrEqual(fd, 0)
    guard fd >= 0 else { return }
    defer {
      flock(fd, LOCK_UN)
      close(fd)
      unlink(path)
    }
    XCTAssertEqual(flock(fd, LOCK_EX), 0)
    SharedData.configureLockPath(path)
    let clock = ContinuousClock()
    let start = clock.now

    XCTAssertThrowsError(try OrphanedSessionCleanup.run(context: container.mainContext))

    XCTAssertLessThan(start.duration(to: clock.now), .milliseconds(250))
  }
}
