import CloudKit
import Foundation
import XCTest

@testable import FamilyFoqos

@MainActor
final class SyncEngineResetTests: XCTestCase {

  private var suiteName: String!
  private var defaults: UserDefaults!
  private var store: SyncEngineStore!
  private let zoneID = CKRecordZone.ID(
    zoneName: CloudKitConstants.syncZoneName, ownerName: CKCurrentUserDefaultName)

  override func setUp() {
    super.setUp()
    suiteName = "reset-tests-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)!
    SharedData.configure(suite: defaults)
    store = SyncEngineStore(userRecordName: "user-A", defaults: defaults)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    defaults = nil
    super.tearDown()
  }

  // MARK: - Helpers

  private func makeController(
    deviceId: String = "device-A",
    outbox: MockResetOutbox,
    seeder: MockResetSeeder,
    fetcher: MockRecordFetcher = MockRecordFetcher(),
    surfacer: MockResetConflictSurfacer = MockResetConflictSurfacer()
  ) -> ResetController {
    ResetController(
      store: store, outbox: outbox, seeder: seeder, fetcher: fetcher,
      surfacer: surfacer, deviceId: deviceId)
  }

  private func commandRecord(
    id: UUID, clear: Bool, origin: String, now: Date
  ) -> CKRecord {
    let recordID = CKRecord.ID(recordName: ResetController.commandRecordName, zoneID: zoneID)
    let record = CKRecord(recordType: SyncResetRequest.recordType, recordID: recordID)
    record[SyncResetRequest.FieldKey.requestId.rawValue] = id.uuidString
    record[SyncResetRequest.FieldKey.clearRemoteAppSelections.rawValue] = clear
    record[SyncResetRequest.FieldKey.requestedAt.rawValue] = now
    record[SyncResetRequest.FieldKey.originDeviceId.rawValue] = origin
    return record
  }

  private func establishmentRecord(generation: Int, now: Date) -> CKRecord {
    SyncedEstablishment(generation: generation, establishedAt: now).toCKRecord(in: zoneID)
  }

  /// A command record missing originDeviceId ⇒ SyncResetRequest(from:) returns nil (undecodable).
  private func undecodableCommandRecord(now: Date) -> CKRecord {
    let recordID = CKRecord.ID(recordName: ResetController.commandRecordName, zoneID: zoneID)
    let record = CKRecord(recordType: SyncResetRequest.recordType, recordID: recordID)
    record[SyncResetRequest.FieldKey.requestedAt.rawValue] = now
    return record
  }

  // MARK: - T8 / §8.1 step 1

  func testGivenSteady_WhenBeginReset_ThenPersistsDeletingIntentPreMarksAndEnqueuesDeleteZone() {
    let now = Date()
    let outbox = MockResetOutbox()
    let seeder = MockResetSeeder()
    let controller = makeController(outbox: outbox, seeder: seeder)

    controller.beginReset(clearRemoteAppSelections: true, now: now)

    let intent = store.resetIntent
    XCTAssertNotNil(intent)
    XCTAssertEqual(intent?.stage, .deleting)
    XCTAssertEqual(intent?.clear, true)
    XCTAssertNil(intent?.priorCommandId, "No prior reset history known to this device")
    // I4 pre-mark carve-out (§8.1 step 1): own id marked + set as lastApplied before any send.
    XCTAssertTrue(store.processedResetCommandIds.contains(intent!.id))
    XCTAssertEqual(store.lastAppliedResetCommandId, intent!.id)
    XCTAssertEqual(outbox.zoneDeleteCount, 1)
    XCTAssertEqual(outbox.sendCount, 1)
    XCTAssertEqual(seeder.seedCount, 0)
  }

  func testGivenPriorResetHistory_WhenBeginReset_ThenPriorCommandIdSnapshotsLastApplied() {
    let now = Date()
    let prior = UUID()
    store.lastAppliedResetCommandId = prior
    let outbox = MockResetOutbox()
    let controller = makeController(outbox: outbox, seeder: MockResetSeeder())

    controller.beginReset(clearRemoteAppSelections: false, now: now)

    XCTAssertEqual(store.resetIntent?.priorCommandId, prior)
  }

  func testGivenResetInProgress_WhenBeginResetCalledAgain_ThenIgnoredWithoutClobberingOrDoubleEnqueue() {
    let now = Date()
    let outbox = MockResetOutbox()
    let seeder = MockResetSeeder()
    let controller = makeController(outbox: outbox, seeder: seeder)

    controller.beginReset(clearRemoteAppSelections: true, now: now)
    let originalId = store.resetIntent?.id

    controller.beginReset(clearRemoteAppSelections: false, now: now)

    XCTAssertEqual(store.resetIntent?.id, originalId, "re-entrant call must not clobber the intent")
    XCTAssertEqual(outbox.zoneDeleteCount, 1, "re-entrant call must not enqueue a second deleteZone")
  }

