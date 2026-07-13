import CloudKit
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class SyncEngineFacadeInvariantTests: XCTestCase {
  var suiteName: String!
  var defaults: UserDefaults!
  var container: ModelContainer!
  var context: ModelContext!
  var manager: ProfileSyncManager!
  var savedEnabled = false
  var savedIsSyncReady = false
  var savedController: (any SyncEngineControlling)?
  var savedBufferDefaults: UserDefaults!
  let syncZoneID = CKRecordZone.ID(
    zoneName: CloudKitConstants.syncZoneName, ownerName: CKCurrentUserDefaultName)

  override func setUp() async throws {
    try await super.setUp()
    suiteName = "SyncEngineFacadeInvariantTests-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)!
    SharedData.configure(suite: defaults)
    container = try TestModelContainer.create()
    context = container.mainContext
    manager = ProfileSyncManager.shared
    savedEnabled = manager.isEnabled
    savedIsSyncReady = manager.isSyncReady
    savedController = manager.engineController
    savedBufferDefaults = manager.bufferDefaults
    manager.engineController = nil
    manager.isSyncReady = false
    manager.isEnabled = false
    manager.clearAccountChangeStateForTest()
  }

  override func tearDown() async throws {
    manager.engineController = savedController
    manager.isSyncReady = savedIsSyncReady
    manager.isEnabled = savedEnabled
    manager.bufferDefaults = savedBufferDefaults
    manager.clearAccountChangeStateForTest()
    UserDefaults().removePersistentDomain(forName: suiteName)
    try await super.tearDown()
  }

  func testDisabledNeverHasLiveDriver_userDisable() throws {
    let (controller, _) = makeController()
    controller.start()
    controller.stop()

    XCTAssertEqual(controller.state, .disabled)
    XCTAssertFalse(controller.hasLiveDriver)
  }

  func testPurgedNeverHasLiveDriver() throws {
    let (controller, _) = makeController()
    controller.start()

    controller.handle(
      .fetchedDatabaseChanges(
        modifiedZoneIDs: [], deletedZones: [(zoneID: syncZoneID, reason: .purged)]))

    XCTAssertEqual(controller.state, .purged)
    XCTAssertFalse(controller.hasLiveDriver)
  }

  func testSignOutPauseNeverHasLiveDriver() throws {
    let (controller, _) = makeController()
    controller.start()

    controller.handle(.accountChange(kind: .signOut))

    XCTAssertEqual(controller.state, .disabled)
    XCTAssertFalse(controller.hasLiveDriver)
  }

  func testConfirmedDifferentUserLeavesNoLiveDriver() throws {
    let (controller, _) = makeController()
    controller.start()

    controller.prepareForAccountSwitch()

    XCTAssertEqual(controller.state, .disabled)
    XCTAssertFalse(controller.hasLiveDriver)
  }

  func testConfirmedSameUserReturnsToOperational() async throws {
    let driver = MockSyncEngineDriver()
    manager.isEnabled = false
    await manager.attachEngine(
      modelContext: context,
      emergencyManager: EmergencyUnblockManager(defaults: defaults),
      userRecordNameProvider: { "userA" },
      driverFactory: { _ in driver })
    manager.isEnabled = true
    let controller = try XCTUnwrap(manager.engineController as? SyncEngineController)
    await controller.startupTask?.value
    controller.stop()

    manager.resetAccountChangeDebugCountersForTest()
    manager.resolveAccountChange(
      availability: .available(CKRecord.ID(recordName: "userA")), newName: "userA")
    await (manager.engineController as? SyncEngineController)?.startupTask?.value

    let restarted = try XCTUnwrap(manager.engineController as? SyncEngineController)
    XCTAssertTrue(restarted.state == .bootstrapping || restarted.state == .steady)
  }

  private func makeController() -> (SyncEngineController, MockSyncEngineDriver) {
    let store = SyncEngineStore(userRecordName: "userA", defaults: defaults)
    let driver = MockSyncEngineDriver()
    let emergencyManager = EmergencyUnblockManager(defaults: defaults)
    let apply = SyncApplyService(
      modelContext: context, store: store, sessionController: MockSessionController(),
      emergencyManager: emergencyManager, deviceId: "device-A")
    let provider = RecordProvider(
      modelContext: context, store: store, emergencyManager: emergencyManager, deviceId: "device-A")
    let controller = SyncEngineController(
      modelContext: context,
      store: store,
      driverFactory: { _ in driver },
      apply: apply,
      provider: provider,
      sessionSync: MockSessionSyncFlushing(),
      deviceId: "device-A")
    return (controller, driver)
  }
}
