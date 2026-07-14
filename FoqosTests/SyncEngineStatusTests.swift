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

  func testPendingChangeCountCountsOutboundRecordAndDatabaseChanges() {
    let controller = makeStartedController()
    driver.setPendingRecordZoneChangesForTest([
      .saveRecord(recordID("save-1")),
      .deleteRecord(recordID("delete-1")),
    ])
    driver.setPendingDatabaseChangesForTest([.saveZone(CKRecordZone(zoneID: zoneID))])

    XCTAssertEqual(controller.pendingChangeCount, 3)
  }

  func testDidFetchStampsLastSyncAndFiresStatusHook() {
    let controller = makeStartedController()
    var ticks = 0
    controller.onStatusChanged = { ticks += 1 }

    XCTAssertNil(controller.lastSuccessfulSyncDate)
    controller.handle(.didFetchChanges)

    XCTAssertNotNil(controller.lastSuccessfulSyncDate)
    XCTAssertGreaterThanOrEqual(ticks, 1)
  }

  func testSentStampsLastSyncOnlyWithProgressAndNoFailure() {
    let controller = makeStartedController()

    controller.handle(
      .sentRecordZoneChanges(
        savedRecords: [], failedRecordSaves: [], deletedRecordIDs: [],
        failedRecordDeletes: []))
    XCTAssertNil(controller.lastSuccessfulSyncDate)

    controller.handle(
      .sentRecordZoneChanges(
        savedRecords: [sampleRecord()], failedRecordSaves: [], deletedRecordIDs: [],
        failedRecordDeletes: []))
    let afterProgress = controller.lastSuccessfulSyncDate
    XCTAssertNotNil(afterProgress)

    controller.handle(
      .sentRecordZoneChanges(
        savedRecords: [sampleRecord()],
        failedRecordSaves: [(sampleRecord(), CKError(.serviceUnavailable))],
        deletedRecordIDs: [], failedRecordDeletes: []))
    XCTAssertEqual(controller.lastSuccessfulSyncDate, afterProgress)
  }

  func testPrepareForAccountSwitchClearsLastSuccessfulSyncDate() {
    let controller = makeStartedController()
    stampLastSuccessfulSync(on: controller)
    XCTAssertNotNil(controller.lastSuccessfulSyncDate)

    controller.prepareForAccountSwitch()

    XCTAssertNil(controller.lastSuccessfulSyncDate)
  }

  func testStopClearsLastSuccessfulSyncDate() {
    let controller = makeStartedController()
    stampLastSuccessfulSync(on: controller)
    XCTAssertNotNil(controller.lastSuccessfulSyncDate)

    controller.stop()

    XCTAssertNil(controller.lastSuccessfulSyncDate)
  }

  func testPurgedZoneDeletionClearsLastSuccessfulSyncDate() {
    let controller = makeStartedController()
    stampLastSuccessfulSync(on: controller)
    XCTAssertNotNil(controller.lastSuccessfulSyncDate)

    controller.handle(
      .fetchedDatabaseChanges(
        modifiedZoneIDs: [], deletedZones: [(zoneID: zoneID, reason: .purged)]))

    XCTAssertNil(controller.lastSuccessfulSyncDate)
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

  private func recordID(_ name: String) -> CKRecord.ID {
    CKRecord.ID(recordName: name, zoneID: zoneID)
  }

  private func sampleRecord() -> CKRecord {
    let record = CKRecord(recordType: SyncedProfile.recordType, recordID: recordID(UUID().uuidString))
    record[SyncedProfile.FieldKey.profileId.rawValue] = UUID().uuidString
    record[SyncedProfile.FieldKey.name.rawValue] = "Profile"
    record[SyncedProfile.FieldKey.order.rawValue] = 0
    record[SyncedProfile.FieldKey.version.rawValue] = 1
    record[SyncedProfile.FieldKey.originDeviceId.rawValue] = "device-B"
    return record
  }

  private func stampLastSuccessfulSync(on controller: SyncEngineController) {
    controller.handle(.didFetchChanges)
  }
}