  // MARK: - #286 coexistence guard (origin)

  func testGivenPendingSeedSaves_WhenBeginReset_ThenDeleteZoneAloneNoRecordSaves() {
    let now = Date()
    let mockDriver = MockSyncEngineDriver(
      pendingRecordZoneChanges: [
        .saveRecord(CKRecord.ID(recordName: "emergency-settings", zoneID: zoneID)),
        .saveRecord(CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID)),
      ],
      pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
    let controller = ResetController(
      store: store, outbox: DriverResetOutbox(driver: mockDriver, zoneID: zoneID),
      seeder: MockResetSeeder(), fetcher: MockRecordFetcher(),
      surfacer: MockResetConflictSurfacer(), deviceId: "device-A")

    controller.beginReset(clearRemoteAppSelections: true, now: now)

    // #286: the delete send must carry ONLY the deleteZone — no coexisting record-saves or
    // saveZone (CKSyncEngine asserts on that combination at sendChanges()).
    XCTAssertEqual(mockDriver.pendingDatabaseChanges, [.deleteZone(zoneID)])
    XCTAssertTrue(
      mockDriver.pendingRecordZoneChanges.isEmpty,
      "pending record saves must be cleared before the zone delete")
  }

  // MARK: - T9 / §8.1 steps 3-4

  func testGivenDeletingStage_WhenZoneDeleteConfirmed_ThenPurgesAdvancesToRecreatingAndEnqueuesSaveZone()
    async
  {
    let now = Date()
    let outbox = MockResetOutbox()
    let seeder = MockResetSeeder()
    let controller = makeController(outbox: outbox, seeder: seeder)
    controller.beginReset(clearRemoteAppSelections: false, now: now)

    await controller.handleZoneDeleteConfirmed()

    XCTAssertEqual(seeder.purgeCount, 1, "§8.1 step 3: I6 purge on delete confirmed")
    XCTAssertEqual(store.resetIntent?.stage, .recreating)
    XCTAssertEqual(outbox.zoneSaveCount, 1)
    XCTAssertEqual(outbox.sendCount, 2)  // begin + step 3
  }

  func testGivenRecreatingStage_WhenZoneSaveConfirmed_ThenSeedsIntentFirstAndEnqueuesCommand() {
    let now = Date()
    let outbox = MockResetOutbox()
    let seeder = MockResetSeeder()
    let controller = makeController(outbox: outbox, seeder: seeder)
    controller.beginReset(clearRemoteAppSelections: false, now: now)
    // Force to recreating (delete already confirmed in a real run).
    store.resetIntent = ResetIntent(
      id: store.resetIntent!.id, clear: false, stage: .recreating, priorCommandId: nil)

    controller.handleZoneSaveConfirmed()

    XCTAssertEqual(store.resetIntent?.stage, .seeding)
    XCTAssertTrue(store.pendingSeedIntent, "I11 intent-first before seed")
    XCTAssertEqual(outbox.commandSaveCount, 1)
    XCTAssertEqual(seeder.seedCount, 1)
    XCTAssertEqual(outbox.sendCount, 2)  // begin + step 4
  }

  func testGivenWipeReset_WhenZoneSaveConfirmed_ThenWritesOnlyEstablishmentAndAdvancesToWiping()
    async
  {
    let now = Date()
    store.establishmentGeneration = 1
    let processed = UUID()
    store.markProcessed(processed)
    store.setSystemFields(Data([0x01]), for: "stale")
    store.setTombstone(recordName: "stale", changeTag: "tag")
    store.setDeleteWatermark(recordName: "stale", value: 4)
    store.addFailedApply(FailedApply(recordName: "stale", recordType: SyncedProfile.recordType, op: .upsert))
    let outbox = MockResetOutbox()
    let seeder = MockResetSeeder()
    let controller = makeController(outbox: outbox, seeder: seeder)
    controller.beginReset(wipe: true, clearRemoteAppSelections: false, now: now)
    await controller.handleZoneDeleteConfirmed()

    controller.handleZoneSaveConfirmed()

    XCTAssertEqual(store.establishmentGeneration, 2)
    XCTAssertEqual(store.resetIntent?.stage, .wiping)
    XCTAssertNil(store.systemFields(for: "stale"))
    XCTAssertTrue(store.deleteTombstones.isEmpty)
    XCTAssertNil(store.deleteWatermark(for: "stale"))
    XCTAssertTrue(store.failedApplies.isEmpty)
    XCTAssertTrue(store.processedResetCommandIds.contains(processed))
    XCTAssertEqual(seeder.wipeLocalCount, 1)
    XCTAssertEqual(outbox.establishmentSaveCount, 1)
    XCTAssertEqual(outbox.commandSaveCount, 0)
    XCTAssertEqual(seeder.seedCount, 0)
  }

