import CloudKit
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class SyncEngineControllerTests: XCTestCase {
  var suiteName: String!
  var defaults: UserDefaults!
  var container: ModelContainer!
  var context: ModelContext!
  var store: SyncEngineStore!
  var driver: MockSyncEngineDriver!
  var apply: SyncApplyService!
  var provider: RecordProvider!
  var sessionSync: MockSessionSyncFlushing!
  var sessionController: MockSessionController!
  let deviceId = "device-A"
  let userRecordName = "user-A"
  let zoneID = CKRecordZone.ID(
    zoneName: CloudKitConstants.syncZoneName, ownerName: CKCurrentUserDefaultName)

  override func setUp() async throws {
    try await super.setUp()
    suiteName = "SyncEngineControllerTests-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)!
    SharedData.configure(suite: defaults)
    container = try TestModelContainer.create()
    context = container.mainContext
    store = SyncEngineStore(userRecordName: userRecordName, defaults: defaults)
    driver = MockSyncEngineDriver()
    sessionController = MockSessionController()
    let emergency = EmergencyUnblockManager()
    apply = SyncApplyService(
      modelContext: context, store: store, sessionController: sessionController,
      emergencyManager: emergency, deviceId: deviceId)
    provider = RecordProvider(
      modelContext: context, store: store, emergencyManager: emergency, deviceId: deviceId)
    sessionSync = MockSessionSyncFlushing()
    SyncConflictManager.shared.clearAll()
  }

  override func tearDown() async throws {
    SyncConflictManager.shared.clearAll()
    UserDefaults().removePersistentDomain(forName: suiteName)
    try await super.tearDown()
  }

  // MARK: - Harness helpers

  func makeController() -> SyncEngineController {
    SyncEngineController(
      modelContext: context,
      store: store,
      driverFactory: { [driver] _ in driver! },
      apply: apply,
      provider: provider,
      sessionSync: sessionSync,
      deviceId: deviceId)
  }

  func recordID(_ name: String) -> CKRecord.ID {
    CKRecord.ID(recordName: name, zoneID: zoneID)
  }

  func makeProfileRecord(id: UUID, version: Int, name: String = "P") -> CKRecord {
    let profile = BlockedProfiles(id: id, name: name, syncVersion: version)
    let synced = SyncedProfile(from: profile, originDeviceId: "device-B")
    return synced.toCKRecord(in: zoneID)
  }

  func makeCKError(_ code: CKError.Code, userInfo: [String: Any] = [:]) -> CKError {
    let ns = NSError(domain: CKErrorDomain, code: code.rawValue, userInfo: userInfo)
    return CKError(_nsError: ns)
  }

  func pendingSaveNames() -> Set<String> {
    Set(
      driver.pendingRecordZoneChanges.compactMap {
        if case .saveRecord(let id) = $0 { return id.recordName } else { return nil }
      })
  }

  func pendingDeleteNames() -> Set<String> {
    Set(
      driver.pendingRecordZoneChanges.compactMap {
        if case .deleteRecord(let id) = $0 { return id.recordName } else { return nil }
      })
  }

  func hasPendingZoneSave() -> Bool {
    driver.pendingDatabaseChanges.contains {
      if case .saveZone = $0 { return true } else { return false }
    }
  }

  func hasPendingZoneDelete() -> Bool {
    driver.pendingDatabaseChanges.contains {
      if case .deleteZone = $0 { return true } else { return false }
    }
  }

  func fetchProfile(_ id: UUID) throws -> BlockedProfiles? {
    try context.fetch(
      FetchDescriptor<BlockedProfiles>(predicate: #Predicate { $0.id == id })
    ).first
  }

  // MARK: - Tests

  func testGivenController_WhenConstructed_ThenRequiresContextAndAppliesDurableInEvent() async {
    let controller = makeController()
    XCTAssertEqual(controller.state, .disabled)
    controller.start()
    // Driver was created via the factory (I10: context present from init).
    XCTAssertEqual(controller.state, .bootstrapping)
    await controller.startupTask?.value
  }

  func testGivenRestoredPendingDeletesAndDbChanges_WhenStart_ThenStripRemovesThemSynchronouslyWithNoSend() {
    store.engineState = Data([0x01])  // not a bootstrap
    let keepZone = CKRecordZone(zoneID: zoneID)
    driver = MockSyncEngineDriver(
      stateSerialization: Data([0x01]),
      pendingRecordZoneChanges: [
        .deleteRecord(recordID("del-1")),
        .deleteRecord(recordID("legacy-1")),
        .saveRecord(recordID("save-1")),
      ],
      pendingDatabaseChanges: [
        .saveZone(keepZone),
        .deleteZone(zoneID),
      ])
    store.addLegacyCleanupIds(["legacy-1"])

    let controller = makeController()
    controller.start()  // assert BEFORE awaiting startupTask: synchronous region only

    XCTAssertFalse(pendingDeleteNames().contains("del-1"), "restored delete stripped")
    XCTAssertTrue(pendingDeleteNames().contains("legacy-1"), "legacy delete survives strip")
    XCTAssertTrue(pendingSaveNames().contains("save-1"), "restored saves untouched by strip")
    XCTAssertTrue(driver.pendingDatabaseChanges.isEmpty, "all restored db changes stripped")
    XCTAssertEqual(driver.sendChangesCount, 0, "no send during synchronous strip window (AB-4)")

    controller.startupTask?.cancel()
  }

  func testGivenLegacyCleanupIdsAndFlagUnset_WhenStart_ThenIdsSurviveStripAndReEnqueue() async {
    store.engineState = Data([0x01])
    store.addLegacyCleanupIds(["legacy-1", "legacy-2"])
    XCTAssertFalse(store.legacyCleanupDone)
    driver.pendingRecordZoneChanges = []  // pending changes lost across the kill

    let controller = makeController()
    controller.start()
    await controller.startupTask?.value

    XCTAssertEqual(
      pendingDeleteNames().intersection(["legacy-1", "legacy-2"]), ["legacy-1", "legacy-2"],
      "surviving legacy ids re-enqueued for deletion while flag unset")
  }

  func testGivenLegacyCleanupDone_WhenStart_ThenNoLegacyReEnqueue() async {
    store.engineState = Data([0x01])
    store.legacyCleanupDone = true

    let controller = makeController()
    controller.start()
    await controller.startupTask?.value

    XCTAssertTrue(pendingDeleteNames().isEmpty)
  }

  // MARK: - I11 seeding helper (intent-first, AB-1, S-25)

  func testGivenSeedHelper_WhenSeed_ThenIntentFirstThenSaveZoneAndSaveAllRestorable() throws {
    let p = BlockedProfiles(name: "A")
    context.insert(p)
    let loc = SavedLocation(name: "Home", latitude: 1, longitude: 2)
    context.insert(loc)
    try context.save()

    let controller = makeController()
    controller.start()  // creates driver
    controller.startupTask?.cancel()

    controller.seedZoneAndRecords()

    XCTAssertTrue(store.pendingSeedIntent, "intent persisted first (I11)")
    XCTAssertTrue(hasPendingZoneSave(), "saveZone enqueued")
    let saves = pendingSaveNames()
    XCTAssertTrue(saves.contains(p.id.uuidString))
    XCTAssertTrue(saves.contains(loc.id.uuidString))
    XCTAssertTrue(saves.contains(SyncedEmergencySettings.recordName))
  }

  func testGivenNewerSchemaProfile_WhenSeed_ThenNotIncludedInRestorableSet() throws {
    let p = BlockedProfiles(name: "A")
    p.profileSchemaVersion = BlockedProfiles.currentSchemaVersion + 1
    context.insert(p)
    try context.save()
    XCTAssertTrue(p.isNewerSchemaVersion)

    let controller = makeController()
    controller.start()
    controller.startupTask?.cancel()

    controller.seedZoneAndRecords()

    XCTAssertFalse(
      pendingSaveNames().contains(p.id.uuidString),
      "isNewerSchemaVersion profiles are excluded from re-seed (§5.4/I11)")
  }

  func testGivenSessions_WhenSeed_ThenSessionsNeverSeeded() throws {
    let p = BlockedProfiles(name: "A")
    context.insert(p)
    try context.save()
    let session = BlockedProfileSession(tag: "test", blockedProfile: p)
    context.insert(session)
    try context.save()

    let controller = makeController()
    controller.start()
    controller.startupTask?.cancel()

    controller.seedZoneAndRecords()

    let saves = pendingSaveNames()
    XCTAssertFalse(
      saves.contains { $0.hasPrefix("ProfileSession_") },
      "sessions are never re-seeded (§6/N13)")
    XCTAssertFalse(saves.contains(session.id))
  }

  func testGivenSeed_WhenEnqueued_ThenSaveZoneDatabaseChangePrecedesRecordSaves() throws {
    let controller = makeController()
    controller.start()
    controller.startupTask?.cancel()
    controller.seedZoneAndRecords()
    // AB-1: the engine sends database changes before record changes; we assert the
    // saveZone is enqueued (a database change) alongside the record saves so the
    // engine's own ordering guarantee applies.
    XCTAssertTrue(hasPendingZoneSave())
    XCTAssertTrue(pendingSaveNames().contains(SyncedEmergencySettings.recordName))

    // S-25: assert enqueue order in the mock's operation log — the saveZone add
    // must precede the record-save add so the engine can honor AB-1 even before
    // any send occurs.
    let dbChangeIndex = driver.operations.firstIndex {
      if case .addDatabaseChanges(let changes) = $0 {
        return changes.contains { if case .saveZone = $0 { return true } else { return false } }
      }
      return false
    }
    let recordSaveIndex = driver.operations.firstIndex {
      if case .addRecordChanges(let changes) = $0 {
        return changes.contains {
          if case .saveRecord(let id) = $0 { return id.recordName == SyncedEmergencySettings.recordName }
          return false
        }
      }
      return false
    }
    let dbIndex = try XCTUnwrap(dbChangeIndex, "saveZone add op present in log")
    let recordIndex = try XCTUnwrap(recordSaveIndex, "record save add op present in log")
    XCTAssertLessThan(dbIndex, recordIndex, "AB-1: saveZone enqueued before record saves")
  }

  // MARK: - T1 seed decision at startup (S-19, S-28, I7)

  func testGivenExistingEngineStateNoIntents_WhenStart_ThenZeroEnqueues() async {
    store.engineState = Data([0x01])  // ordinary relaunch
    XCTAssertFalse(store.pendingSeedIntent)
    XCTAssertTrue(store.deleteTombstones.isEmpty)
    let p = BlockedProfiles(name: "A")
    context.insert(p)
    try? context.save()

    let controller = makeController()
    controller.start()
    await controller.startupTask?.value

    XCTAssertTrue(pendingSaveNames().isEmpty, "ordinary relaunch enqueues nothing (I7/S-19)")
    XCTAssertFalse(hasPendingZoneSave())
    XCTAssertEqual(driver.fetchChangesCount, 1)
  }

  func testGivenNilEngineState_WhenStart_ThenBootstrapSeeds() async {
    store.engineState = nil
    let p = BlockedProfiles(name: "A")
    context.insert(p)
    try? context.save()

    let controller = makeController()
    controller.start()
    await controller.startupTask?.value

    XCTAssertTrue(store.pendingSeedIntent)
    XCTAssertTrue(hasPendingZoneSave())
    XCTAssertTrue(pendingSaveNames().contains(p.id.uuidString))
    XCTAssertEqual(sessionSync.flushCount, 0, "bootstrap does not purge (nothing to purge)")
  }

  func testGivenPendingSeedIntentSet_WhenStart_ThenPurgeAndReSeed() async {
    store.engineState = Data([0x01])
    store.pendingSeedIntent = true
    store.setSystemFields(Data([0x09]), for: "stale")
    let p = BlockedProfiles(name: "A")
    context.insert(p)
    try? context.save()

    let controller = makeController()
    controller.start()
    await controller.startupTask?.value

    XCTAssertNil(store.systemFields(for: "stale"), "I6 purge ran")
    XCTAssertEqual(sessionSync.flushCount, 1)
    XCTAssertTrue(hasPendingZoneSave())
    XCTAssertTrue(pendingSaveNames().contains(p.id.uuidString))
  }

  // MARK: - I11 observable-clear (Fix 5)

  func
    testGivenBootstrapSeed_WhenAllSeededNamesObservedSent_ThenPendingSeedIntentClearsAndRelaunchEnqueuesNothing()
    async
  {
    store.engineState = nil
    let p = BlockedProfiles(name: "A")
    context.insert(p)
    try? context.save()

    let controller = makeController()
    controller.start()
    await controller.startupTask?.value

    XCTAssertTrue(store.pendingSeedIntent, "bootstrap seed sets the intent")

    // Materialize every seeded save (as the production adapter would) and confirm them
    // sent, then confirm the zone save — the full observable-clear surface (Fix 5).
    let batch = controller.nextRecordZoneChangeBatch(scope: nil) ?? []
    XCTAssertEqual(
      Set(batch.map { $0.recordID.recordName }),
      Set([p.id.uuidString, SyncedEmergencySettings.recordName]))

    controller.handle(
      .sentRecordZoneChanges(
        savedRecords: batch, failedRecordSaves: [], deletedRecordIDs: [], failedRecordDeletes: []))
    XCTAssertTrue(store.pendingSeedIntent, "zone save not yet confirmed ⇒ intent still set")

    controller.handle(
      .sentDatabaseChanges(
        savedZones: [zoneID], failedZoneSaves: [], deletedZoneIDs: [], failedZoneDeletes: []))

    XCTAssertFalse(
      store.pendingSeedIntent, "every seeded name observed sent ⇒ I11 intent-clear (Fix 5)")

    controller.handle(.stateUpdate(serialization: Data([0x01])))

    // Relaunch: a fresh controller over the same store now sees pendingSeedIntent == false
    // and (since engineState is non-nil) takes the ordinary-relaunch path — enqueues
    // nothing (S-19).
    let relaunchDriver = MockSyncEngineDriver()
    let relaunchController = SyncEngineController(
      modelContext: context, store: store, driverFactory: { _ in relaunchDriver },
      apply: apply, provider: provider, sessionSync: sessionSync, deviceId: deviceId)
    relaunchController.start()
    await relaunchController.startupTask?.value

    XCTAssertTrue(
      relaunchDriver.pendingRecordZoneChanges.isEmpty, "relaunch enqueues no record saves")
    XCTAssertFalse(
      relaunchDriver.pendingDatabaseChanges.contains {
        if case .saveZone = $0 { return true } else { return false }
      },
      "relaunch enqueues no zone save")
  }

  // MARK: - I12 delete-intent recovery (S-29, S-33, CRA-5)

  func testGivenTombstoneEntityPresent_WhenRecover_ThenAbortAndClear() async {
    let id = UUID()
    let p = BlockedProfiles(id: id, name: "A")
    context.insert(p)
    try? context.save()
    store.engineState = Data([0x01])
    store.setTombstone(recordName: id.uuidString, changeTag: "tag-1")

    let controller = makeController()
    controller.start()
    await controller.startupTask?.value

    XCTAssertNil(store.deleteTombstones[id.uuidString], "entity present ⇒ abort, clear tombstone")
    XCTAssertTrue(pendingDeleteNames().isEmpty, "no delete enqueued")
  }

  func testGivenRecoveredTombstoneNotFound_WhenRecover_ThenClearedNoDelete() async {
    let id = UUID()
    store.engineState = Data([0x01])
    store.setTombstone(recordName: id.uuidString, changeTag: "tag-a")
    driver.fetchRecordResults[id.uuidString] = .notFound

    let controller = makeController()
    controller.start()
    await controller.startupTask?.value

    XCTAssertNil(store.deleteTombstones[id.uuidString], "absent ⇒ already complete, cleared")
    XCTAssertFalse(pendingDeleteNames().contains(id.uuidString))
  }

  func testGivenRecoveredTombstoneMatchingTag_WhenRecover_ThenDeleteEnqueuedTombstoneRetained()
    async
  {
    let id = UUID()
    store.engineState = Data([0x01])
    store.setTombstone(recordName: id.uuidString, changeTag: "tag-m")
    let record = makeProfileRecord(id: id, version: 1)
    driver.fetchRecordResults[id.uuidString] = .found(record, changeTag: "tag-m")

    let controller = makeController()
    controller.start()
    await controller.startupTask?.value

    XCTAssertTrue(
      pendingDeleteNames().contains(id.uuidString),
      "matching tag ⇒ delete enqueued (CRA-5)")
    XCTAssertNotNil(
      store.deleteTombstones[id.uuidString], "tombstone retained until delete confirmed")
  }

  func testGivenRecoveredTombstoneDifferentTag_WhenRecover_ThenClearedConflictSurfacedNoDelete()
    async
  {
    let id = UUID()
    store.engineState = Data([0x01])
    store.setTombstone(recordName: id.uuidString, changeTag: "tag-old")
    let record = makeProfileRecord(id: id, version: 1, name: "Re-adopted")
    driver.fetchRecordResults[id.uuidString] = .found(record, changeTag: "tag-new")

    let controller = makeController()
    controller.start()
    await controller.startupTask?.value

    XCTAssertNil(store.deleteTombstones[id.uuidString], "different tag ⇒ re-adopted, cleared")
    XCTAssertFalse(pendingDeleteNames().contains(id.uuidString), "no delete")
    XCTAssertNotNil(SyncConflictManager.shared.conflictedProfiles[id], "conflict surfaced")
  }

  func testGivenRecoveredTombstoneTransientFetchError_WhenRecover_ThenTombstoneKept() async {
    let id = UUID()
    store.engineState = Data([0x01])
    store.setTombstone(recordName: id.uuidString, changeTag: "tag-1")
    driver.fetchRecordResults[id.uuidString] = .transientError(makeCKError(.networkFailure))

    let controller = makeController()
    controller.start()
    await controller.startupTask?.value

    XCTAssertNotNil(store.deleteTombstones[id.uuidString], "transient ⇒ keep, retry later")
    XCTAssertFalse(pendingDeleteNames().contains(id.uuidString))
  }

  func testGivenRecoveredTombstoneZoneNotFound_WhenRecover_ThenTombstoneKeptNotCleared() async {
    // Fix 3: .zoneNotFound must group with .transientError (KEEP), not .notFound (CLEAR) —
    // a re-seeded zone's record may come back, and §5.6 must re-verify rather than having
    // silently dropped the delete intent (resurrection risk).
    let id = UUID()
    store.engineState = Data([0x01])
    store.setTombstone(recordName: id.uuidString, changeTag: "tag-1")
    driver.fetchRecordResults[id.uuidString] = .zoneNotFound

    let controller = makeController()
    controller.start()
    await controller.startupTask?.value

    XCTAssertNotNil(
      store.deleteTombstones[id.uuidString], "zoneNotFound ⇒ keep, §5.6 re-verifies (Fix 3)")
    XCTAssertFalse(pendingDeleteNames().contains(id.uuidString))
  }

  // MARK: - §5.6 failed-apply retry (S-35)

  func testGivenFailedApplies_WhenRetry_ThenVerifyThenReapplyAndSupersession() async {
    store.engineState = Data([0x01])
    let upsertId = UUID()
    let deleteAbsentId = UUID()
    let deletePresentId = UUID()

    store.addFailedApply(
      FailedApply(
        recordName: upsertId.uuidString, recordType: SyncedProfile.recordType, op: .upsert))
    store.addFailedApply(
      FailedApply(
        recordName: deleteAbsentId.uuidString, recordType: SyncedProfile.recordType, op: .delete))
    store.addFailedApply(
      FailedApply(
        recordName: deletePresentId.uuidString, recordType: SyncedProfile.recordType, op: .delete)
    )

    driver.fetchRecordResults[upsertId.uuidString] = .found(
      makeProfileRecord(id: upsertId, version: 3, name: "Recovered"), changeTag: nil)
    driver.fetchRecordResults[deleteAbsentId.uuidString] = .notFound
    // Present ⇒ recreated since ⇒ drop the entry, never delete.
    driver.fetchRecordResults[deletePresentId.uuidString] = .found(
      makeProfileRecord(id: deletePresentId, version: 1), changeTag: nil)
    // A local entity exists for the delete-present id so a delete WOULD remove it.
    let p = BlockedProfiles(id: deletePresentId, name: "KeepMe")
    context.insert(p)
    try? context.save()

    let controller = makeController()
    controller.start()
    await controller.startupTask?.value

    XCTAssertNil(
      store.failedApplies.first { $0.recordName == upsertId.uuidString },
      "upsert re-applied ⇒ entry cleared (supersession)")
    XCTAssertNotNil(try? fetchProfile(upsertId), "upsert record re-applied into SwiftData")

    XCTAssertNil(
      store.failedApplies.first { $0.recordName == deleteAbsentId.uuidString },
      "delete verified absent ⇒ applied + cleared")

    XCTAssertNil(
      store.failedApplies.first { $0.recordName == deletePresentId.uuidString },
      "delete verified present ⇒ entry dropped")
    XCTAssertNotNil(try? fetchProfile(deletePresentId), "present record NOT deleted (S-35)")
  }

  func
    testGivenFailedApplyEntrySurvivesRetryViaTransientError_WhenLaterApplySucceeds_ThenEntryClearedSupersession()
    async
  {
    store.engineState = Data([0x01])
    let id = UUID()
    store.addFailedApply(
      FailedApply(recordName: id.uuidString, recordType: SyncedProfile.recordType, op: .upsert))
    driver.fetchRecordResults[id.uuidString] = .transientError(makeCKError(.networkFailure))

    let controller = makeController()
    controller.start()
    await controller.startupTask?.value

    XCTAssertNotNil(
      store.failedApplies.first { $0.recordName == id.uuidString },
      "transient fetch error during retry ⇒ entry kept for next cycle")

    // A later successful apply (e.g. the next fetch cycle, §5.1) supersedes the retry:
    // any successful apply for the recordName clears the failedApplies entry regardless
    // of which op originally failed.
    let record = makeProfileRecord(id: id, version: 1, name: "Superseded")
    let outcome = apply.applyFetchedModification(record, isPendingDeleteOrTombstoned: { _ in false })
    XCTAssertEqual(outcome, .applied)

    XCTAssertNil(
      store.failedApplies.first { $0.recordName == id.uuidString },
      "later successful apply clears the entry (supersession)")
  }

  // MARK: - AB-3 fetch-cycle delimiters (T2, S-37)

  func testGivenFetchCycle_WhenDidFetchChanges_ThenSteadyAndCycleDelimited() async {
    store.engineState = Data([0x01])
    let controller = makeController()
    controller.start()
    await controller.startupTask?.value
    XCTAssertEqual(controller.state, .bootstrapping)

    controller.handle(.willFetchChanges)
    controller.handle(.didFetchChanges)
    XCTAssertEqual(controller.state, .steady, "T2: first didFetchChanges ⇒ Steady")
    await controller.fetchCycleSweepTask?.value
  }

  func testGivenFailedApplyPending_WhenDidFetchChanges_ThenPostCycleSweepRetriesIt() async {
    store.engineState = Data([0x01])
    let controller = makeController()
    controller.start()
    await controller.startupTask?.value

    // A failed apply recorded after startup (e.g. by a mid-session fetch apply, out of
    // scope here) should be retried by the NEXT completed fetch cycle's §5.6 sweep
    // (S-37), not only at controller start.
    let id = UUID()
    store.addFailedApply(
      FailedApply(recordName: id.uuidString, recordType: SyncedProfile.recordType, op: .upsert))
    driver.fetchRecordResults[id.uuidString] = .found(
      makeProfileRecord(id: id, version: 1, name: "Recovered"), changeTag: nil)

    controller.handle(.willFetchChanges)
    controller.handle(.didFetchChanges)
    await controller.fetchCycleSweepTask?.value

    XCTAssertNil(
      store.failedApplies.first { $0.recordName == id.uuidString },
      "post-cycle §5.6 sweep retried and cleared the entry")
    XCTAssertNotNil(try? fetchProfile(id), "recovered record applied by the post-cycle sweep")
  }

  // MARK: - T3 fetchedRecordZoneChanges routing (§5.1/§5.2, S-1, S-32, CRA-1, CRA-2)

  func testGivenNoTombstone_WhenFetchedModification_ThenApplied() {
    let id = UUID()
    let controller = makeController()
    controller.start()
    controller.startupTask?.cancel()

    controller.handle(
      .fetchedRecordZoneChanges(modifications: [makeProfileRecord(id: id, version: 5)], deletions: []))

    XCTAssertNotNil(try? fetchProfile(id), "plain fetched modification applies (S-1)")
  }

  func testGivenTombstonedId_WhenFetchedModification_ThenSkippedPendingDeleteWins() {
    let id = UUID()
    store.setTombstone(recordName: id.uuidString, changeTag: "t")
    let controller = makeController()
    controller.start()
    controller.startupTask?.cancel()

    controller.handle(
      .fetchedRecordZoneChanges(modifications: [makeProfileRecord(id: id, version: 5)], deletions: []))

    XCTAssertNil(try? fetchProfile(id), "pending-delete-wins ⇒ modification skipped (S-32)")
  }

  func testGivenFetchedDeletion_WhenHandled_ThenTombstoneClearedAndPendingDeleteRemoved() {
    let id = UUID()
    let p = BlockedProfiles(id: id, name: "A")
    context.insert(p)
    try? context.save()
    store.setTombstone(recordName: id.uuidString, changeTag: "t")
    store.setSystemFields(Data([0x1]), for: id.uuidString)

    let controller = makeController()
    controller.start()
    controller.startupTask?.cancel()
    driver.add(pendingRecordZoneChanges: [.deleteRecord(recordID(id.uuidString))])

    controller.handle(
      .fetchedRecordZoneChanges(
        modifications: [],
        deletions: [(recordID: recordID(id.uuidString), recordType: SyncedProfile.recordType)]))

    XCTAssertNil(try? fetchProfile(id), "local profile deleted (§5.2)")
    XCTAssertNil(store.deleteTombstones[id.uuidString], "tombstone cleared (I12)")
    XCTAssertNil(store.systemFields(for: id.uuidString))
    XCTAssertFalse(pendingDeleteNames().contains(id.uuidString), "pending .deleteRecord removed (§5.2)")
  }

  func testGivenFetchedSyncResetRequest_WhenFetchedModification_ThenRoutedToHookNotGenericApply() {
    let resetRequest = SyncResetRequest(clearRemoteAppSelections: true, originDeviceId: "device-B")
    let requestId = resetRequest.requestId
    let resetRecord = resetRequest.toCKRecord(in: zoneID)

    let controller = makeController()
    controller.start()
    controller.startupTask?.cancel()

    var capturedRecord: CKRecord?
    var captureCount = 0
    controller.onFetchedResetCommand = { record in
      capturedRecord = record
      captureCount += 1
    }

    controller.handle(
      .fetchedRecordZoneChanges(modifications: [resetRecord], deletions: []))

    XCTAssertEqual(captureCount, 1, "CRA-2: fetched SyncResetRequest routed to the hook exactly once")
    XCTAssertEqual(
      capturedRecord?.recordID.recordName, requestId.uuidString,
      "hook received the reset command record")
    XCTAssertNil(
      try? fetchProfile(requestId),
      "no generic apply ran for the reset command (not passed to applyFetchedModification)")
    XCTAssertTrue(
      store.failedApplies.isEmpty,
      "no failedApplies bookkeeping created by a generic apply of the reset command")
  }

  func testGivenEqualVersionDivergence_WhenFetchedModification_ThenReenqueueDrainedToDriverAndConflictAdded() {
    let id = UUID()
    let local = BlockedProfiles(id: id, name: "Local", syncVersion: 5)
    context.insert(local)
    try? context.save()

    let controller = makeController()
    controller.start()
    controller.startupTask?.cancel()

    let remoteRecord = makeProfileRecord(id: id, version: 5, name: "Remote")

    controller.handle(
      .fetchedRecordZoneChanges(modifications: [remoteRecord], deletions: []))

    XCTAssertTrue(
      pendingSaveNames().contains(id.uuidString),
      "CRA-1: §5.1 equal-version-divergence reenqueue is drained and reaches the driver as .saveRecord")
    XCTAssertNotNil(
      SyncConflictManager.shared.conflictedProfiles[id],
      "equal-version divergence surfaces a conflict")
  }

  // MARK: - T4 sentRecordZoneChanges routing (§5.3, S-10, S-11, S-17, S-23, S-29, CRA-1, CRA-3)

  func testGivenSentSave_WhenServerRecordChanged_ThenBranchCTagStoredMergeAndReAdd() {
    // Local strictly newer than server ⇒ branch C local-wins ⇒ re-add.
    let id = UUID()
    let local = BlockedProfiles(id: id, name: "Local", syncVersion: 5)
    context.insert(local)
    try? context.save()
    let controller = makeController()
    controller.start()
    controller.startupTask?.cancel()

    let sent = makeProfileRecord(id: id, version: 5)  // what we tried to save
    let server = makeProfileRecord(id: id, version: 3)  // older on server
    let error = makeCKError(
      .serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: server])

    controller.handle(
      .sentRecordZoneChanges(
        savedRecords: [], failedRecordSaves: [(record: sent, error: error)],
        deletedRecordIDs: [], failedRecordDeletes: []))

    XCTAssertNotNil(store.systemFields(for: id.uuidString), "server tag stored first (scoped type)")
    XCTAssertTrue(pendingSaveNames().contains(id.uuidString), "local strictly newer ⇒ re-add")
  }

  func testGivenSentSave_WhenServerRecordChangedEqualVersionPayloadEqual_ThenBranch0AdoptSilent() {
    let id = UUID()
    let local = BlockedProfiles(id: id, name: "Same", syncVersion: 5)
    context.insert(local)
    try? context.save()
    let controller = makeController()
    controller.start()
    controller.startupTask?.cancel()

    // Server echoes exactly the local payload/version — a byte-identical CKRecord derived
    // from the SAME local model instance (e.g. CloudKit materialized our own prior save).
    let server = SyncedProfile(from: local, originDeviceId: "device-B").toCKRecord(in: zoneID)
    let error = makeCKError(
      .serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: server])

    controller.handle(
      .sentRecordZoneChanges(
        savedRecords: [], failedRecordSaves: [(record: server, error: error)],
        deletedRecordIDs: [], failedRecordDeletes: []))

    XCTAssertNotNil(
      store.systemFields(for: id.uuidString), "server tag stored first even in branch 0")
    XCTAssertFalse(pendingSaveNames().contains(id.uuidString), "branch 0: adopt-silent, no re-add")
    XCTAssertNil(
      SyncConflictManager.shared.conflictedProfiles[id], "branch 0: no conflict surfaced")
  }

  func testGivenSentSave_WhenServerRecordChangedEqualVersionDiffers_ThenBranchEDrainReachesDriver() {
    let id = UUID()
    let local = BlockedProfiles(id: id, name: "Local", syncVersion: 5)
    context.insert(local)
    try? context.save()
    let controller = makeController()
    controller.start()
    controller.startupTask?.cancel()

    let sent = makeProfileRecord(id: id, version: 5, name: "Local")
    let server = makeProfileRecord(id: id, version: 5, name: "ServerDiff")  // same version, differs
    let error = makeCKError(
      .serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: server])

    controller.handle(
      .sentRecordZoneChanges(
        savedRecords: [], failedRecordSaves: [(record: sent, error: error)],
        deletedRecordIDs: [], failedRecordDeletes: []))

    XCTAssertTrue(
      pendingSaveNames().contains(id.uuidString),
      "CRA-1: branch E (§5.1 equal-version divergence) reenqueue drained to the driver")
    XCTAssertNotNil(
      SyncConflictManager.shared.conflictedProfiles[id], "branch E surfaces a conflict")
  }

  func testGivenSentSave_WhenZoneNotFound_ThenBranchZSaveZoneSeedAndReAdd() {
    let id = UUID()
    let controller = makeController()
    controller.start()
    controller.startupTask?.cancel()
    let sent = makeProfileRecord(id: id, version: 1)

    controller.handle(
      .sentRecordZoneChanges(
        savedRecords: [], failedRecordSaves: [(record: sent, error: makeCKError(.zoneNotFound))],
        deletedRecordIDs: [], failedRecordDeletes: []))

    XCTAssertTrue(hasPendingZoneSave(), "branch Z ⇒ saveZone")
    XCTAssertTrue(store.pendingSeedIntent, "branch Z ⇒ intent-first seed")
    XCTAssertTrue(pendingSaveNames().contains(id.uuidString), "failed change re-added")
  }

  func testGivenSentSave_WhenUnknownItem_ThenBranchUSaveDropsTagReAddsCreate() {
    let id = UUID()
    store.setSystemFields(Data([0x1]), for: id.uuidString)
    let controller = makeController()
    controller.start()
    controller.startupTask?.cancel()
    let sent = makeProfileRecord(id: id, version: 1)

    controller.handle(
      .sentRecordZoneChanges(
        savedRecords: [], failedRecordSaves: [(record: sent, error: makeCKError(.unknownItem))],
        deletedRecordIDs: [], failedRecordDeletes: []))

    XCTAssertNil(store.systemFields(for: id.uuidString), "U-save drops the system-fields entry")
    XCTAssertTrue(pendingSaveNames().contains(id.uuidString), "re-added as create")
  }

  func testGivenSentSave_WhenRetriableVsNonRetriable_ThenBranchROnceBranchFSurfaced() {
    let rId = UUID()
    let fId = UUID()
    let fProfile = BlockedProfiles(id: fId, name: "F")
    context.insert(fProfile)
    try? context.save()
    let controller = makeController()
    controller.start()
    controller.startupTask?.cancel()

    controller.handle(
      .sentRecordZoneChanges(
        savedRecords: [],
        failedRecordSaves: [
          (record: makeProfileRecord(id: rId, version: 1), error: makeCKError(.networkFailure)),
          (record: makeProfileRecord(id: fId, version: 1), error: makeCKError(.permissionFailure)),
        ], deletedRecordIDs: [], failedRecordDeletes: []))

    XCTAssertEqual(
      pendingSaveNames().filter { $0 == rId.uuidString }.count, 1, "branch R re-added once")
    XCTAssertFalse(pendingSaveNames().contains(fId.uuidString), "branch F removed permanently")
    XCTAssertNotNil(SyncConflictManager.shared.conflictedProfiles[fId], "branch F surfaces conflict")
  }

  func testGivenFailedDelete_WhenUnknownItem_ThenBranchUDeleteClearsTombstoneAndSystemFields() {
    let id = UUID()
    store.setTombstone(recordName: id.uuidString, changeTag: "t")
    store.setSystemFields(Data([0x1]), for: id.uuidString)
    let controller = makeController()
    controller.start()
    controller.startupTask?.cancel()

    controller.handle(
      .sentRecordZoneChanges(
        savedRecords: [], failedRecordSaves: [],
        deletedRecordIDs: [],
        failedRecordDeletes: [
          (recordID: recordID(id.uuidString), error: makeCKError(.unknownItem))
        ]))

    XCTAssertNil(store.deleteTombstones[id.uuidString], "U-delete clears the tombstone")
    XCTAssertNil(store.systemFields(for: id.uuidString), "U-delete drops the system-fields entry")
  }

  func testGivenConfirmedDelete_WhenSentRecordChanges_ThenTombstoneClearedAndSystemFieldsDropped() {
    let id = UUID()
    store.setTombstone(recordName: id.uuidString, changeTag: "t")
    store.setSystemFields(Data([0x1]), for: id.uuidString)
    let controller = makeController()
    controller.start()
    controller.startupTask?.cancel()

    controller.handle(
      .sentRecordZoneChanges(
        savedRecords: [], failedRecordSaves: [],
        deletedRecordIDs: [recordID(id.uuidString)], failedRecordDeletes: []))

    XCTAssertNil(store.deleteTombstones[id.uuidString], "confirmed delete clears tombstone (I12)")
    XCTAssertNil(store.systemFields(for: id.uuidString))
    XCTAssertTrue(apply.recentlyConfirmedDeletes.contains(id.uuidString), "echo guard populated")
  }

  func testGivenSavedRecord_WhenSent_ThenSystemFieldsStoredAndLegacyIdCleared() {
    let id = UUID()
    store.addLegacyCleanupIds(["legacy-x"])
    let controller = makeController()
    controller.start()
    controller.startupTask?.cancel()

    let saved = makeProfileRecord(id: id, version: 2)
    let legacy = CKRecord(
      recordType: "SyncedSession", recordID: recordID("legacy-x"))
    controller.handle(
      .sentRecordZoneChanges(
        savedRecords: [saved, legacy], failedRecordSaves: [], deletedRecordIDs: [],
        failedRecordDeletes: []))

    XCTAssertNotNil(store.systemFields(for: id.uuidString), "scoped-type tag stored")
    XCTAssertFalse(store.legacyCleanupIds.contains("legacy-x"), "legacy id cleared on confirmation")
    XCTAssertTrue(store.legacyCleanupDone, "flag set when legacyCleanupIds empties")
  }

  func testGivenCommandRecordSaved_WhenSent_ThenCRA3SuccessHookFiresAndNoSystemFieldsStored() {
    let controller = makeController()
    controller.start()
    controller.startupTask?.cancel()

    let resetRequest = SyncResetRequest(clearRemoteAppSelections: true, originDeviceId: "device-B")
    let requestId = resetRequest.requestId
    let commandRecord = resetRequest.toCKRecord(in: zoneID)

    var capturedRecord: CKRecord?
    var captureCount = 0
    controller.resetCommandSaveDidSucceed = { record in
      capturedRecord = record
      captureCount += 1
    }

    controller.handle(
      .sentRecordZoneChanges(
        savedRecords: [commandRecord], failedRecordSaves: [], deletedRecordIDs: [],
        failedRecordDeletes: []))

    XCTAssertEqual(captureCount, 1, "CRA-3: command-save success hook fires exactly once")
    XCTAssertEqual(
      capturedRecord?.recordID.recordName, requestId.uuidString,
      "hook received the saved command record")
    XCTAssertNil(
      store.systemFields(for: requestId.uuidString),
      "command record is not a scoped type ⇒ no systemFields stored")
  }

  func testGivenCommandSaveFails_WhenForeignServerRecord_ThenAbandonedAndSupersededSurfaced() {
    // Fix 2 (§8.1 step 5): the hook must forward the SERVER record (not the device's own
    // attempted record) and gate on the error code — a foreign requestId must abandon +
    // surface, not silently confirm (the old code always forwarded the local record, whose
    // requestId always equals the intent's own id, so it always took the "own ⇒ confirmed"
    // branch).
    let controller = makeController()
    controller.start()
    controller.startupTask?.cancel()
    store.resetIntent = ResetIntent(
      id: UUID(), clear: false, stage: .seeding, priorCommandId: nil)

    let ownAttempt = CKRecord(
      recordType: SyncResetRequest.recordType,
      recordID: recordID(ResetController.commandRecordName))
    let foreignServer = CKRecord(
      recordType: SyncResetRequest.recordType,
      recordID: recordID(ResetController.commandRecordName))
    foreignServer[SyncResetRequest.FieldKey.requestId.rawValue] = UUID().uuidString
    foreignServer[SyncResetRequest.FieldKey.clearRemoteAppSelections.rawValue] = false
    foreignServer[SyncResetRequest.FieldKey.requestedAt.rawValue] = Date()
    foreignServer[SyncResetRequest.FieldKey.originDeviceId.rawValue] = "device-B"
    let error = makeCKError(
      .serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: foreignServer])

    controller.handle(
      .sentRecordZoneChanges(
        savedRecords: [], failedRecordSaves: [(record: ownAttempt, error: error)],
        deletedRecordIDs: [], failedRecordDeletes: []))

    XCTAssertNil(store.resetIntent, "foreign requestId ⇒ abandoned")
    XCTAssertTrue(
      SyncConflictManager.shared.resetWasSuperseded, "abandon surfaces reset-superseded")
  }

  func testGivenCommandSaveFails_WhenTransientError_ThenIntentKeptNotAbandoned() {
    // Fix 2: retriable/other codes must NOT clear or abandon the intent.
    let controller = makeController()
    controller.start()
    controller.startupTask?.cancel()
    let intent = ResetIntent(id: UUID(), clear: false, stage: .seeding, priorCommandId: nil)
    store.resetIntent = intent

    let ownAttempt = CKRecord(
      recordType: SyncResetRequest.recordType,
      recordID: recordID(ResetController.commandRecordName))
    let error = makeCKError(.networkFailure)

    controller.handle(
      .sentRecordZoneChanges(
        savedRecords: [], failedRecordSaves: [(record: ownAttempt, error: error)],
        deletedRecordIDs: [], failedRecordDeletes: []))

    XCTAssertEqual(store.resetIntent?.id, intent.id, "transient failure ⇒ intent kept")
    XCTAssertFalse(SyncConflictManager.shared.resetWasSuperseded)
  }

  // MARK: - S-34 end-to-end (deferred from Task 68: echo-guard cycle scoping)

  func
    testGivenConfirmedDelete_WhenModificationDeliveredInSameCycleVsLaterCycle_ThenSkippedThenApplied()
  {
    let id = UUID()
    let controller = makeController()
    driver.delegate = controller
    controller.start()
    controller.startupTask?.cancel()

    // Cycle 1: willFetchChanges, then mid-cycle the delete is confirmed (echo guard
    // populated, confirmDeleteCycle[name] = 1 == currentCycle ⇒ not yet drainable), then a
    // fetched modification for the SAME id arrives — still within the cycle that started
    // BEFORE the confirmation ⇒ must still be skipped.
    driver.deliverFetchCycle([
      .sentRecordZoneChanges(
        savedRecords: [], failedRecordSaves: [],
        deletedRecordIDs: [recordID(id.uuidString)], failedRecordDeletes: []),
      .fetchedRecordZoneChanges(
        modifications: [makeProfileRecord(id: id, version: 1, name: "Echo")], deletions: []),
    ])

    XCTAssertNil(
      try? fetchProfile(id),
      "modification delivered within the confirming cycle is still guarded (S-34)")
    XCTAssertTrue(
      apply.recentlyConfirmedDeletes.contains(id.uuidString), "guard not yet drained")

    // Cycle 2's willFetchChanges drains confirmDeleteCycle entries with value < currentCycle
    // (1 < 2) ⇒ the guard for `id` is removed at the START of this later cycle. A
    // modification delivered within cycle 2 is now a genuine recreation and must apply.
    driver.deliverFetchCycle([
      .fetchedRecordZoneChanges(
        modifications: [makeProfileRecord(id: id, version: 1, name: "Recreated")], deletions: [])
    ])

    XCTAssertFalse(
      apply.recentlyConfirmedDeletes.contains(id.uuidString),
      "guard drained at the start of the first cycle after confirmation")
    XCTAssertNotNil(
      try? fetchProfile(id), "modification delivered in a later cycle applies (genuine recreation)")
  }

  // MARK: - T4b sentDatabaseChanges (§5.5)

  func testGivenSentDatabaseChanges_WhenZoneSavedOrAlreadyExists_ThenConfirmed() {
    let controller = makeController()
    controller.start()
    controller.startupTask?.cancel()
    let zone = CKRecordZone(zoneID: zoneID)

    // zone-already-exists counts as confirmed ⇒ no re-add.
    controller.handle(
      .sentDatabaseChanges(
        savedZones: [], failedZoneSaves: [(zone: zone, error: makeCKError(.serverRecordChanged))],
        deletedZoneIDs: [], failedZoneDeletes: []))
    XCTAssertFalse(hasPendingZoneSave(), "already-exists ⇒ confirmed, not re-added")

    // retriable ⇒ re-add saveZone.
    controller.handle(
      .sentDatabaseChanges(
        savedZones: [], failedZoneSaves: [(zone: zone, error: makeCKError(.networkFailure))],
        deletedZoneIDs: [], failedZoneDeletes: []))
    XCTAssertTrue(hasPendingZoneSave(), "retriable zone save ⇒ re-add")
  }

  func testGivenSentDatabaseChanges_WhenSavedZonesOrDeletedZoneIDs_ThenOnZoneChangeConfirmedFires() {
    let controller = makeController()
    controller.start()
    controller.startupTask?.cancel()

    var capturedSaved: [CKRecordZone.ID] = []
    var capturedDeleted: [CKRecordZone.ID] = []
    var callCount = 0
    controller.onZoneChangeConfirmed = { saved, deleted in
      capturedSaved = saved
      capturedDeleted = deleted
      callCount += 1
    }

    controller.handle(
      .sentDatabaseChanges(
        savedZones: [zoneID], failedZoneSaves: [], deletedZoneIDs: [], failedZoneDeletes: []))

    XCTAssertEqual(callCount, 1, "hook fires once for savedZones")
    XCTAssertEqual(capturedSaved, [zoneID], "hook receives the saved zone")
    XCTAssertTrue(capturedDeleted.isEmpty, "no deleted zones in this call")

    controller.handle(
      .sentDatabaseChanges(
        savedZones: [], failedZoneSaves: [], deletedZoneIDs: [zoneID], failedZoneDeletes: []))

    XCTAssertEqual(callCount, 2, "hook fires again for deletedZoneIDs")
    XCTAssertTrue(capturedSaved.isEmpty, "no saved zones in this call")
    XCTAssertEqual(capturedDeleted, [zoneID], "hook receives the deleted zone")
  }

  func testGivenFailedZoneDelete_WhenZoneNotFound_ThenConfirmedAndNotReAdded() {
    let controller = makeController()
    controller.start()
    controller.startupTask?.cancel()

    var confirmedDeletedZoneIDs: [CKRecordZone.ID] = []
    controller.onZoneChangeConfirmed = { _, deleted in
      confirmedDeletedZoneIDs.append(contentsOf: deleted)
    }

    controller.handle(
      .sentDatabaseChanges(
        savedZones: [], failedZoneSaves: [], deletedZoneIDs: [],
        failedZoneDeletes: [(zoneID: zoneID, error: makeCKError(.zoneNotFound))]))

    XCTAssertTrue(
      confirmedDeletedZoneIDs.contains(zoneID),
      "zoneNotFound-on-delete fires the confirmation hook for that zone")
    XCTAssertFalse(hasPendingZoneDelete(), "zoneNotFound ⇒ confirmed, not re-added")
  }

  func testGivenFailedZoneDelete_WhenRetriable_ThenReAddedWithoutZoneSpecificConfirmation() {
    let controller = makeController()
    controller.start()
    controller.startupTask?.cancel()

    var confirmedDeletedZoneIDs: [CKRecordZone.ID] = []
    controller.onZoneChangeConfirmed = { _, deleted in
      confirmedDeletedZoneIDs.append(contentsOf: deleted)
    }

    controller.handle(
      .sentDatabaseChanges(
        savedZones: [], failedZoneSaves: [], deletedZoneIDs: [],
        failedZoneDeletes: [(zoneID: zoneID, error: makeCKError(.networkFailure))]))

    XCTAssertTrue(hasPendingZoneDelete(), "retriable zone delete ⇒ re-add")
    XCTAssertFalse(
      confirmedDeletedZoneIDs.contains(zoneID),
      "retriable delete failure does not confirm that zone")
  }

  // MARK: - §5.4 nextRecordZoneChangeBatch materialization (S-14, S-29)

  func testGivenMaterializableSave_WhenNextBatch_ThenReturnsRecord() {
    let id = UUID()
    let p = BlockedProfiles(id: id, name: "OK")
    context.insert(p)
    try? context.save()
    let controller = makeController()
    controller.start()
    controller.startupTask?.cancel()
    driver.add(pendingRecordZoneChanges: [.saveRecord(recordID(id.uuidString))])

    let batch = controller.nextRecordZoneChangeBatch(scope: nil)
    XCTAssertNotNil(batch?.first { $0.recordID.recordName == id.uuidString })
  }

  func testGivenAbsentEntityPendingSave_WhenNextBatch_ThenRemovedAndNotReturned() {
    let id = UUID()
    let controller = makeController()
    controller.start()
    controller.startupTask?.cancel()
    driver.add(pendingRecordZoneChanges: [.saveRecord(recordID(id.uuidString))])

    let batch = controller.nextRecordZoneChangeBatch(scope: nil)

    XCTAssertNil(
      batch?.first { $0.recordID.recordName == id.uuidString },
      "absent entity save not materialized (§5.4)")
    XCTAssertFalse(pendingSaveNames().contains(id.uuidString), "stray pending save removed")
  }

  func testGivenNewerSchemaProfilePendingSave_WhenNextBatch_ThenRemoved() {
    let id = UUID()
    let p = BlockedProfiles(id: id, name: "Newer")
    context.insert(p)
    try? context.save()
    let controller = makeController()
    controller.start()
    controller.startupTask?.cancel()
    driver.add(pendingRecordZoneChanges: [.saveRecord(recordID(id.uuidString))])

    // Force provider.record(...) to return nil by making the local record un-materializable:
    // set its schema version above current so provider treats it as isNewerSchemaVersion.
    p.profileSchemaVersion = BlockedProfiles.currentSchemaVersion + 1
    try? context.save()

    let batch = controller.nextRecordZoneChangeBatch(scope: nil)

    XCTAssertNil(
      batch?.first { $0.recordID.recordName == id.uuidString },
      "unmaterializable/newer-schema save not materialized (§5.4/S-14)")
    XCTAssertFalse(pendingSaveNames().contains(id.uuidString), "stray pending save removed")
  }

  func testGivenTombstonelessPendingDelete_WhenNextBatch_ThenRemovedUnlessLegacy() {
    let orphanId = "orphan"
    let legacyId = "legacy-y"
    store.addLegacyCleanupIds([legacyId])
    let controller = makeController()
    controller.start()
    controller.startupTask?.cancel()
    driver.add(pendingRecordZoneChanges: [
      .deleteRecord(recordID(orphanId)),  // no tombstone ⇒ refuse
      .deleteRecord(recordID(legacyId)),  // legacy exempt ⇒ kept
    ])

    _ = controller.nextRecordZoneChangeBatch(scope: nil)

    XCTAssertFalse(pendingDeleteNames().contains(orphanId), "tombstone-less delete removed (§5.4)")
    XCTAssertTrue(pendingDeleteNames().contains(legacyId), "legacy cleanup delete exempt")
  }

  func testGivenTombstonedPendingDelete_WhenNextBatch_ThenKept() {
    let id = UUID()
    store.setTombstone(recordName: id.uuidString, changeTag: "t")
    let controller = makeController()
    controller.start()
    controller.startupTask?.cancel()
    driver.add(pendingRecordZoneChanges: [.deleteRecord(recordID(id.uuidString))])

    _ = controller.nextRecordZoneChangeBatch(scope: nil)

    XCTAssertTrue(
      pendingDeleteNames().contains(id.uuidString),
      "delete with a live tombstone is kept, not refused (§5.4)")
  }

  func testGivenPendingResetCommandSave_WhenNextBatch_ThenMaterializedViaResetNotProvider() {
    // Fix 1 [CRITICAL]: the fixed-name command record is never a data entity the provider
    // knows about (provider.record(forRecordName:) always returns nil for it) — it must be
    // materialized via `reset?.commandRecord(now:)` instead, or the reset command is
    // silently stripped from the batch every time (ResetController.commandRecord dead code).
    let controller = makeController()
    controller.start()
    controller.startupTask?.cancel()
    store.resetIntent = ResetIntent(
      id: UUID(), clear: false, stage: .seeding, priorCommandId: nil)
    driver.add(
      pendingRecordZoneChanges: [.saveRecord(recordID(ResetController.commandRecordName))])

    let batch = controller.nextRecordZoneChangeBatch(scope: nil)

    let command = batch?.first { $0.recordID.recordName == ResetController.commandRecordName }
    XCTAssertNotNil(command, "command record materialized into the batch (Fix 1)")
    XCTAssertEqual(command?.recordType, SyncResetRequest.recordType)
  }

  func testGivenPendingResetCommandSaveNoLiveIntent_WhenNextBatch_ThenRemovedNotReturned() {
    // No live resetIntent ⇒ commandRecord(now:) returns nil ⇒ falls through to the same
    // remove-from-queue path as any other unmaterializable save.
    let controller = makeController()
    controller.start()
    controller.startupTask?.cancel()
    driver.add(
      pendingRecordZoneChanges: [.saveRecord(recordID(ResetController.commandRecordName))])

    let batch = controller.nextRecordZoneChangeBatch(scope: nil)

    XCTAssertNil(batch?.first { $0.recordID.recordName == ResetController.commandRecordName })
    XCTAssertFalse(pendingSaveNames().contains(ResetController.commandRecordName))
  }

  // MARK: - T10 stateUpdate persistence (AB-2, S-26)

  func testGivenStateUpdate_WhenHandled_ThenEngineStatePersisted() {
    let controller = makeController()
    controller.start()
    controller.startupTask?.cancel()
    let serialization = Data([0xAB, 0xCD])

    controller.handle(.stateUpdate(serialization: serialization))

    XCTAssertEqual(store.engineState, serialization, "T10 persists serialization (AB-2 fetch tokens)")
  }

  func testGivenStateUpdateBetweenTwoFetchEvents_WhenPersisted_ThenSecondEventReDeliveredOnRelaunch() {
    // AB-2 (S-26): persisting on stateUpdate only reflects fetch progress already handled.
    // We assert the controller persists the serialization it was handed and never fabricates one.
    let controller = makeController()
    controller.start()
    controller.startupTask?.cancel()
    controller.handle(.fetchedRecordZoneChanges(modifications: [], deletions: []))
    controller.handle(.stateUpdate(serialization: Data([0x01])))
    controller.handle(.fetchedRecordZoneChanges(modifications: [], deletions: []))
    // No further stateUpdate ⇒ engineState still reflects the first serialization; on relaunch the
    // engine re-delivers the second event's changes (nothing persisted past [0x01]).
    XCTAssertEqual(store.engineState, Data([0x01]))
  }

  // MARK: - T5/T6 zone events (§8.4, S-3, S-4)

  func testGivenZoneDeleted_WhenHandled_ThenDataIntactPurgeIntentFirstSeed() async {
    let p = BlockedProfiles(name: "A")
    context.insert(p)
    try? context.save()
    store.setSystemFields(Data([0x1]), for: "stale")
    let controller = makeController()
    controller.start()
    await controller.startupTask?.value

    controller.handle(
      .fetchedDatabaseChanges(
        modifiedZoneIDs: [], deletedZones: [(zoneID: zoneID, reason: .deleted)]))
    await controller.flushTask?.value

    XCTAssertNotNil(try? context.fetch(FetchDescriptor<BlockedProfiles>()).first, "data intact (I1)")
    XCTAssertNil(store.systemFields(for: "stale"), "I6 purge")
    XCTAssertEqual(sessionSync.flushCount, 1, "session cache flushed (I6)")
    XCTAssertTrue(store.pendingSeedIntent, "intent-first seed (T5/I11)")
    XCTAssertTrue(hasPendingZoneSave())
  }

  func testGivenZonePurged_WhenHandled_ThenDisabledDiscardStateTombstonesIntact() {
    store.engineState = Data([0x1])
    store.resetIntent = ResetIntent(id: UUID(), clear: false, stage: .deleting, priorCommandId: nil)
    store.pendingSeedIntent = true
    store.setTombstone(recordName: "keep", changeTag: "t")
    let controller = makeController()
    controller.start()
    controller.startupTask?.cancel()

    controller.handle(
      .fetchedDatabaseChanges(
        modifiedZoneIDs: [], deletedZones: [(zoneID: zoneID, reason: .purged)]))

    XCTAssertEqual(controller.state, .purged, "T6")
    XCTAssertNil(store.engineState, "engine state discarded")
    XCTAssertNil(store.resetIntent)
    XCTAssertFalse(store.pendingSeedIntent)
    XCTAssertNotNil(store.deleteTombstones["keep"], "tombstones survive (not consent-scoped)")
    XCTAssertFalse(SharedData.deviceSyncEnabled, "sync disabled")
    XCTAssertTrue(pendingSaveNames().isEmpty, "nothing enqueued")
  }

  // MARK: - T7 accountChange (§7)

  func testGivenAccountChange_WhenHandled_ThenStopInvalidateContinuationsPurgeNothing() async {
    store.setSystemFields(Data([0x1]), for: "keep")
    let controller = makeController()
    controller.start()
    controller.handle(.accountChange(kind: .switchAccounts))

    XCTAssertEqual(controller.state, .disabled)
    XCTAssertNotNil(store.systemFields(for: "keep"), "account change purges nothing (§7)")
    XCTAssertTrue(controller.startupTask?.isCancelled ?? true, "in-flight continuations invalidated")
  }

  // MARK: - T11 stop (N5)

  func testGivenStop_WhenCalled_ThenClearIntentsBestEffortSendTombstonesSurvive() {
    store.engineState = Data([0x1])
    store.resetIntent = ResetIntent(id: UUID(), clear: false, stage: .deleting, priorCommandId: nil)
    store.pendingSeedIntent = true
    store.setTombstone(recordName: "keep", changeTag: "t")
    var stopResetCalled = false
    let controller = makeController()
    controller.start()
    controller.startupTask?.cancel()
    // Fix 7 (T11): start() now wires the real onStopReset ⇒ ResetController.abandonForStop.
    // Override AFTER start(), same as the other hook-overriding tests in this file, so this
    // test can keep asserting call ORDER without exercising the real dequeue mechanic (that
    // is covered separately below by the zone-dequeue/no-supersession test).
    controller.onStopReset = { stopResetCalled = true }

    controller.stop()

    XCTAssertTrue(stopResetCalled, "reset dequeue hook invoked first (T11)")
    XCTAssertFalse(store.pendingSeedIntent)
    XCTAssertNil(store.engineState, "engine state discarded (N5 saves lost)")
    XCTAssertNotNil(store.deleteTombstones["keep"], "tombstones survive T11 (re-propagate via I12)")
    XCTAssertEqual(driver.sendChangesCount, 1, "best-effort final send")
    XCTAssertEqual(controller.state, .disabled)
  }

  /// Fix 7 (T11 contract violation): a `deleteZone` enqueued by a live `.deleting` reset
  /// must be dequeued BEFORE `stop()`'s best-effort final `sendChanges()` — otherwise a
  /// user-initiated sync disable flushes a mid-reset zone deletion to CloudKit. This must
  /// also NOT surface a "reset superseded" conflict (that banner is reserved for a reset
  /// abandoned by a FOREIGN command, never for the user's own disable).
  func testGivenMidDeletingReset_WhenStop_ThenDeleteZoneDequeuedNoSupersededResetIntentCleared() {
    let controller = makeController()
    controller.start()
    controller.startupTask?.cancel()
    controller.beginReset(clearRemoteAppSelections: false)
    XCTAssertEqual(store.resetIntent?.stage, .deleting, "sanity: mid-reset before stop")
    XCTAssertTrue(hasPendingZoneDelete(), "sanity: deleteZone enqueued by beginReset")

    controller.stop()

    XCTAssertFalse(
      hasPendingZoneDelete(), "T11: mid-reset deleteZone dequeued before the final send")
    XCTAssertFalse(
      SyncConflictManager.shared.resetWasSuperseded,
      "user-initiated disable must never surface a superseded-reset conflict")
    XCTAssertNil(store.resetIntent, "resetIntent cleared")
    XCTAssertEqual(controller.state, .disabled)
  }

  // MARK: - §8.1 reset resume hook

  func testGivenResetIntentSet_WhenStart_ThenResumeHookInvoked() async {
    store.engineState = Data([0x1])
    let intent = ResetIntent(id: UUID(), clear: true, stage: .recreating, priorCommandId: nil)
    store.resetIntent = intent
    var resumed: ResetIntent?
    let controller = makeController()
    controller.start()
    // Phase F (Task 134b): start() now wires onResumeReset to the composed
    // ResetController — override it here, after start(), same as the other
    // hook-overriding tests in this file.
    controller.onResumeReset = { resumed = $0 }
    await controller.startupTask?.value

    XCTAssertEqual(resumed?.id, intent.id, "§8.1 resume delegated to Phase E hook")
  }
}
