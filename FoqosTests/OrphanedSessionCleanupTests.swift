import FoqosShared
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class OrphanedSessionCleanupTests: XCTestCase {
  private var suiteName: String!
  private var previousMarker: Any?
  private let marker = "family_foqos_orphaned_session_cleanup_v1"

  override func setUp() async throws {
    suiteName = "OrphanedSessionCleanupTests-\(UUID())"
    SharedData.configure(suite: UserDefaults(suiteName: suiteName)!)
    previousMarker = UserDefaults.standard.object(forKey: marker)
    UserDefaults.standard.removeObject(forKey: marker)
  }

  override func tearDown() async throws {
    SharedData.resetLockPath()
    UserDefaults().removePersistentDomain(forName: suiteName)
    if let previousMarker { UserDefaults.standard.set(previousMarker, forKey: marker) } else { UserDefaults.standard.removeObject(forKey: marker) }
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
    XCTAssertFalse(UserDefaults.standard.bool(forKey: marker))
    SharedData.resetLockPath()
    try manager.loadActiveSession(context: container.mainContext)
    XCTAssertNil(SharedData.getActiveSharedSession())
    XCTAssertTrue(UserDefaults.standard.bool(forKey: marker))
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

    try OrphanedSessionCleanup.runIfNeeded(
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

  func testSaveFailureDoesNotMarkRepairComplete() throws {
    struct SaveFailure: Error {}
    let container = try TestModelContainer.create()
    XCTAssertThrowsError(try OrphanedSessionCleanup.runIfNeeded(context: container.mainContext, save: { _ in throw SaveFailure() }))
    XCTAssertFalse(UserDefaults.standard.bool(forKey: marker))
    try OrphanedSessionCleanup.runIfNeeded(context: container.mainContext)
    XCTAssertTrue(UserDefaults.standard.bool(forKey: marker))
  }
}