  func testGivenWipingStage_WhenResume_ThenReenqueuesOnlyEstablishmentNoCommandNoSeed() async {
    let outbox = MockResetOutbox()
    let seeder = MockResetSeeder()
    let controller = makeController(outbox: outbox, seeder: seeder)
    store.establishmentGeneration = 2
    store.resetIntent = ResetIntent(
      id: UUID(), clear: false, wipe: true, stage: .wiping, priorCommandId: nil)

    await controller.resume()

    XCTAssertEqual(outbox.establishmentSaveCount, 1)
    XCTAssertEqual(outbox.commandSaveCount, 0)
    XCTAssertEqual(seeder.seedCount, 0)
  }

  func testGivenWipingStage_WhenAbandonedForStop_ThenPendingEstablishmentSaveIsRemoved() {
    let outbox = MockResetOutbox()
    let controller = makeController(outbox: outbox, seeder: MockResetSeeder())
    store.resetIntent = ResetIntent(
      id: UUID(), clear: false, wipe: true, stage: .wiping, priorCommandId: nil)

    controller.abandonForStop()

    XCTAssertNil(store.resetIntent)
    XCTAssertEqual(outbox.removeEstablishmentCount, 1)
  }

  func testGivenWipe_WhenEstablishmentSaveConfirmed_ThenClearsIntent() {
    let now = Date()
    let outbox = MockResetOutbox()
    let seeder = MockResetSeeder()
    let controller = makeController(outbox: outbox, seeder: seeder)
    controller.beginReset(wipe: true, clearRemoteAppSelections: false, now: now)
    store.resetIntent = ResetIntent(
      id: store.resetIntent!.id, clear: false, wipe: true, stage: .wiping, priorCommandId: nil)

    controller.handleEstablishmentSaveResult(.saved)

    XCTAssertNil(store.resetIntent)
  }

  func testGivenWipeSaveLosesToHigherGeneration_WhenHandlingConflict_ThenReturnsWinnerForAdoption() {
    let now = Date()
    let outbox = MockResetOutbox()
    let controller = makeController(outbox: outbox, seeder: MockResetSeeder())
    store.establishmentGeneration = 2
    store.engineState = Data([0x01])
    store.resetIntent = ResetIntent(
      id: UUID(), clear: false, wipe: true, stage: .wiping, priorCommandId: nil)

    let winningRecord = controller.handleEstablishmentSaveResult(
      .serverRecordChanged(establishmentRecord(generation: 3, now: now)))

    XCTAssertEqual(store.establishmentGeneration, 2, "the adoption path owns generation advancement")
    XCTAssertEqual(store.engineState, Data([0x01]), "the live reset machine must not fake a restart")
    XCTAssertNil(store.resetIntent)
    XCTAssertEqual(
      winningRecord?[SyncedEstablishment.FieldKey.generation.rawValue] as? Int,
      3,
      "the controller must route the winning record through full generation adoption")
  }

  func testGivenNonDeletingStage_WhenZoneDeleteConfirmedWithNilIntent_ThenNoOp() async {
    // Zone-delete confirmation with resetIntent == nil is a T5 concern (controller), not reset.
    let outbox = MockResetOutbox()
    let seeder = MockResetSeeder()
    let controller = makeController(outbox: outbox, seeder: seeder)

    await controller.handleZoneDeleteConfirmed()

    XCTAssertEqual(seeder.purgeCount, 0)
    XCTAssertNil(store.resetIntent)
  }

  // MARK: - §8.3 command application

  func testGivenForeignCommand_WhenAppliedTwiceSameId_ThenSecondIsNoOp() async {
    let now = Date()
    let id = UUID()
    let outbox = MockResetOutbox()
    let seeder = MockResetSeeder()
    let controller = makeController(outbox: outbox, seeder: seeder)
    let record = commandRecord(id: id, clear: false, origin: "device-B", now: now)

    await controller.applyCommand(record)
    XCTAssertTrue(store.processedResetCommandIds.contains(id))
    XCTAssertEqual(seeder.seedCount, 1)
    XCTAssertEqual(seeder.purgeCount, 1)

    // S-5: same-id redelivery is a no-op (I3).
    await controller.applyCommand(record)
    XCTAssertEqual(seeder.seedCount, 1, "redelivery must not re-seed")
    XCTAssertEqual(seeder.purgeCount, 1)
    XCTAssertEqual(store.lastAppliedResetCommandId, id)
  }

