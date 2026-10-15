import FoqosShared
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class ResetBlockingStateTests: XCTestCase {
  private var suiteName: String!
  override func setUp() async throws {
    suiteName = "ResetBlockingStateTests-\(UUID())"
    SharedData.configure(suite: UserDefaults(suiteName: suiteName)!)
  }
  override func tearDown() async throws {
    SharedData.resetLockPath()
    UserDefaults().removePersistentDomain(forName: suiteName)
  }

  func testResetRefusesExtensionOnlyActiveSessionWithoutEffects() throws {
    let now = Date()
    let container = try TestModelContainer.create()
    let context = container.mainContext
    let profile = BlockedProfiles(name: "Active", createdAt: now, updatedAt: now)
    context.insert(profile)
    try context.save()
    let live = SharedData.SessionSnapshot(id: UUID().uuidString, tag: "schedule", blockedProfileId: profile.id, startTime: now, forceStarted: true)
    SharedData.createActiveSharedSession(for: live)
    let applier = RecordingRestrictionApplier()
    var timerRemovals = 0
    let manager = StrategyManager(appBlocker: applier, removeAllStrategyTimers: { timerRemovals += 1 })

    manager.resetBlockingState(context: context)

    XCTAssertEqual(SharedData.getActiveSharedSession(), live)
    XCTAssertTrue(applier.calls.isEmpty)
    XCTAssertEqual(timerRemovals, 0)
  }

  func testResetRemovesOrphanSharedSession() throws {
    let now = Date()
    let container = try TestModelContainer.create()
    let ghost = SharedData.SessionSnapshot(id: UUID().uuidString, tag: "schedule", blockedProfileId: UUID(), startTime: now, forceStarted: true)
    SharedData.createActiveSharedSession(for: ghost)
    let manager = StrategyManager(appBlocker: RecordingRestrictionApplier(), removeAllStrategyTimers: {})

    manager.resetBlockingState(context: container.mainContext)

    XCTAssertNil(SharedData.getActiveSharedSession())
  }

  func testResetPreservesExtensionWinnerPublishedWhileWaitingForLock() throws {
    let now = Date()
    let container = try TestModelContainer.create()
    let context = container.mainContext
    let profile = BlockedProfiles(name: "Winner", createdAt: now, updatedAt: now)
    context.insert(profile)
    try context.save()
    let winner = SharedData.SessionSnapshot(id: UUID().uuidString, tag: "schedule", blockedProfileId: profile.id, startTime: now, forceStarted: true)
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
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
      // The extension writes while it owns the process-shared lock.
      SharedData.activeSharedSession = winner
      flock(fd, LOCK_UN)
    }
    let applier = RecordingRestrictionApplier()
    var timerRemovals = 0
    let manager = StrategyManager(appBlocker: applier, removeAllStrategyTimers: { timerRemovals += 1 })

    XCTAssertNil(manager.resetBlockingState(context: context))

    XCTAssertEqual(SharedData.getActiveSharedSession(), winner)
    XCTAssertTrue(applier.calls.isEmpty)
    XCTAssertEqual(timerRemovals, 0)
  }

  func testResetPreservesLocalActiveSessionEvenWithoutSharedSnapshot() throws {
    let now = Date()
    let container = try TestModelContainer.create()
    let context = container.mainContext
    let profile = BlockedProfiles(name: "Local", createdAt: now, updatedAt: now)
    context.insert(profile)
    let local = BlockedProfileSession(tag: "manual", blockedProfile: profile, startTime: now)
    context.insert(local)
    try context.save()
    let applier = RecordingRestrictionApplier()
    let manager = StrategyManager(appBlocker: applier, removeAllStrategyTimers: {})
    manager.activeSession = local

    XCTAssertNil(manager.resetBlockingState(context: context))

    XCTAssertEqual(manager.activeSession?.id, local.id)
    XCTAssertNil(local.endTime)
    XCTAssertTrue(applier.calls.isEmpty)
  }
}
