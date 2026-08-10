import CloudKit
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class WipeInterleavingTests: XCTestCase {
  private var suiteName: String!
  private var defaults: UserDefaults!
  private var container: ModelContainer!
  private var context: ModelContext!
  private var store: SyncEngineStore!
  private var sessionController: MockSessionController!
  private var emergencyManager: EmergencyUnblockManager!
  private var manager: ProfileSyncManager!
  private var savedEnabled = false
  private var savedIsSyncReady = false
  private var savedController: (any SyncEngineControlling)?

  private let deviceId = "device-A"
  private let zoneID = CKRecordZone.ID(
    zoneName: CloudKitConstants.syncZoneName, ownerName: CKCurrentUserDefaultName)

  override func setUp() async throws {
    try await super.setUp()
    suiteName = "WipeInterleavingTests-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)!
    SharedData.configure(suite: defaults)
    container = try TestModelContainer.create()
    context = container.mainContext
    store = SyncEngineStore(userRecordName: "apply-user", defaults: defaults)
    sessionController = MockSessionController()
    emergencyManager = EmergencyUnblockManager(defaults: defaults)
    manager = ProfileSyncManager.shared
    savedEnabled = manager.isEnabled
    savedIsSyncReady = manager.isSyncReady
    savedController = manager.engineController
    manager.engineController = nil
    manager.isSyncReady = false
    manager.isEnabled = false
    manager.clearAccountChangeStateForTest()
    await manager.attachEngine(
      modelContext: context,
      emergencyManager: emergencyManager,
      userRecordNameProvider: { "apply-user" },
      driverFactory: { _ in MockSyncEngineDriver() },
      storeDefaults: defaults)
  }

  override func tearDown() async throws {
    manager.engineController = savedController
    manager.isSyncReady = savedIsSyncReady
    manager.isEnabled = savedEnabled
    manager.clearAccountChangeStateForTest()
    UserDefaults().removePersistentDomain(forName: suiteName)
    try await super.tearDown()
  }

  func testSW1OfflinePendingSaveStampedAtOldGenerationIsDeadWorldAfterAdoption() async throws {
    let id = UUID()
    let oldGenerationRecord = makeProfileRecord(id: id, name: "Queued Offline Edit", generation: 1)
    store.engineState = Data([0x01])

    await manager.adoptEstablishmentGeneration(2)

    let outcome = makeApplyService().applyFetchedModification(
      oldGenerationRecord, isPendingDeleteOrTombstoned: noPendingDelete)

    XCTAssertNil(store.engineState, "adoption must force a token-less refetch")
    XCTAssertEqual(outcome, .skippedDeadWorld)
    XCTAssertNil(try BlockedProfiles.findProfile(byID: id, in: context))
  }

  func testSW2SecondWipeWhileResetIntentExistsDoesNotClobberOriginalIntent() {
    let now = Date()
    let outbox = MockResetOutbox()
    let controller = makeResetController(outbox: outbox)

    controller.beginReset(wipe: true, clearRemoteAppSelections: false, now: now)
    let originalIntent = store.resetIntent

    controller.beginReset(wipe: true, clearRemoteAppSelections: false, now: now)

    XCTAssertEqual(store.resetIntent, originalIntent)
    XCTAssertEqual(outbox.zoneDeleteCount, 1)
  }

  func testSW3NewerGenerationRecordRedeliveredAfterForcedRefetchMaterializes() async throws {
    let id = UUID()
    let currentGenerationRecord = makeProfileRecord(id: id, name: "After Wipe", generation: 2)
    store.establishmentGeneration = 1
    store.engineState = Data([0x01])
    let service = makeApplyService()

    let firstOutcome = service.applyFetchedModification(
      currentGenerationRecord, isPendingDeleteOrTombstoned: noPendingDelete)

    XCTAssertEqual(firstOutcome, .skippedNewerGeneration)
    XCTAssertNil(try BlockedProfiles.findProfile(byID: id, in: context))

    await manager.adoptEstablishmentGeneration(2)

    let redeliveredOutcome = service.applyFetchedModification(
      currentGenerationRecord, isPendingDeleteOrTombstoned: noPendingDelete)

    XCTAssertNil(store.engineState, "the adoption reattach must start from nil serialization")
    XCTAssertEqual(redeliveredOutcome, .applied)
    XCTAssertEqual(try BlockedProfiles.findProfile(byID: id, in: context)?.name, "After Wipe")
  }

  func testSW4GenerationAdoptionClearsTombstoneAndFailedApplyForRecreatedRecord() async throws {
    let id = UUID()
    let recordName = id.uuidString
    store.establishmentGeneration = 1
    store.setTombstone(recordName: recordName, changeTag: "old")
    store.setDeleteWatermark(recordName: recordName, value: 4)
    store.addFailedApply(FailedApply(recordName: recordName, recordType: SyncedProfile.recordType, op: .upsert))

    await manager.adoptEstablishmentGeneration(2)
    let recreated = makeProfileRecord(id: id, name: "Recreated", version: 5, generation: 2)

    let outcome = makeApplyService().applyFetchedModification(
      recreated, isPendingDeleteOrTombstoned: isPendingDeleteOrTombstoned)

    XCTAssertEqual(outcome, .applied)
    XCTAssertTrue(store.failedApplies.isEmpty)
    XCTAssertTrue(store.deleteTombstones.isEmpty)
    XCTAssertNil(store.deleteWatermark(for: recordName))
    XCTAssertEqual(try BlockedProfiles.findProfile(byID: id, in: context)?.name, "Recreated")
  }

  func testSW5GenerationlessV1ProfileAfterWipeIsDocumentedResidualNotMaterialized() throws {
    let id = UUID()
    store.establishmentGeneration = 1
    let v1Record = makeProfileRecord(id: id, name: "V1 Residual", generation: nil)

    let outcome = makeApplyService().applyFetchedModification(
      v1Record, isPendingDeleteOrTombstoned: noPendingDelete)

    XCTAssertEqual(outcome, .skippedDeadWorld)
    XCTAssertNil(try BlockedProfiles.findProfile(byID: id, in: context))
  }

  func testSW7DeadWorldEmergencyEpochDoesNotRestoreClearedLedger() {
    store.establishmentGeneration = 1
    emergencyManager.seedForTesting(epoch: 5)
    emergencyManager.clearLedgerForGenerationAdoption()
    let laggingEpoch = SyncedEmergencyEpoch(epoch: 5, generation: 0).toCKRecord(in: zoneID)

    let outcome = makeApplyService().applyFetchedModification(
      laggingEpoch, isPendingDeleteOrTombstoned: noPendingDelete)

    XCTAssertEqual(outcome, .skippedDeadWorld)
    XCTAssertEqual(emergencyManager.currentResetEpoch, 0)
  }

  func testSW8OriginCrashAtWipingResumesOnlyEstablishmentSaveAndClearsWhenConfirmed() async {
    let outbox = MockResetOutbox()
    let seeder = MockResetSeeder()
    let controller = makeResetController(outbox: outbox, seeder: seeder)
    store.establishmentGeneration = 2
    store.resetIntent = ResetIntent(
      id: UUID(), clear: false, wipe: true, stage: .wiping, priorCommandId: nil)

    await controller.resume()

    XCTAssertEqual(outbox.establishmentSaveCount, 1)
    XCTAssertEqual(outbox.commandSaveCount, 0)
    XCTAssertEqual(seeder.seedCount, 0)

    controller.handleEstablishmentSaveResult(.saved)

    XCTAssertNil(store.resetIntent)
  }

  private func makeApplyService() -> SyncApplyService {
    SyncApplyService(
      modelContext: context, store: store, sessionController: sessionController,
      emergencyManager: emergencyManager, deviceId: deviceId)
  }

  private func makeResetController(
    outbox: MockResetOutbox,
    seeder: MockResetSeeder = MockResetSeeder()
  ) -> ResetController {
    ResetController(
      store: store, outbox: outbox, seeder: seeder, fetcher: MockRecordFetcher(),
      surfacer: MockResetConflictSurfacer(), deviceId: deviceId)
  }

  private func makeProfileRecord(
    id: UUID,
    name: String,
    version: Int = 1,
    generation: Int?
  ) -> CKRecord {
    let now = Date()
    let profile = BlockedProfiles(id: id, name: name, syncVersion: version)
    profile.createdAt = now
    profile.updatedAt = now
    var synced = SyncedProfile(from: profile, originDeviceId: "device-B")
    synced.version = version
    synced.createdAt = now
    synced.updatedAt = now
    let record = synced.toCKRecord(in: zoneID)
    record[SyncedProfile.FieldKey.generation.rawValue] = generation
    return record
  }

  private var noPendingDelete: (String) -> Bool {
    { _ in false }
  }

  private func isPendingDeleteOrTombstoned(_ recordName: String) -> Bool {
    store.deleteTombstones.keys.contains(recordName)
  }

}