  func testGivenAppliedButUnmarked_WhenCommandRedelivered_ThenReAppliesIdempotentlyAndMarks() async {
    let now = Date()
    let id = UUID()
    let outbox = MockResetOutbox()
    let seeder = MockResetSeeder()
    let controller = makeController(outbox: outbox, seeder: seeder)
    let record = commandRecord(id: id, clear: false, origin: "device-B", now: now)

    // S-6: simulate a kill AFTER apply but BEFORE the mark persisted — pendingSeedIntent set,
    // id NOT in processed. Redelivery re-applies idempotently and completes the mark.
    store.pendingSeedIntent = true
    XCTAssertFalse(store.processedResetCommandIds.contains(id))

    await controller.applyCommand(record)

    XCTAssertEqual(seeder.seedCount, 1, "unmarked command re-applies")
    XCTAssertEqual(seeder.purgeCount, 1)
    XCTAssertTrue(store.processedResetCommandIds.contains(id), "mark completes on re-apply")
    XCTAssertEqual(store.lastAppliedResetCommandId, id)
  }

  func testGivenCommand_WhenApplied_ThenPurgesAndSeedsRegardlessOfClearFlagInIntentApplyMarkOrder() async {
    let now = Date()
    let outbox = MockResetOutbox()

    // clear == false: still purge + seed, no selection clear.
    let seederNoClear = MockResetSeeder()
    let controllerNoClear = makeController(outbox: outbox, seeder: seederNoClear)
    await controllerNoClear.applyCommand(
      commandRecord(id: UUID(), clear: false, origin: "device-B", now: now))
    XCTAssertEqual(seederNoClear.purgeCount, 1)
    XCTAssertEqual(seederNoClear.seedCount, 1)
    XCTAssertEqual(seederNoClear.clearSelectionsCount, 0)

    // clear == true: clears selections AND purge + seed.
    let idClear = UUID()
    let seederClear = MockResetSeeder()
    let controllerClear = makeController(outbox: outbox, seeder: seederClear)
    // Assert intent → apply → mark ordering: at seed time pendingSeedIntent is set and the
    // command id is NOT yet marked processed.
    var seedSawIntent = false
    var seedSawUnmarked = false
    seederClear.onSeed = { [weak self] in
      guard let self else { return }
      seedSawIntent = self.store.pendingSeedIntent
      seedSawUnmarked = !self.store.processedResetCommandIds.contains(idClear)
    }
    await controllerClear.applyCommand(
      commandRecord(id: idClear, clear: true, origin: "device-B", now: now))
    XCTAssertEqual(seederClear.clearSelectionsCount, 1)
    XCTAssertEqual(seederClear.purgeCount, 1)
    XCTAssertEqual(seederClear.seedCount, 1)
    XCTAssertTrue(seedSawIntent, "pendingSeedIntent persisted before seed (intent-first)")
    XCTAssertTrue(seedSawUnmarked, "mark happens AFTER apply (I4)")
    XCTAssertTrue(store.processedResetCommandIds.contains(idClear))
  }

  func testGivenOwnOriginCommand_WhenApplied_ThenMarkedNeverApplied() async {
    let now = Date()
    let id = UUID()
    let outbox = MockResetOutbox()
    let seeder = MockResetSeeder()
    let controller = makeController(deviceId: "device-A", outbox: outbox, seeder: seeder)

    await controller.applyCommand(
      commandRecord(id: id, clear: true, origin: "device-A", now: now))

    // S-9: own-origin ⇒ lastApplied set, marked, but never applied (no purge/seed/clear).
    XCTAssertEqual(store.lastAppliedResetCommandId, id)
    XCTAssertTrue(store.processedResetCommandIds.contains(id))
    XCTAssertEqual(seeder.purgeCount, 0)
    XCTAssertEqual(seeder.seedCount, 0)
    XCTAssertEqual(seeder.clearSelectionsCount, 0)
  }

  func testGivenUndecodableCommand_WhenApplied_ThenInertNoStateChange() async {
    let now = Date()
    let outbox = MockResetOutbox()
    let seeder = MockResetSeeder()
    let controller = makeController(outbox: outbox, seeder: seeder)

    await controller.applyCommand(undecodableCommandRecord(now: now))

    XCTAssertNil(store.lastAppliedResetCommandId, "undecodable command is inert (§5.1)")
    XCTAssertTrue(store.processedResetCommandIds.isEmpty)
    XCTAssertEqual(seeder.seedCount, 0)
  }

  // MARK: - §8.1 step 5 + resume

  private func seedSeedingStage(id: UUID, clear: Bool = false) {
    store.resetIntent = ResetIntent(id: id, clear: clear, stage: .seeding, priorCommandId: nil)
    store.pendingSeedIntent = true
  }

