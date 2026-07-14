import XCTest

@testable import FamilyFoqos

@MainActor
final class SyncStatusDerivationTests: XCTestCase {
  var testSuiteName: String!
  var manager: ProfileSyncManager!
  var mock: MockSyncEngineControlling!
  private var savedEnabled = false
  private var savedIsSyncReady = false
  private var savedController: (any SyncEngineControlling)?
  private var savedBufferDefaults: UserDefaults!

  override func setUp() async throws {
    try await super.setUp()
    testSuiteName = "SyncStatusDerivationTests-\(UUID().uuidString)"
    SharedData.configure(suite: UserDefaults(suiteName: testSuiteName)!)
    manager = ProfileSyncManager.shared
    savedEnabled = manager.isEnabled
    savedIsSyncReady = manager.isSyncReady
    savedController = manager.engineController
    savedBufferDefaults = manager.bufferDefaults
    manager.isSyncReady = false
    manager.isEnabled = false
    mock = MockSyncEngineControlling()
    manager.engineController = mock
  }

  override func tearDown() async throws {
    manager.engineController = savedController
    manager.isSyncReady = savedIsSyncReady
    manager.isEnabled = savedEnabled
    manager.bufferDefaults = savedBufferDefaults
    UserDefaults().removePersistentDomain(forName: testSuiteName)
    try await super.tearDown()
  }

  func testDeriveStatusPrecedence() {
    typealias Manager = ProfileSyncManager
    XCTAssertEqual(
      Manager.deriveStatus(
        isEnabled: false, pausedReason: nil, isInFlight: false, isOnline: true,
        pendingCount: 5),
      .disabled)
    XCTAssertEqual(
      Manager.deriveStatus(
        isEnabled: true, pausedReason: .signedOut, isInFlight: true, isOnline: true,
        pendingCount: 5),
      .paused(.signedOut))
    XCTAssertEqual(
      Manager.deriveStatus(
        isEnabled: true, pausedReason: nil, isInFlight: true, isOnline: true,
        pendingCount: 5),
      .syncing)
    XCTAssertEqual(
      Manager.deriveStatus(
        isEnabled: true, pausedReason: nil, isInFlight: false, isOnline: false,
        pendingCount: 5),
      .offline)
    XCTAssertEqual(
      Manager.deriveStatus(
        isEnabled: true, pausedReason: nil, isInFlight: false, isOnline: false,
        pendingCount: 0),
      .synced)
    XCTAssertEqual(
      Manager.deriveStatus(
        isEnabled: true, pausedReason: nil, isInFlight: false, isOnline: true,
        pendingCount: 3),
      .waiting(3))
    XCTAssertEqual(
      Manager.deriveStatus(
        isEnabled: true, pausedReason: nil, isInFlight: false, isOnline: true,
        pendingCount: 0),
      .synced)
  }

  func testSnapshotRepublishesWhenControllerFiresStatusHook() {
    manager.isEnabled = true
    mock.pendingChangeCount = 2
    mock.isInFlight = false
    mock.fireStatusChangedForTest()
    XCTAssertEqual(manager.syncStatusSnapshot.status, .waiting(2))

    mock.pendingChangeCount = 0
    mock.lastSuccessfulSyncDate = Date()
    mock.fireStatusChangedForTest()
    XCTAssertEqual(manager.syncStatusSnapshot.status, .synced)
    XCTAssertNotNil(manager.syncStatusSnapshot.lastSyncDate)
  }

  func testReconnectDrivesSyncNowWhenReady() {
    manager.isEnabled = true
    manager.isSyncReady = true

    manager.handleReachabilityPathUpdateForTest(isSatisfied: true)
    manager.handleReachabilityPathUpdateForTest(isSatisfied: false)
    manager.handleReachabilityPathUpdateForTest(isSatisfied: true)

    XCTAssertGreaterThanOrEqual(mock.requestSyncCount, 1)
  }

  func testDisableStopsMonitor() {
    manager.isEnabled = true
    XCTAssertTrue(manager.isReachabilityMonitoringForTest)

    manager.isEnabled = false

    XCTAssertFalse(manager.isReachabilityMonitoringForTest)
  }
}
