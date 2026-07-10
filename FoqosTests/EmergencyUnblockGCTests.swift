import XCTest

@testable import FamilyFoqos

@MainActor
final class EmergencyUnblockGCTests: XCTestCase {

  private var emgSuite: String!
  private var emgDefaults: UserDefaults!
  private var savedController: (any SyncEngineControlling)?
  private var savedEnabled = false
  private var savedIsSyncReady = false
  private var mock: MockSyncEngineControlling!

  override func setUp() async throws {
    try await super.setUp()
    emgSuite = "GC-emg-\(UUID().uuidString)"
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

  func testGivenStaleEpochEvents_WhenGC_ThenRemovedLocallyAndDeletesEnqueued() {
    let now = Date()
    let manager = EmergencyUnblockManager(defaults: emgDefaults, profileSyncManager: .shared)
    manager.seedForTesting(allowance: 3, epoch: 1)
    let e1 = manager.consumeUnblockEvent(now: now)
    let e2 = manager.consumeUnblockEvent(now: now)
    manager.advanceResetEpochForTesting()

    manager.garbageCollectStaleUnblockEvents()

    XCTAssertEqual(mock.enqueuedEmergencyUnblockEventDeletes.count, 2, "one delete per stale event")
    XCTAssertTrue(mock.enqueuedEmergencyUnblockEventDeletes.contains(e1.recordName))
    XCTAssertTrue(mock.enqueuedEmergencyUnblockEventDeletes.contains(e2.recordName))
    XCTAssertTrue(manager.staleUnblockEventRecordNames().isEmpty, "stale events pruned locally")
  }
}
