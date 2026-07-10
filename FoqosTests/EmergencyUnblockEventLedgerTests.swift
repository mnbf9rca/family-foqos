import XCTest

@testable import FamilyFoqos

@MainActor
final class EmergencyUnblockEventLedgerTests: XCTestCase {

  private var suiteName: String!
  private var defaults: UserDefaults!

  override func setUp() async throws {
    try await super.setUp()
    suiteName = "EmergencyLedger-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)!
  }

  override func tearDown() async throws {
    defaults.removePersistentDomain(forName: suiteName)
    try await super.tearDown()
  }

  func testGivenThreeAllowance_WhenTwoEventsInEpoch_ThenRemainingIsOne() {
    let now = Date()
    let manager = EmergencyUnblockManager(defaults: defaults)
    manager.seedForTesting(epoch: 1)

    _ = manager.consumeUnblockEvent(now: now)
    _ = manager.consumeUnblockEvent(now: now)

    XCTAssertEqual(manager.getRemainingEmergencyUnblocks(), 1)
  }

  func testGivenConcurrentEventsFromTwoDevices_WhenMerged_ThenBothCount() {
    let now = Date()
    let manager = EmergencyUnblockManager(defaults: defaults)
    manager.seedForTesting(epoch: 1)

    let localEvent = manager.consumeUnblockEvent(now: now)
    let remoteEvent = SyncedEmergencyUnblockEvent(
      id: UUID(), deviceId: "other", consumedAt: now, resetEpoch: 1)
    manager.mergeRemoteUnblockEvent(remoteEvent)

    XCTAssertEqual(manager.getRemainingEmergencyUnblocks(), 1, "two distinct events both count")
    XCTAssertNotEqual(localEvent.id, remoteEvent.id)
  }

  func testGivenReDeliveredEvent_WhenMergedTwice_ThenCountsOnce() {
    let now = Date()
    let manager = EmergencyUnblockManager(defaults: defaults)
    manager.seedForTesting(epoch: 1)
    let event = SyncedEmergencyUnblockEvent(
      id: UUID(), deviceId: "x", consumedAt: now, resetEpoch: 1)

    manager.mergeRemoteUnblockEvent(event)
    manager.mergeRemoteUnblockEvent(event)

    XCTAssertEqual(manager.getRemainingEmergencyUnblocks(), 2)
  }

  func testGivenOldEpochEvents_WhenEpochAdvances_ThenTheyStopCounting() {
    let now = Date()
    let manager = EmergencyUnblockManager(defaults: defaults)
    manager.seedForTesting(epoch: 1)

    _ = manager.consumeUnblockEvent(now: now)
    _ = manager.consumeUnblockEvent(now: now)
    manager.advanceResetEpochForTesting()

    XCTAssertEqual(manager.getRemainingEmergencyUnblocks(), 3, "prior-epoch events don't count")
  }

  func testRemainingClampsAtZero() {
    let now = Date()
    let manager = EmergencyUnblockManager(defaults: defaults)
    manager.seedForTesting(epoch: 1)

    for _ in 0..<5 {
      _ = manager.consumeUnblockEvent(now: now)
    }

    XCTAssertEqual(manager.getRemainingEmergencyUnblocks(), 0, "never negative")
  }
}
