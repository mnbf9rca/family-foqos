@preconcurrency import FoqosShared
import XCTest

@testable import FamilyFoqos

final class SharedDataLockTests: XCTestCase {

  private static let testSuiteName = "SharedDataLockTests-\(UUID().uuidString)"

  override func setUp() {
    super.setUp()
    SharedData.configure(
      suite: UserDefaults(suiteName: Self.testSuiteName)!
    )
  }

  override func tearDown() {
    UserDefaults().removePersistentDomain(forName: Self.testSuiteName)
    super.tearDown()
  }

  func testGivenTwoSnapshots_WhenSettingAndRemovingSequentially_ThenNoDeadlock() {
    // Given: two snapshots
    let id1 = UUID()
    let id2 = UUID()
    let snapshot1 = makeSnapshot(id: id1, name: "Profile 1")
    let snapshot2 = makeSnapshot(id: id2, name: "Profile 2")

    // When: set and remove sequentially (exercises lock acquire/release cycle)
    SharedData.setSnapshot(snapshot1, for: id1.uuidString)
    SharedData.setSnapshot(snapshot2, for: id2.uuidString)
    SharedData.removeSnapshot(for: id1.uuidString)

    // Then: only snapshot2 remains
    let remaining = SharedData.profileSnapshots
    XCTAssertNil(remaining[id1.uuidString])
    XCTAssertNotNil(remaining[id2.uuidString])
  }

  func testGivenManyConcurrentWrites_WhenWritingSnapshots_ThenPreservesAllEntries() {
    // NOTE: Uses GCD to simulate concurrent writes within a single process.
    // True cross-process testing (main app vs DeviceActivity extension) is
    // impractical in XCTest, but the POSIX flock() mechanism is identical
    // in-process and cross-process, so this validates the lock behavior.

    // Given: many concurrent writes to different keys
    let count = 50
    let ids = (0..<count).map { _ in UUID() }
    let group = DispatchGroup()

    // When: write all concurrently
    for (i, id) in ids.enumerated() {
      let snapshot = makeSnapshot(id: id, name: "Profile \(i)")
      group.enter()
      DispatchQueue.global().async {
        SharedData.setSnapshot(snapshot, for: id.uuidString)
        group.leave()
      }
    }
    let result = group.wait(timeout: .now() + 10)
    XCTAssertEqual(result, .success, "Concurrent writes timed out — possible deadlock")

    // Then: all entries present (no lost writes)
    let all = SharedData.profileSnapshots
    for id in ids {
      XCTAssertNotNil(all[id.uuidString], "Snapshot for \(id) should exist")
    }
  }

  func testGivenActiveSession_WhenEndingSession_ThenAtomicallyMovesToCompleted() {
    // Given: an active session
    let profileId = UUID()
    SharedData.createSessionForScheduler(for: profileId)
    XCTAssertNotNil(SharedData.getActiveSharedSession())

    // When: end the session
    SharedData.endActiveSharedSession()

    // Then: session moved to completed, active is nil
    XCTAssertNil(SharedData.getActiveSharedSession())
    let completed = SharedData.getAndFlushCompletedSessionsForScheduler()
    XCTAssertEqual(completed.count, 1)
    XCTAssertEqual(completed.first?.blockedProfileId, profileId)
  }

  func testGivenTwoCompletedSessions_WhenFlushingAtomically_ThenReturnsBothAndClears() {
    // Given: two completed sessions
    let profileId1 = UUID()
    let profileId2 = UUID()
    SharedData.createSessionForScheduler(for: profileId1)
    SharedData.endActiveSharedSession()
    SharedData.createSessionForScheduler(for: profileId2)
    SharedData.endActiveSharedSession()

    // When: atomic get-and-flush
    let flushed = SharedData.getAndFlushCompletedSessionsForScheduler()

    // Then: returns both sessions and clears storage
    XCTAssertEqual(flushed.count, 2)
    guard flushed.count == 2 else {
      return
    }
    XCTAssertEqual(flushed[0].blockedProfileId, profileId1)
    XCTAssertEqual(flushed[1].blockedProfileId, profileId2)
    XCTAssertTrue(SharedData.getAndFlushCompletedSessionsForScheduler().isEmpty)
  }

  // MARK: - Error paths (withLock graceful degradation)

  func testGivenNilLockPath_WhenWritingSnapshot_ThenProceedsUnlocked() {
    // Given: force nil lockPath (simulates missing app group container)
    SharedData.configureLockPath(nil)
    defer { SharedData.resetLockPath() }

    // When: write a snapshot (exercises withLock with nil lockPath)
    let id = UUID()
    let snapshot = makeSnapshot(id: id, name: "NilLock")
    SharedData.setSnapshot(snapshot, for: id.uuidString)

    // Then: snapshot was written despite no lock
    let retrieved = SharedData.snapshot(for: id.uuidString)
    XCTAssertEqual(retrieved?.name, "NilLock")
  }

  func testGivenInvalidLockPath_WhenWritingSnapshot_ThenProceedsUnlocked() {
    // Given: lock path in nonexistent directory (open() will fail with ENOENT)
    SharedData.configureLockPath("/nonexistent/directory/lock")
    defer { SharedData.resetLockPath() }

    // When: write a snapshot (exercises withLock with open() failure)
    let id = UUID()
    let snapshot = makeSnapshot(id: id, name: "BadPath")
    SharedData.setSnapshot(snapshot, for: id.uuidString)

    // Then: snapshot was written despite lock failure
    let retrieved = SharedData.snapshot(for: id.uuidString)
    XCTAssertEqual(retrieved?.name, "BadPath")
  }

  // MARK: - Public withLock entry point (Task 3, #267)

  func testGivenReturningClosure_WhenRunUnderWithLock_ThenReturnsBodyResult() {
    let result = SharedData.withLock { 40 + 2 }
    XCTAssertEqual(result, 42)
  }

  func testGivenMutatingClosure_WhenRunUnderWithLock_ThenSideEffectApplied() {
    var counter = 0
    SharedData.withLock { counter += 1 }
    XCTAssertEqual(counter, 1)
  }

  // MARK: - Helpers

  private func makeSnapshot(id: UUID, name: String) -> SharedData.ProfileSnapshot {
    SharedData.ProfileSnapshot(
      id: id,
      name: name,
      selectedActivity: .init(),
      createdAt: Date(),
      updatedAt: Date(),
      order: 0,
      enableLiveActivity: false,
      enableBreaks: false,
      enableStrictMode: false,
      enableAllowMode: false,
      enableAllowModeDomains: false,
      enableSafariBlocking: false
    )
  }
}