  func testGivenSeedingStage_WhenCommandSaveResult_ThenSavedClearsForeignAbandonsOwnConfirmsUndecodableAbandons()
    async
  {
    let now = Date()

    // saved ⇒ clear intent (command tag not stored).
    let idSaved = UUID()
    let outboxSaved = MockResetOutbox()
    let surfacerSaved = MockResetConflictSurfacer()
    let cSaved = makeController(outbox: outboxSaved, seeder: MockResetSeeder(), surfacer: surfacerSaved)
    seedSeedingStage(id: idSaved)
    cSaved.handleCommandSaveResult(.saved)
    XCTAssertNil(store.resetIntent)
    XCTAssertEqual(surfacerSaved.surfaceCount, 0)

    // serverRecordChanged with OWN requestId ⇒ earlier save succeeded, confirmed-clear, no surface.
    let idOwn = UUID()
    let outboxOwn = MockResetOutbox()
    let surfacerOwn = MockResetConflictSurfacer()
    let cOwn = makeController(outbox: outboxOwn, seeder: MockResetSeeder(), surfacer: surfacerOwn)
    seedSeedingStage(id: idOwn)
    cOwn.handleCommandSaveResult(
      .serverRecordChanged(commandRecord(id: idOwn, clear: false, origin: "device-A", now: now)))
    XCTAssertNil(store.resetIntent)
    XCTAssertEqual(surfacerOwn.surfaceCount, 0)

    // serverRecordChanged with FOREIGN requestId ⇒ superseded: abandon + surface + dequeue.
    let idForeign = UUID()
    let outboxForeign = MockResetOutbox()
    let surfacerForeign = MockResetConflictSurfacer()
    let cForeign = makeController(outbox: outboxForeign, seeder: MockResetSeeder(), surfacer: surfacerForeign)
    seedSeedingStage(id: idForeign)
    cForeign.handleCommandSaveResult(
      .serverRecordChanged(commandRecord(id: UUID(), clear: false, origin: "device-B", now: now)))
    XCTAssertNil(store.resetIntent)
    XCTAssertEqual(surfacerForeign.surfaceCount, 1)
    XCTAssertEqual(outboxForeign.removeCommandCount, 1)
    XCTAssertEqual(outboxForeign.removeZoneCount, 1)

    // serverRecordChanged with UNDECODABLE serverRecord ⇒ treat as foreign (abandon + surface).
    let idUndec = UUID()
    let outboxUndec = MockResetOutbox()
    let surfacerUndec = MockResetConflictSurfacer()
    let cUndec = makeController(outbox: outboxUndec, seeder: MockResetSeeder(), surfacer: surfacerUndec)
    seedSeedingStage(id: idUndec)
    cUndec.handleCommandSaveResult(.serverRecordChanged(undecodableCommandRecord(now: now)))
    XCTAssertNil(store.resetIntent)
    XCTAssertEqual(surfacerUndec.surfaceCount, 1)
    XCTAssertEqual(outboxUndec.removeCommandCount, 1)
  }

  func testGivenRecreatingOrSeedingStage_WhenResume_ThenReenqueuesThatStagesChanges() async {
    // .recreating ⇒ re-enqueue saveZone.
    let outboxR = MockResetOutbox()
    let cR = makeController(outbox: outboxR, seeder: MockResetSeeder())
    store.resetIntent = ResetIntent(id: UUID(), clear: false, stage: .recreating, priorCommandId: nil)
    await cR.resume()
    XCTAssertEqual(outboxR.zoneSaveCount, 1)
    XCTAssertEqual(outboxR.sendCount, 1)

    // .seeding ⇒ re-enqueue command save + seed.
    let outboxS = MockResetOutbox()
    let seederS = MockResetSeeder()
    let cS = makeController(outbox: outboxS, seeder: seederS)
    store.resetIntent = ResetIntent(id: UUID(), clear: false, stage: .seeding, priorCommandId: nil)
    await cS.resume()
    XCTAssertEqual(outboxS.commandSaveCount, 1)
    XCTAssertEqual(seederS.seedCount, 1)
    XCTAssertEqual(outboxS.sendCount, 1)
  }

  // MARK: - S-36 .deleting resume gate

  private func seedDeletingStage(id: UUID, prior: UUID?) {
    store.resetIntent = ResetIntent(id: id, clear: false, stage: .deleting, priorCommandId: prior)
  }

