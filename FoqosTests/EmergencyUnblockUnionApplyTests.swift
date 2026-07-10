import CloudKit
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class EmergencyUnblockUnionApplyTests: XCTestCase {

  private var container: ModelContainer!
  private var context: ModelContext!
  private var store: SyncEngineStore!
  private var emergencyManager: EmergencyUnblockManager!
  private var storeDefaults: UserDefaults!
  private var emgDefaults: UserDefaults!
  private var storeSuite: String!
  private var emgSuite: String!
  private let zoneID = CKRecordZone.ID(
    zoneName: CloudKitConstants.syncZoneName, ownerName: CKCurrentUserDefaultName)

  override func setUp() async throws {
    try await super.setUp()
    storeSuite = "UnionApply-store-\(UUID().uuidString)"
    emgSuite = "UnionApply-emg-\(UUID().uuidString)"
    storeDefaults = UserDefaults(suiteName: storeSuite)!
    emgDefaults = UserDefaults(suiteName: emgSuite)!
    SharedData.configure(suite: UserDefaults(suiteName: "UnionApply-shared-\(UUID().uuidString)")!)
    store = SyncEngineStore(userRecordName: "user-1", defaults: storeDefaults)
    container = try TestModelContainer.create()
    context = container.mainContext
    emergencyManager = EmergencyUnblockManager(defaults: emgDefaults)
    emergencyManager.seedForTesting(epoch: 1)
  }

  override func tearDown() async throws {
    storeDefaults.removePersistentDomain(forName: storeSuite)
    emgDefaults.removePersistentDomain(forName: emgSuite)
    try await super.tearDown()
  }

  private func makeService() -> SyncApplyService {
    SyncApplyService(
      modelContext: context,
      store: store,
      sessionController: MockSessionController(),
      emergencyManager: emergencyManager,
      deviceId: "device-A")
  }

  func testGivenRemoteUnblockEvent_WhenApplied_ThenMergedAndCountDrops() {
    let now = Date()
    let apply = makeService()
    let event = SyncedEmergencyUnblockEvent(id: UUID(), deviceId: "peer", consumedAt: now, resetEpoch: 1)
    let record = event.toCKRecord(in: zoneID)

    _ = apply.applyFetchedModification(record, isPendingDeleteOrTombstoned: { _ in false })
    XCTAssertEqual(emergencyManager.getRemainingEmergencyUnblocks(), 2)

    _ = apply.applyFetchedModification(record, isPendingDeleteOrTombstoned: { _ in false })
    XCTAssertEqual(emergencyManager.getRemainingEmergencyUnblocks(), 2, "idempotent union")
  }

  func testGivenRemoteEpoch_WhenApplied_ThenAdoptedByMaxRegardlessOfOrder() {
    let apply = makeService()

    _ = apply.applyFetchedModification(
      SyncedEmergencyEpoch(epoch: 3).toCKRecord(in: zoneID),
      isPendingDeleteOrTombstoned: { _ in false })
    XCTAssertEqual(emergencyManager.currentResetEpoch, 3, "higher epoch adopted")

    _ = apply.applyFetchedModification(
      SyncedEmergencyEpoch(epoch: 2).toCKRecord(in: zoneID),
      isPendingDeleteOrTombstoned: { _ in false })
    XCTAssertEqual(emergencyManager.currentResetEpoch, 3, "lower epoch never lowers it")
  }

  func testGivenUnblockEventDeletion_WhenApplied_ThenRemovedFromLedgerIdempotently() {
    let now = Date()
    let apply = makeService()
    let event = SyncedEmergencyUnblockEvent(id: UUID(), deviceId: "peer", consumedAt: now, resetEpoch: 1)
    _ = apply.applyFetchedModification(
      event.toCKRecord(in: zoneID), isPendingDeleteOrTombstoned: { _ in false })
    XCTAssertEqual(emergencyManager.getRemainingEmergencyUnblocks(), 2)

    let recordID = CKRecord.ID(recordName: event.recordName, zoneID: zoneID)
    let outcome = apply.applyFetchedDeletion(
      recordID: recordID, recordType: SyncedEmergencyUnblockEvent.recordType)

    XCTAssertEqual(outcome, .deleted)
    XCTAssertEqual(emergencyManager.getRemainingEmergencyUnblocks(), 3, "event removed from ledger")
    _ = apply.applyFetchedDeletion(recordID: recordID, recordType: SyncedEmergencyUnblockEvent.recordType)
    XCTAssertEqual(emergencyManager.getRemainingEmergencyUnblocks(), 3, "delete replay is idempotent")
  }

  func testGivenPeerPrunedBeforeEpochSeen_ThenNeverUnderCounts() {
    let now = Date()
    let apply = makeService()
    let e1 = SyncedEmergencyUnblockEvent(id: UUID(), deviceId: "peer", consumedAt: now, resetEpoch: 1)
    let e2 = SyncedEmergencyUnblockEvent(id: UUID(), deviceId: "peer", consumedAt: now, resetEpoch: 1)
    emergencyManager.mergeRemoteUnblockEvent(e1)
    emergencyManager.mergeRemoteUnblockEvent(e2)
    XCTAssertEqual(emergencyManager.getRemainingEmergencyUnblocks(), 1)

    _ = apply.applyFetchedDeletion(
      recordID: CKRecord.ID(recordName: e1.recordName, zoneID: zoneID),
      recordType: SyncedEmergencyUnblockEvent.recordType)
    _ = apply.applyFetchedDeletion(
      recordID: CKRecord.ID(recordName: e2.recordName, zoneID: zoneID),
      recordType: SyncedEmergencyUnblockEvent.recordType)

    XCTAssertGreaterThanOrEqual(
      emergencyManager.getRemainingEmergencyUnblocks(), 1,
      "deletions-before-epoch can only over-count, never wrongly deny")

    _ = apply.applyFetchedModification(
      SyncedEmergencyEpoch(epoch: 2).toCKRecord(in: zoneID),
      isPendingDeleteOrTombstoned: { _ in false })
    XCTAssertEqual(emergencyManager.getRemainingEmergencyUnblocks(), 3)
  }

  func testGivenEpochBumpArrivesWithoutEvents_ThenCountResetsAndOldEventsInert() {
    let now = Date()
    let apply = makeService()
    let e1 = SyncedEmergencyUnblockEvent(id: UUID(), deviceId: "peer", consumedAt: now, resetEpoch: 1)
    let e2 = SyncedEmergencyUnblockEvent(id: UUID(), deviceId: "peer", consumedAt: now, resetEpoch: 1)
    emergencyManager.mergeRemoteUnblockEvent(e1)
    emergencyManager.mergeRemoteUnblockEvent(e2)
    XCTAssertEqual(emergencyManager.getRemainingEmergencyUnblocks(), 1)

    _ = apply.applyFetchedModification(
      SyncedEmergencyEpoch(epoch: 2).toCKRecord(in: zoneID),
      isPendingDeleteOrTombstoned: { _ in false })

    XCTAssertEqual(emergencyManager.getRemainingEmergencyUnblocks(), 3)
    emergencyManager.mergeRemoteUnblockEvent(
      SyncedEmergencyUnblockEvent(id: UUID(), deviceId: "peer", consumedAt: now, resetEpoch: 1))
    XCTAssertEqual(emergencyManager.getRemainingEmergencyUnblocks(), 3, "old-epoch events are inert")
  }

  func testGivenEventsArriveBeforeEpoch_ThenCountedOnlyAfterEpochAdopted() {
    let now = Date()
    let apply = makeService()
    let event = SyncedEmergencyUnblockEvent(id: UUID(), deviceId: "peer", consumedAt: now, resetEpoch: 2)

    _ = apply.applyFetchedModification(
      event.toCKRecord(in: zoneID), isPendingDeleteOrTombstoned: { _ in false })
    XCTAssertEqual(
      emergencyManager.getRemainingEmergencyUnblocks(), 3,
      "future-epoch events are inert until the epoch record arrives")

    _ = apply.applyFetchedModification(
      SyncedEmergencyEpoch(epoch: 2).toCKRecord(in: zoneID),
      isPendingDeleteOrTombstoned: { _ in false })
    XCTAssertEqual(emergencyManager.getRemainingEmergencyUnblocks(), 2)
  }
}
