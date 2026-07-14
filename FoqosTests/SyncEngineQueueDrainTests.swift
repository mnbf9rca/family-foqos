import CloudKit
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class SyncEngineQueueDrainTests: XCTestCase {
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
    suiteName = "SyncEngineQueueDrainTests-\(UUID().uuidString)"
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

  func testRetriableReAddSchedulesADrainSend() async {
    let controller = makeStartedController()
    controller.setQueueDrainDelayForTest(0)
    driver.reset()

    controller.handle(
      .sentRecordZoneChanges(
        savedRecords: [],
        failedRecordSaves: [(sampleRecord(), CKError(.serviceUnavailable))],
        deletedRecordIDs: [], failedRecordDeletes: []))
    await controller.drainTaskForTest?.value

    XCTAssertGreaterThanOrEqual(driver.sendChangesCount, 1)
  }

  func testDrainDoesNotSendWhenNothingReAdded() async {
    let controller = makeStartedController()
    controller.setQueueDrainDelayForTest(0)
    driver.reset()

    controller.handle(
      .sentRecordZoneChanges(
        savedRecords: [sampleRecord()], failedRecordSaves: [], deletedRecordIDs: [],
        failedRecordDeletes: []))
    await controller.drainTaskForTest?.value

    XCTAssertEqual(driver.sendChangesCount, 0)
  }

  func testFetchSideReAddAlsoDrainsOnDidFetchChanges() async {
    let id = UUID()
    let local = BlockedProfiles(id: id, name: "Local", syncVersion: 5)
    context.insert(local)
    try? context.save()
    let controller = makeStartedController()
    controller.setQueueDrainDelayForTest(0)
    let remoteRecord = makeProfileRecord(id: id, version: 5, name: "Remote")
    remoteRecord[SyncedProfile.FieldKey.updatedAt.rawValue] = local.updatedAt.addingTimeInterval(-10)

    controller.handle(.fetchedRecordZoneChanges(modifications: [remoteRecord], deletions: []))
    driver.reset()
    controller.handle(.didFetchChanges)
    await controller.drainTaskForTest?.value

    XCTAssertGreaterThanOrEqual(driver.sendChangesCount, 1)
  }

  func testDrainGatedOffWhenNonOperational() async {
    let controller = makeStartedController()
    controller.setQueueDrainDelayForTest(0)
    controller.forceStateForTest(.disabled)
    driver.reset()

    controller.handle(
      .sentRecordZoneChanges(
        savedRecords: [],
        failedRecordSaves: [(sampleRecord(), CKError(.serviceUnavailable))],
        deletedRecordIDs: [], failedRecordDeletes: []))
    await controller.drainTaskForTest?.value

    XCTAssertEqual(driver.sendChangesCount, 0)
  }

  func testStopCancelsPendingDrainAndClearsInFlight() {
    let controller = makeStartedController()
    controller.setQueueDrainDelayForTest(1_000_000_000)
    controller.handle(.willSendChanges)
    controller.handle(
      .sentRecordZoneChanges(
        savedRecords: [],
        failedRecordSaves: [(sampleRecord(), CKError(.serviceUnavailable))],
        deletedRecordIDs: [], failedRecordDeletes: []))

    controller.stop()

    XCTAssertNil(controller.drainTaskForTest)
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
    controller.startupTask?.cancel()
    return controller
  }

  private func recordID(_ name: String) -> CKRecord.ID {
    CKRecord.ID(recordName: name, zoneID: zoneID)
  }

  private func sampleRecord() -> CKRecord {
    makeProfileRecord(id: UUID(), version: 1)
  }

  private func makeProfileRecord(id: UUID, version: Int, name: String = "Profile") -> CKRecord {
    let profile = BlockedProfiles(id: id, name: name, syncVersion: version)
    let synced = SyncedProfile(from: profile, originDeviceId: "device-B")
    return synced.toCKRecord(in: zoneID)
  }
}