  func testGivenDeletingStageResume_WhenGateFetchesCommand_ThenAllFiveArmsResolveCorrectly() async {
    let now = Date()

    // Arm 1: own id ⇒ already published ⇒ confirmed-clear, no re-enqueue, no surface.
    let idOwn = UUID()
    let outboxOwn = MockResetOutbox()
    let surfacerOwn = MockResetConflictSurfacer()
    let fetcherOwn = MockRecordFetcher()
    fetcherOwn.result = .success(commandRecord(id: idOwn, clear: false, origin: "device-A", now: now))
    let cOwn = makeController(
      outbox: outboxOwn, seeder: MockResetSeeder(), fetcher: fetcherOwn, surfacer: surfacerOwn)
    seedDeletingStage(id: idOwn, prior: nil)
    await cOwn.resume()
    XCTAssertNil(store.resetIntent)
    XCTAssertEqual(outboxOwn.zoneDeleteCount, 0)
    XCTAssertEqual(surfacerOwn.surfaceCount, 0)

    // Arm 2a: == priorCommandId ⇒ prior incarnation ⇒ resume (re-enqueue deleteZone).
    let idPrior = UUID()
    let prior = UUID()
    let outboxPrior = MockResetOutbox()
    let fetcherPrior = MockRecordFetcher()
    fetcherPrior.result = .success(commandRecord(id: prior, clear: false, origin: "device-B", now: now))
    let cPrior = makeController(outbox: outboxPrior, seeder: MockResetSeeder(), fetcher: fetcherPrior)
    seedDeletingStage(id: idPrior, prior: prior)
    await cPrior.resume()
    XCTAssertEqual(store.resetIntent?.stage, .deleting, "prior ⇒ resume, intent kept")
    XCTAssertEqual(outboxPrior.zoneDeleteCount, 1)
    XCTAssertEqual(outboxPrior.sendCount, 1)

    // Arm 2b: no command (absent) ⇒ resume.
    let outboxNone = MockResetOutbox()
    let fetcherNone = MockRecordFetcher()
    fetcherNone.result = .success(nil)
    let cNone = makeController(outbox: outboxNone, seeder: MockResetSeeder(), fetcher: fetcherNone)
    seedDeletingStage(id: UUID(), prior: nil)
    await cNone.resume()
    XCTAssertEqual(outboxNone.zoneDeleteCount, 1)

    // Arm 2c: zoneNotFound ⇒ resume.
    let outboxZNF = MockResetOutbox()
    let fetcherZNF = MockRecordFetcher()
    fetcherZNF.result = .failure(CKError(.zoneNotFound))
    let cZNF = makeController(outbox: outboxZNF, seeder: MockResetSeeder(), fetcher: fetcherZNF)
    seedDeletingStage(id: UUID(), prior: nil)
    await cZNF.resume()
    XCTAssertEqual(outboxZNF.zoneDeleteCount, 1)

    // Arm 3: foreign (!= id, != prior) ⇒ abandon + surface + dequeue zone changes.
    let outboxForeign = MockResetOutbox()
    let surfacerForeign = MockResetConflictSurfacer()
    let fetcherForeign = MockRecordFetcher()
    fetcherForeign.result = .success(
      commandRecord(id: UUID(), clear: false, origin: "device-B", now: now))
    let cForeign = makeController(
      outbox: outboxForeign, seeder: MockResetSeeder(), fetcher: fetcherForeign,
      surfacer: surfacerForeign)
    seedDeletingStage(id: UUID(), prior: UUID())
    await cForeign.resume()
    XCTAssertNil(store.resetIntent)
    XCTAssertEqual(surfacerForeign.surfaceCount, 1)
    XCTAssertEqual(outboxForeign.removeZoneCount, 1)
    XCTAssertEqual(outboxForeign.removeCommandCount, 1)
    XCTAssertEqual(outboxForeign.zoneDeleteCount, 0, "no resume after abandon")

    // Arm 4: undecodable ⇒ abandon + surface.
    let outboxUndec = MockResetOutbox()
    let surfacerUndec = MockResetConflictSurfacer()
    let fetcherUndec = MockRecordFetcher()
    fetcherUndec.result = .success(undecodableCommandRecord(now: now))
    let cUndec = makeController(
      outbox: outboxUndec, seeder: MockResetSeeder(), fetcher: fetcherUndec, surfacer: surfacerUndec)
    seedDeletingStage(id: UUID(), prior: nil)
    await cUndec.resume()
    XCTAssertNil(store.resetIntent)
    XCTAssertEqual(surfacerUndec.surfaceCount, 1)

    // Arm 5: transient error ⇒ intent kept, no surface, no re-enqueue (retry later).
    let outboxTrans = MockResetOutbox()
    let surfacerTrans = MockResetConflictSurfacer()
    let fetcherTrans = MockRecordFetcher()
    fetcherTrans.result = .failure(CKError(.networkFailure))
    let idTrans = UUID()
    let cTrans = makeController(
      outbox: outboxTrans, seeder: MockResetSeeder(), fetcher: fetcherTrans, surfacer: surfacerTrans)
    seedDeletingStage(id: idTrans, prior: nil)
    await cTrans.resume()
    XCTAssertEqual(store.resetIntent?.id, idTrans, "transient ⇒ intent kept")
    XCTAssertEqual(store.resetIntent?.stage, .deleting)
    XCTAssertEqual(outboxTrans.zoneDeleteCount, 0)
    XCTAssertEqual(surfacerTrans.surfaceCount, 0)
  }

