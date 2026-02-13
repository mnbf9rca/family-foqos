import XCTest

@testable import FamilyFoqos

final class SharedDataLockTests: XCTestCase {

  override func setUp() {
    super.setUp()
    // Clean slate for each test
    SharedData.flushActiveSession()
    SharedData.flushCompletedSessionsForSchedular()
  }

  func testSequentialSnapshotOperationsDoNotDeadlock() {
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

    // Cleanup
    SharedData.removeSnapshot(for: id2.uuidString)
  }

  func testConcurrentSnapshotWritesPreserveAllEntries() {
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
    group.wait()

    // Then: all entries present (no lost writes)
    let all = SharedData.profileSnapshots
    for id in ids {
      XCTAssertNotNil(all[id.uuidString], "Snapshot for \(id) should exist")
    }

    // Cleanup
    for id in ids {
      SharedData.removeSnapshot(for: id.uuidString)
    }
  }

  func testEndActiveSharedSessionIsAtomic() {
    // Given: an active session
    let profileId = UUID()
    SharedData.createSessionForSchedular(for: profileId)
    XCTAssertNotNil(SharedData.getActiveSharedSession())

    // When: end the session
    SharedData.endActiveSharedSession()

    // Then: session moved to completed, active is nil
    XCTAssertNil(SharedData.getActiveSharedSession())
    let completed = SharedData.getCompletedSessionsForSchedular()
    XCTAssertEqual(completed.count, 1)
    XCTAssertEqual(completed.first?.blockedProfileId, profileId)

    // Cleanup
    SharedData.flushCompletedSessionsForSchedular()
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
