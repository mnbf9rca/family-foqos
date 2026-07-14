import CloudKit
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class SyncEngineStatusTests: XCTestCase {
  var suiteName: String!
  var defaults: UserDefaults!
  var container: ModelContainer!
  var context: ModelContext!
  var store: SyncEngineStore!
  var driver: MockSyncEngineDriver!
  var apply: SyncApplyService!
  var provider: RecordProvider!
  var emergencyManager: EmergencyUnblockManager!
  var sessionSync: MockSessionSyncFlushing!
  var sessionController: MockSessionController!
  var profileDeleteCommitScheduler: ManualProfileDeleteCommitScheduler!
  let deviceId = "device-A"
  let userRecordName = "user-A"
  let zoneID = CKRecordZone.ID(
    zoneName: CloudKitConstants.syncZoneName, ownerName: CKCurrentUserDefaultName)

  override func setUp() async throws {
    try await super.setUp()
    suiteName = "SyncEngineStatusTests-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)!
    SharedData.configure(suite: defaults)
    container = try TestModelContainer.create()
    context = container.mainContext
    store = SyncEngineStore(userRecordName: userRecordName, defaults: defaults)
    driver = MockSyncEngineDriver()
    sessionController = MockSessionController()
    profileDeleteCommitScheduler = ManualProfileDeleteCommitScheduler()
    emergencyManager = EmergencyUnblockManager(defaults: defaults)
    apply = SyncApplyService(
      modelContext: context, store: store, sessionController: sessionController,
      emergencyManager: emergencyManager, deviceId: deviceId,
      scheduleProfileDeleteCommit: profileDeleteCommitScheduler.schedule)
    provider = RecordProvider(
      modelContext: context, store: store, emergencyManager: emergencyManager, deviceId: deviceId)
    sessionSync = MockSessionSyncFlushing()
    SyncConflictManager.shared.clearAll()
  }

  override func tearDown() async throws {
    SyncConflictManager.shared.clearAll()
    UserDefaults().removePersistentDomain(forName: suiteName)
    try await super.tearDown()
  }

  func testInFlightTracksSendAndFetchBrackets() {
    let controller = makeStartedController()

    XCTAssertFalse(controller.isInFlight)
    controller.handle(.willSendChanges)
    XCTAssertTrue(controller.isInFlight)
    controller.handle(
      .sentRecordZoneChanges(
        savedRecords: [], failedRecordSaves: [], deletedRecordIDs: [],
        failedRecordDeletes: []))
    controller.handle(.didSendChanges)
    XCTAssertFalse(controller.isInFlight)

    controller.handle(.willFetchChanges)
    XCTAssertTrue(controller.isInFlight)
    controller.handle(.didFetchChanges)
    XCTAssertFalse(controller.isInFlight)
  }

  private func makeStartedController() -> SyncEngineController {
    let controller = SyncEngineController(
      modelContext: context,
      store: store,
      driverFactory: { [driver] _ in driver! },
      apply: apply,
      provider: provider,
      sessionSync: sessionSync,
      deviceId: deviceId)
    controller.start()
    return controller
  }
}