  func testGivenDeletingResumeWithPendingSaves_WhenResume_ThenDeleteZoneAloneNoCoexistence()
    async
  {
    let now = Date()
    store.resetIntent = ResetIntent(
      id: UUID(), clear: true, stage: .deleting, priorCommandId: nil)
    let mockDriver = MockSyncEngineDriver(
      pendingRecordZoneChanges: [
        .saveRecord(CKRecord.ID(recordName: "emergency-settings", zoneID: zoneID))
      ],
      pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
    // Default MockRecordFetcher returns .success(nil) ⇒ gate sees "no command" ⇒ reenqueueDeleting.
    let controller = ResetController(
      store: store, outbox: DriverResetOutbox(driver: mockDriver, zoneID: zoneID),
      seeder: MockResetSeeder(), fetcher: MockRecordFetcher(),
      surfacer: MockResetConflictSurfacer(), deviceId: "device-A")
    _ = now  // gate is date-independent; pinned per house rule

    await controller.resume()

    XCTAssertEqual(mockDriver.pendingDatabaseChanges, [.deleteZone(zoneID)])
    XCTAssertTrue(
      mockDriver.pendingRecordZoneChanges.isEmpty,
      "#286: a resumed .deleting stage must not re-add a deleteZone alongside pending saves")
  }

  func testGivenDeletingWipe_WhenGateFindsHigherGeneration_ThenDequeuesDeleteWithoutAdvancingGeneration()
    async
  {
    let now = Date()
    let fetcher = MockRecordFetcher()
    fetcher.result = .success(establishmentRecord(generation: 2, now: now))
    let mockDriver = MockSyncEngineDriver(pendingDatabaseChanges: [.deleteZone(zoneID)])
    let controller = ResetController(
      store: store, outbox: DriverResetOutbox(driver: mockDriver, zoneID: zoneID),
      seeder: MockResetSeeder(), fetcher: fetcher,
      surfacer: MockResetConflictSurfacer(), deviceId: "device-A")
    store.establishmentGeneration = 1
    store.resetIntent = ResetIntent(
      id: UUID(), clear: false, wipe: true, stage: .deleting, priorCommandId: nil)

    await controller.resume()

    XCTAssertNil(store.resetIntent)
    XCTAssertEqual(
      store.establishmentGeneration, 1,
      "normal fetched-record adoption must perform the discard before advancing generation")
    XCTAssertFalse(
      mockDriver.pendingDatabaseChanges.contains(.deleteZone(zoneID)),
      "the losing wipe must dequeue its stale deletion before the peer's new zone is adopted")
  }

  func testGivenDeletingWipeCancelledDuringGateFetch_WhenFetchReturns_ThenZoneDeleteIsNotReenqueued()
    async
  {
    let now = Date()
    let outbox = MockResetOutbox()
    let fetcher = MockRecordFetcher()
    fetcher.result = .success(establishmentRecord(generation: 1, now: now))
    let controller = makeController(
      outbox: outbox, seeder: MockResetSeeder(), fetcher: fetcher)
    let intent = ResetIntent(
      id: UUID(), clear: false, wipe: true, stage: .deleting, priorCommandId: nil)
    store.establishmentGeneration = 1
    store.resetIntent = intent
    fetcher.onFetch = {
      controller.cancelDeletingWipeForEstablishmentAdoption()
    }

    await controller.resume()

    XCTAssertNil(store.resetIntent)
    XCTAssertEqual(outbox.clearPendingCount, 0)
    XCTAssertEqual(outbox.zoneDeleteCount, 0)
    XCTAssertEqual(outbox.sendCount, 0)
  }

  func testGivenDeletingResetClearedDuringGateFetch_WhenFetchReturns_ThenZoneDeleteIsNotReenqueued()
    async
  {
    let now = Date()
    let outbox = MockResetOutbox()
    let fetcher = MockRecordFetcher()
    let priorCommandId = UUID()
    fetcher.result = .success(
      commandRecord(id: priorCommandId, clear: false, origin: "device-B", now: now))
    let controller = makeController(
      outbox: outbox, seeder: MockResetSeeder(), fetcher: fetcher)
    store.resetIntent = ResetIntent(
      id: UUID(), clear: false, stage: .deleting, priorCommandId: priorCommandId)
    fetcher.onFetch = {
      self.store.resetIntent = nil
    }

    await controller.resume()

    XCTAssertEqual(outbox.clearPendingCount, 0)
    XCTAssertEqual(outbox.zoneDeleteCount, 0)
    XCTAssertEqual(outbox.sendCount, 0)
  }

  func testGivenDeletingWipeResume_WhenGateDoesNotFindHigherGeneration_ThenAllRetryArmsAreCovered()
    async
  {
    let now = Date()
    store.establishmentGeneration = 1

    let absentOutbox = MockResetOutbox()
    let absentFetcher = MockRecordFetcher()
    absentFetcher.result = .success(nil)
    store.resetIntent = ResetIntent(
      id: UUID(), clear: false, wipe: true, stage: .deleting, priorCommandId: nil)
    await makeController(
      outbox: absentOutbox, seeder: MockResetSeeder(), fetcher: absentFetcher
    ).resume()
    XCTAssertEqual(absentOutbox.zoneDeleteCount, 1)

    let undecodableOutbox = MockResetOutbox()
    let undecodableFetcher = MockRecordFetcher()
    undecodableFetcher.result = .success(
      CKRecord(
        recordType: SyncedEstablishment.recordType,
        recordID: CKRecord.ID(recordName: SyncedEstablishment.recordName, zoneID: zoneID)))
    store.resetIntent = ResetIntent(
      id: UUID(), clear: false, wipe: true, stage: .deleting, priorCommandId: nil)
    await makeController(
      outbox: undecodableOutbox, seeder: MockResetSeeder(), fetcher: undecodableFetcher
    ).resume()
    XCTAssertEqual(undecodableOutbox.zoneDeleteCount, 1)

    let equalOutbox = MockResetOutbox()
    let equalFetcher = MockRecordFetcher()
    equalFetcher.result = .success(establishmentRecord(generation: 1, now: now))
    store.resetIntent = ResetIntent(
      id: UUID(), clear: false, wipe: true, stage: .deleting, priorCommandId: nil)
    await makeController(
      outbox: equalOutbox, seeder: MockResetSeeder(), fetcher: equalFetcher
    ).resume()
    XCTAssertEqual(equalOutbox.zoneDeleteCount, 1)

    let zoneMissingOutbox = MockResetOutbox()
    let zoneMissingFetcher = MockRecordFetcher()
    zoneMissingFetcher.result = .failure(CKError(.zoneNotFound))
    store.resetIntent = ResetIntent(
      id: UUID(), clear: false, wipe: true, stage: .deleting, priorCommandId: nil)
    await makeController(
      outbox: zoneMissingOutbox, seeder: MockResetSeeder(), fetcher: zoneMissingFetcher
    ).resume()
    XCTAssertEqual(zoneMissingOutbox.zoneDeleteCount, 1)

    let transientOutbox = MockResetOutbox()
    let transientFetcher = MockRecordFetcher()
    transientFetcher.result = .failure(CKError(.networkFailure))
    let transientId = UUID()
    store.resetIntent = ResetIntent(
      id: transientId, clear: false, wipe: true, stage: .deleting, priorCommandId: nil)
    await makeController(
      outbox: transientOutbox, seeder: MockResetSeeder(), fetcher: transientFetcher
    ).resume()
    XCTAssertEqual(store.resetIntent?.id, transientId)
    XCTAssertEqual(transientOutbox.zoneDeleteCount, 0)
  }

  // MARK: - S-4 cross-check (full .purged behavior lives in Phase D; here: intent/tombstone facet)

  func testGivenAbandonedReset_WhenIntentCleared_ThenTombstonesSurvive() async {
    let now = Date()
    // A local deletion intent (tombstone) exists alongside a reset intent.
    store.setTombstone(recordName: "profile-1", changeTag: "tag-1")
    let idForeign = UUID()
    let outbox = MockResetOutbox()
    let surfacer = MockResetConflictSurfacer()
    let fetcher = MockRecordFetcher()
    fetcher.result = .success(commandRecord(id: UUID(), clear: false, origin: "device-B", now: now))
    let controller = makeController(
      outbox: outbox, seeder: MockResetSeeder(), fetcher: fetcher, surfacer: surfacer)
    seedDeletingStage(id: idForeign, prior: UUID())

    await controller.resume()

    XCTAssertNil(store.resetIntent, "abandoned reset clears the intent")
    XCTAssertEqual(
      store.deleteTombstones["profile-1"], "tag-1",
      "deletion intent is not consent-scoped — tombstones survive reset abandonment (S-4/I12)")
  }
}
