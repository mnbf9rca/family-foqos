import XCTest

@testable import FamilyFoqos

@MainActor
final class EmergencyUnblockConsumeTests: XCTestCase {

  private var emgSuite: String!
  private var emgDefaults: UserDefaults!
  private var savedController: (any SyncEngineControlling)?
  private var savedEnabled = false
  private var savedIsSyncReady = false
  private var mock: MockSyncEngineControlling!

  override func setUp() async throws {
    try await super.setUp()
    emgSuite = "Consume-emg-\(UUID().uuidString)"
    emgDefaults = UserDefaults(suiteName: emgSuite)!
    savedController = ProfileSyncManager.shared.engineController
    savedEnabled = ProfileSyncManager.shared.isEnabled
    savedIsSyncReady = ProfileSyncManager.shared.isSyncReady
    mock = MockSyncEngineControlling()
    ProfileSyncManager.shared.engineController = mock
    ProfileSyncManager.shared.isSyncReady = true
    ProfileSyncManager.shared.isEnabled = true
  }

  override func tearDown() async throws {
    ProfileSyncManager.shared.engineController = savedController
    ProfileSyncManager.shared.isSyncReady = savedIsSyncReady
    ProfileSyncManager.shared.isEnabled = savedEnabled
    emgDefaults.removePersistentDomain(forName: emgSuite)
    try await super.tearDown()
  }

  func testGivenSyncEnabled_WhenRecordAndEnqueueUnblock_ThenEventEnqueuedAndRemainingDrops() {
    let now = Date()
    let manager = EmergencyUnblockManager(defaults: emgDefaults, profileSyncManager: .shared)
    manager.seedForTesting(allowance: 3, epoch: 1)

    manager.recordAndEnqueueUnblock(now: now)

    XCTAssertEqual(manager.getRemainingEmergencyUnblocks(), 2)
    XCTAssertEqual(mock.enqueuedEmergencyUnblockEvents.count, 1, "one event pushed through the funnel")
    XCTAssertEqual(mock.enqueuedEmergencyUnblockEvents.first?.resetEpoch, 1)
  }

  func testGivenConsumedUnblocks_WhenReset_ThenEpochAdvancesAndRemainingRestored() {
    let now = Date()
    let manager = EmergencyUnblockManager(defaults: emgDefaults, profileSyncManager: .shared)
    manager.seedForTesting(allowance: 3, epoch: 1)
    manager.recordAndEnqueueUnblock(now: now)
    manager.recordAndEnqueueUnblock(now: now)
    XCTAssertEqual(manager.getRemainingEmergencyUnblocks(), 1)

    manager.resetEmergencyUnblocks()

    XCTAssertEqual(manager.currentResetEpoch, 2, "reset advances the epoch")
    XCTAssertEqual(manager.getRemainingEmergencyUnblocks(), 3, "prior-epoch events no longer count")
    XCTAssertEqual(mock.enqueuedEmergencyEpochSaves, 1, "reset pushes the monotonic-max epoch")
  }
}
