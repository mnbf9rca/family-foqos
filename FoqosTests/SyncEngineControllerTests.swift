import CloudKit
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
private final class StartupRecoveryGate {
  private var hasEntered = false
  private var entryContinuation: CheckedContinuation<Void, Never>?
  private var releaseContinuation: CheckedContinuation<Void, Never>?

  func suspend() async {
    hasEntered = true
    entryContinuation?.resume()
    entryContinuation = nil
    await withCheckedContinuation { releaseContinuation = $0 }
  }

  func waitUntilEntered() async {
    guard !hasEntered else { return }
    await withCheckedContinuation { entryContinuation = $0 }
  }

  func release() {
    releaseContinuation?.resume()
    releaseContinuation = nil
  }
}

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
    suiteName = "SyncEngineControllerTests-\(UUID().uuidString)"
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

  func countPendingZoneSaves() -> Int {
    driver.pendingDatabaseChanges.reduce(into: 0) { count, change in
      if case .saveZone = change { count += 1 }
    }
  }

  func countPendingSaves(named name: String) -> Int {
    driver.pendingRecordZoneChanges.reduce(into: 0) { count, change in
      if case .saveRecord(let id) = change, id.recordName == name {
        count += 1
      }
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

  // MARK: - #286 self-heal (discard poisoned restored serialization)

  func testGivenRestoredStateHasPendingZoneDelete_WhenStart_ThenSerializationDiscardedAndFreshEngine()
    async
  {
    store.engineState = Data([0x01])  // non-nil stand-in for a poisoned serialization
    let poisoned = MockSyncEngineDriver(pendingDatabaseChanges: [.deleteZone(zoneID)])
    let fresh = MockSyncEngineDriver()
    var pending: [MockSyncEngineDriver] = [poisoned, fresh]
    var factoryArgs: [Data?] = []
    let controller = SyncEngineController(
      modelContext: context, store: store,
      driverFactory: { data in
        factoryArgs.append(data)
        return pending.removeFirst()
      },
      apply: apply, provider: provider, sessionSync: sessionSync, deviceId: deviceId)

    controller.start()
    await controller.startupTask?.value

    XCTAssertNil(store.engineState, "#286 self-heal: poisoned serialization discarded")
    XCTAssertEqual(factoryArgs.count, 2, "engine rebuilt exactly once after discard")
    XCTAssertNil(factoryArgs[1], "rebuilt with nil serialization (fresh engine, no restored tokens)")
    XCTAssertFalse(
      (controller.driver as! MockSyncEngineDriver).pendingDatabaseChanges.contains {
        if case .deleteZone = $0 { return true } else { return false }
      },
      "active engine carries no pending zone-deletion")
  }

  func testGivenActiveResetIntentAndRestoredState_WhenStart_ThenSerializationDiscardedBeforeFactory()
    async
  {
    store.engineState = Data([0x01])
    store.resetIntent = ResetIntent(id: UUID(), clear: false, stage: .deleting, priorCommandId: nil)
    let fresh = MockSyncEngineDriver()
    var factoryArgs: [Data?] = []
    let controller = SyncEngineController(
      modelContext: context, store: store,
      driverFactory: { data in
        factoryArgs.append(data)
        return fresh
      },
      apply: apply, provider: provider, sessionSync: sessionSync, deviceId: deviceId)

    controller.start()
    await controller.startupTask?.value

    XCTAssertNil(store.engineState, "active reset discards restored serialization up front")
    XCTAssertEqual(factoryArgs.count, 1, "no disposable driver should be constructed")
    XCTAssertNil(factoryArgs[0], "first driver is built with nil serialization")
  }

  func testGivenNonPoisonedRestoredState_WhenStart_ThenSerializationKeptEngineNotRebuilt()
    async
  {
    store.engineState = Data([0x01])  // non-nil, no reset in progress, no pending deleteZone
    let normal = MockSyncEngineDriver()
    var factoryCount = 0
    let controller = SyncEngineController(
      modelContext: context, store: store,
      driverFactory: { _ in
        factoryCount += 1
        return normal
      },
      apply: apply, provider: provider, sessionSync: sessionSync, deviceId: deviceId)

    controller.start()
    await controller.startupTask?.value

    XCTAssertEqual(factoryCount, 1, "no rebuild for a healthy serialization")
    XCTAssertNotNil(store.engineState, "healthy serialization retained (ordinary relaunch, S-19)")
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

  func testRestorableRecordNames_IncludesEpochAndEvents() {
    let now = Date()
    emergencyManager.seedForTesting(epoch: 4)
    let event = emergencyManager.consumeUnblockEvent(now: now)
    let controller = makeController()

    let names = Set(controller.restorableRecordNames())

    XCTAssertTrue(names.contains(SyncedEmergencyEpoch.recordName))
    XCTAssertTrue(names.contains(event.recordName))
  }

  func testRestorableRecordNames_IncludesEstablishmentOnlyAfterGenerationBump() {
    let controller = makeController()

    XCTAssertFalse(Set(controller.restorableRecordNames()).contains(SyncedEstablishment.recordName))

    store.establishmentGeneration = 1

    XCTAssertTrue(Set(controller.restorableRecordNames()).contains(SyncedEstablishment.recordName))
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

  func testGivenStartupPastInitialGuard_WhenTeardownBeforeSeedDecision_ThenStartupExitsCleanly()
    async
  {
    store.engineState = nil
    let gate = StartupRecoveryGate()
    let controller = makeController()
    controller.beforeSeedDecisionForTest = { await gate.suspend() }
    controller.start()
    await gate.waitUntilEntered()

    controller.prepareForAccountSwitch()
    gate.release()
    await controller.startupTask?.value

    XCTAssertEqual(controller.state, .disabled)
    XCTAssertFalse(controller.hasLiveDriver)
  }

  func testGivenPendingSeedFlushSuspended_WhenTeardownOccurs_ThenStartupDoesNotSeed() async {
    store.engineState = Data([0x01])
    store.pendingSeedIntent = true
    let gate = StartupRecoveryGate()
    sessionSync.beforeFlush = { await gate.suspend() }
    let controller = makeController()
    controller.start()
    await gate.waitUntilEntered()

    controller.prepareForAccountSwitch()
    gate.release()
    await controller.startupTask?.value

    XCTAssertEqual(controller.state, .disabled)
    XCTAssertFalse(controller.hasLiveDriver)
  }

  func testGivenResetIntentDeletingAndNilEngineState_WhenStart_ThenStartupDoesNotOwnSeedZone() async {
    store.engineState = nil
    store.resetIntent = ResetIntent(id: UUID(), clear: false, stage: .deleting, priorCommandId: nil)
    let p = BlockedProfiles(name: "A")
    context.insert(p)
    try? context.save()

    let controller = makeController()
    controller.start()
    await controller.startupTask?.value
    await Task.yield()

    XCTAssertFalse(hasPendingZoneSave(), "startup seeding must not enqueue saveZone during reset")
    XCTAssertTrue(hasPendingZoneDelete(), "reset resume owns the deleting stage")
    XCTAssertFalse(
      pendingSaveNames().contains(p.id.uuidString),
      "startup must not enqueue record seeding while reset owns startup")
  }

  func testGivenResetIntentRecreatingAndNilEngineState_WhenStart_ThenOnlyResetResumeEnqueuesSaveZone()
    async
  {
    store.engineState = nil
    store.resetIntent = ResetIntent(
      id: UUID(), clear: false, stage: .recreating, priorCommandId: nil)
    let p = BlockedProfiles(name: "A")
    context.insert(p)
    try? context.save()

    let controller = makeController()
    controller.start()
    await controller.startupTask?.value
    await Task.yield()

    XCTAssertEqual(countPendingZoneSaves(), 1, "reset resume owns the recreating saveZone")
    XCTAssertFalse(hasPendingZoneDelete())
    XCTAssertFalse(
      pendingSaveNames().contains(p.id.uuidString),
      "generic startup seed must not duplicate reset-owned recreation")
  }

  func testGivenResetIntentSeedingAndNilEngineState_WhenStart_ThenOnlyResetResumeEnqueuesSingleSeedBatch()
    async
  {
    store.engineState = nil
    store.resetIntent = ResetIntent(id: UUID(), clear: false, stage: .seeding, priorCommandId: nil)
    let p = BlockedProfiles(name: "A")
    context.insert(p)
    try? context.save()

    let controller = makeController()
    controller.start()
    await controller.startupTask?.value
    await Task.yield()

    XCTAssertEqual(countPendingZoneSaves(), 1, "reset seeding should enqueue one zone save")
    XCTAssertEqual(
      countPendingSaves(named: ResetController.commandRecordName), 1,
      "reset seeding should enqueue one command save")
    XCTAssertEqual(
      countPendingSaves(named: p.id.uuidString), 1,
      "reset seeding should enqueue one profile save batch")
    XCTAssertEqual(
      countPendingSaves(named: SyncedEmergencySettings.recordName), 1,
      "reset seeding should enqueue one emergency-settings seed")
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
      Set([p.id.uuidString, SyncedEmergencySettings.recordName, SyncedEmergencyEpoch.recordName]))

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

  func testGivenPostAdoptionEqualEstablishmentConflict_WhenRelaunched_ThenSeedDoesNotRecur()
    async throws
  {
    store.engineState = nil
    store.establishmentGeneration = 1

    let controller = makeController()
    controller.start()
    await controller.startupTask?.value

    let batch = try XCTUnwrap(controller.nextRecordZoneChangeBatch(scope: nil))
    let sentEstablishment = try XCTUnwrap(
      batch.first { $0.recordID.recordName == SyncedEstablishment.recordName })
    let savedRecords = batch.filter {
      $0.recordID.recordName != SyncedEstablishment.recordName
    }
    let serverEstablishment = SyncedEstablishment(generation: 1, establishedAt: Date())
      .toCKRecord(in: zoneID)
    let conflict = makeCKError(
      .serverRecordChanged,
      userInfo: [CKRecordChangedErrorServerRecordKey: serverEstablishment])

    controller.handle(
      .sentRecordZoneChanges(
        savedRecords: savedRecords,
        failedRecordSaves: [(record: sentEstablishment, error: conflict)],
        deletedRecordIDs: [],
        failedRecordDeletes: []))
    controller.handle(
      .sentDatabaseChanges(
        savedZones: [zoneID], failedZoneSaves: [], deletedZoneIDs: [], failedZoneDeletes: []))

    XCTAssertNotNil(
      store.systemFields(for: SyncedEstablishment.recordName),
      "equal-generation server metadata must become the fixed record's change-tag base")
    XCTAssertFalse(
      store.pendingSeedIntent,
      "equal-generation conflict is a terminal seed outcome after adoption")

    controller.handle(.stateUpdate(serialization: Data([0x01])))
    let relaunchDriver = MockSyncEngineDriver()
    let relaunchController = SyncEngineController(
      modelContext: context,
      store: store,
      driverFactory: { _ in relaunchDriver },
      apply: apply,
      provider: provider,
      sessionSync: sessionSync,
      deviceId: deviceId)
    relaunchController.start()
    await relaunchController.startupTask?.value

    XCTAssertFalse(
      relaunchDriver.pendingRecordZoneChanges.contains {
        if case .saveRecord(let id) = $0 {
          return id.recordName == SyncedEstablishment.recordName
        }
        return false
      },
      "ordinary relaunch must not repeat the establishment seed")
  }

  func testGivenLowerServerEstablishmentConflict_WhenRetrySucceeds_ThenSeedResolves()
    async throws
  {
    store.engineState = nil
    store.establishmentGeneration = 2

    let controller = makeController()
    controller.start()
    await controller.startupTask?.value

    let batch = try XCTUnwrap(controller.nextRecordZoneChangeBatch(scope: nil))
    let sentEstablishment = try XCTUnwrap(
      batch.first { $0.recordID.recordName == SyncedEstablishment.recordName })
    let savedRecords = batch.filter {
      $0.recordID.recordName != SyncedEstablishment.recordName
    }
    driver.setPendingRecordZoneChangesForTest([])
    let serverEstablishment = SyncedEstablishment(generation: 1, establishedAt: Date())
      .toCKRecord(in: zoneID)
    let conflict = makeCKError(
      .serverRecordChanged,
      userInfo: [CKRecordChangedErrorServerRecordKey: serverEstablishment])

    controller.handle(
      .sentRecordZoneChanges(
        savedRecords: savedRecords,
        failedRecordSaves: [(record: sentEstablishment, error: conflict)],
        deletedRecordIDs: [],
        failedRecordDeletes: []))
    controller.handle(
      .sentDatabaseChanges(
        savedZones: [zoneID], failedZoneSaves: [], deletedZoneIDs: [], failedZoneDeletes: []))

    XCTAssertNotNil(store.systemFields(for: SyncedEstablishment.recordName))
    XCTAssertEqual(countPendingSaves(named: SyncedEstablishment.recordName), 1)
    XCTAssertTrue(store.pendingSeedIntent, "local winner remains pending until retry succeeds")

    let retry = try XCTUnwrap(provider.record(forRecordName: SyncedEstablishment.recordName))
    controller.handle(
      .sentRecordZoneChanges(
        savedRecords: [retry], failedRecordSaves: [], deletedRecordIDs: [],
        failedRecordDeletes: []))

    XCTAssertFalse(store.pendingSeedIntent, "successful local-winner retry resolves the seed")
  }

  func testGivenHigherServerEstablishmentConflictWithoutReset_WhenHandled_ThenAdoptsOnce() {
    store.engineState = Data([0x01])
    store.establishmentGeneration = 1
    let controller = makeController()
    controller.start()
    controller.startupTask?.cancel()
    let sent = SyncedEstablishment(generation: 1, establishedAt: Date()).toCKRecord(in: zoneID)
    let server = SyncedEstablishment(generation: 2, establishedAt: Date()).toCKRecord(in: zoneID)
    let conflict = makeCKError(
      .serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: server])
    var adoptedRecords: [CKRecord] = []
    controller.onFetchedEstablishment = { adoptedRecords.append($0) }

    controller.handle(
      .sentRecordZoneChanges(
        savedRecords: [], failedRecordSaves: [(record: sent, error: conflict)],
        deletedRecordIDs: [], failedRecordDeletes: []))

    XCTAssertEqual(adoptedRecords.count, 1)
    XCTAssertEqual(
      adoptedRecords.first?[SyncedEstablishment.FieldKey.generation.rawValue] as? Int,
      2)
  }

  func testGivenLiveWipingResetAndNonHigherEstablishmentConflict_WhenHandled_ThenDoesNotFallThrough() {
    store.engineState = Data([0x01])
    store.establishmentGeneration = 2
    let controller = makeController()
    controller.start()
    controller.startupTask?.cancel()
    let sent = SyncedEstablishment(generation: 2, establishedAt: Date()).toCKRecord(in: zoneID)

    for serverGeneration in [2, 1] {
      store.resetIntent = ResetIntent(
        id: UUID(), clear: false, wipe: true, stage: .wiping, priorCommandId: nil)
      store.setSystemFields(nil, for: SyncedEstablishment.recordName)
      driver.setPendingRecordZoneChangesForTest([])
      let server = SyncedEstablishment(
        generation: serverGeneration, establishedAt: Date()
      ).toCKRecord(in: zoneID)
      let conflict = makeCKError(
        .serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: server])

      controller.handle(
        .sentRecordZoneChanges(
          savedRecords: [], failedRecordSaves: [(record: sent, error: conflict)],
          deletedRecordIDs: [], failedRecordDeletes: []))

      XCTAssertNil(store.resetIntent, "live wiping intent is consumed")
      XCTAssertNil(
        store.systemFields(for: SyncedEstablishment.recordName),
        "live reset keeps its existing no-cache conflict semantics")
      XCTAssertEqual(
        countPendingSaves(named: SyncedEstablishment.recordName), 0,
        "consumed live reset must not trigger an unowned follow-on write")
    }
  }

  // MARK: - I12 delete-intent recovery (S-29, S-33, CRA-5)

  func testGivenTombstoneEntityPresent_WhenRecover_ThenAbortAndClear() async {
    let id = UUID()
    let p = BlockedProfiles(id: id, name: "A")
    context.insert(p)
    try? context.save()
    store.engineState = Data([0x01])
    store.setTombstone(recordName: id.uuidString, changeTag: "tag-1")
    store.setDeleteWatermark(recordName: id.uuidString, value: 1)

    let controller = makeController()
    controller.start()
    await controller.startupTask?.value

    XCTAssertFalse(
      store.deleteTombstones.keys.contains(id.uuidString),
      "entity present ⇒ abort, clear tombstone")
    XCTAssertNil(store.deleteWatermark(for: id.uuidString), "entity present ⇒ abort, clear watermark")
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

    XCTAssertFalse(
      store.deleteTombstones.keys.contains(id.uuidString),
      "absent ⇒ already complete, cleared")
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
    XCTAssertTrue(
      store.deleteTombstones.keys.contains(id.uuidString),
      "tombstone retained until delete confirmed")
  }

  // #302 acceptance: a tombstone written while sync is disabled enters the existing I12
  // recovered-intent path on re-enable. The adjacent different-tag and entity-present tests
  // cover N5 keep-bias and the round-4/5 live-record guard respectively.
  func testGivenDisabledDeleteTombstone_WhenReEnabledAndServerTagMatches_ThenDeleteEnqueued()
    async
  {
    let id = UUID()
    let recordName = id.uuidString
    store.engineState = Data([0x01])
    store.setTombstone(recordName: recordName, changeTag: "tag-before-disable")
    let record = makeProfileRecord(id: id, version: 1)
    driver.fetchRecordResults[recordName] = .found(record, changeTag: "tag-before-disable")

    let controller = makeController()
    controller.start()
    await controller.startupTask?.value

    XCTAssertTrue(pendingDeleteNames().contains(recordName))
    XCTAssertTrue(
      store.deleteTombstones.keys.contains(recordName),
      "the intent remains durable until the server confirms deletion")
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

    XCTAssertFalse(
      store.deleteTombstones.keys.contains(id.uuidString),
      "different tag ⇒ re-adopted, cleared")
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

    XCTAssertTrue(
      store.deleteTombstones.keys.contains(id.uuidString),
      "transient ⇒ keep, retry later")
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

    XCTAssertTrue(
      store.deleteTombstones.keys.contains(id.uuidString),
      "zoneNotFound ⇒ keep, §5.6 re-verifies (Fix 3)")
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
    store.setSystemFields(Data("cached".utf8), for: deletePresentId.uuidString)
    store.setTombstone(recordName: deletePresentId.uuidString, changeTag: "stale-delete-tag")
    driver.add(pendingRecordZoneChanges: [.deleteRecord(recordID(deletePresentId.uuidString))])

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
    XCTAssertNil(
      store.deleteTombstones[deletePresentId.uuidString] ?? nil,
      "verified-present retry drops stale delete tombstone")
    XCTAssertNil(
      store.systemFields(for: deletePresentId.uuidString),
      "verified-present retry drops stale delete system fields")
    XCTAssertFalse(
      pendingDeleteNames().contains(deletePresentId.uuidString),
      "verified-present retry removes stale pending delete")
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

  func testGivenFailedRemoteDeleteRetryFindsServerRecordButLocalDeletePending_WhenRetried_ThenLocalDeleteIntentSurvives()
    async
  {
    store.engineState = Data([0x01])
    let id = UUID()
    store.addFailedApply(
      FailedApply(recordName: id.uuidString, recordType: SyncedProfile.recordType, op: .delete))
    store.setSystemFields(Data("cached".utf8), for: id.uuidString)
    store.setTombstone(recordName: id.uuidString, changeTag: "local-delete-tag")
    driver.add(pendingRecordZoneChanges: [.deleteRecord(recordID(id.uuidString))])
    driver.fetchRecordResults[id.uuidString] = .found(
      makeProfileRecord(id: id, version: 1, name: "ServerStillHasIt"),
      changeTag: "local-delete-tag")

    let controller = makeController()
    controller.start()
    await controller.startupTask?.value

    XCTAssertNil(
      store.failedApplies.first { $0.recordName == id.uuidString },
      "verified-present retry drops the stale remote failed apply")
    XCTAssertTrue(
      store.deleteTombstones.keys.contains(id.uuidString),
      "newer local delete tombstone must survive the remote failed-apply cleanup")
    XCTAssertNotNil(
      store.systemFields(for: id.uuidString),
      "newer local delete keeps cached system fields until delete confirmation")
    XCTAssertTrue(
      pendingDeleteNames().contains(id.uuidString),
      "newer local pending delete must still propagate")
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

  func testGivenFetchCycle_WhenDidFetchChanges_ThenSchedulesReconciledOnceWithApplyContext()
    async
  {
    store.engineState = Data([0x01])
    var reconciledContexts: [ModelContext] = []
    let controller = SyncEngineController(
      modelContext: context,
      store: store,
      driverFactory: { [driver] _ in driver! },
      apply: apply,
      provider: provider,
      sessionSync: sessionSync,
      deviceId: deviceId,
      scheduleReconciler: { reconciledContexts.append($0) })
    controller.start()
    await controller.startupTask?.value

    controller.handle(.willFetchChanges)
    controller.handle(.didFetchChanges)

    XCTAssertEqual(reconciledContexts.count, 0, "reconcile waits for post-cycle retry sweep")
    await controller.fetchCycleSweepTask?.value
    XCTAssertEqual(reconciledContexts.count, 1)
    XCTAssertTrue(reconciledContexts.first === context)
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

  func testGivenPendingReenqueueAtRetryEntry_WhenTeardownOccurs_ThenTailDoesNotUseDriver() async {
    store.engineState = Data([0x01])
    let controller = makeController()
    controller.start()
    await controller.startupTask?.value

    let id = UUID()
    let local = BlockedProfiles(id: id, name: "Local", syncVersion: 5)
    context.insert(local)
    try? context.save()
    let remote = makeProfileRecord(id: id, version: 5, name: "Remote")
    remote[SyncedProfile.FieldKey.updatedAt.rawValue] = local.updatedAt.addingTimeInterval(-10)
    _ = apply.applyFetchedModification(remote, isPendingDeleteOrTombstoned: { _ in false })

    let gate = StartupRecoveryGate()
    controller.beforeFailedApplyRetryForTest = { await gate.suspend() }
    controller.handle(.didFetchChanges)
    await gate.waitUntilEntered()

    controller.prepareForAccountSwitch()
    gate.release()
    await controller.fetchCycleSweepTask?.value

    XCTAssertEqual(controller.state, .disabled)
    XCTAssertFalse(controller.hasLiveDriver)
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
    XCTAssertTrue(
      store.deleteTombstones.keys.contains(id.uuidString),
      "tombstone retained until durable delete")
    XCTAssertNotNil(store.systemFields(for: id.uuidString))
    XCTAssertTrue(pendingDeleteNames().contains(id.uuidString), "pending delete retained until commit")

    profileDeleteCommitScheduler.runNext()

    XCTAssertFalse(
      store.deleteTombstones.keys.contains(id.uuidString),
      "tombstone cleared (I12)")
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

  func testGivenResetCommandSuspendedInPurge_WhenAccountSwitchTearsDown_ThenTaskExitsCleanly()
    async
  {
    store.engineState = Data([0x01])
    let controller = makeController()
    controller.start()
    await controller.startupTask?.value

    let gate = StartupRecoveryGate()
    sessionSync.beforeFlush = { await gate.suspend() }
    let request = SyncResetRequest(clearRemoteAppSelections: false, originDeviceId: "device-B")
    controller.handle(
      .fetchedRecordZoneChanges(modifications: [request.toCKRecord(in: zoneID)], deletions: []))
    await gate.waitUntilEntered()
    let task = controller.resetTask

    controller.prepareForAccountSwitch()
    gate.release()
    await task?.value

    XCTAssertFalse(store.processedResetCommandIds.contains(request.requestId))
    XCTAssertEqual(controller.state, .disabled)
    XCTAssertFalse(controller.hasLiveDriver)
  }

  func testGivenResetResumeFetchSuspended_WhenAccountSwitchTearsDown_ThenOutboxStaysIdle()
    async
  {
    store.engineState = Data([0x01])
    store.resetIntent = ResetIntent(
      id: UUID(), clear: false, stage: .deleting, priorCommandId: nil)
    let gate = StartupRecoveryGate()
    driver.beforeFetchRecord = { await gate.suspend() }
    let controller = makeController()
    controller.start()
    await gate.waitUntilEntered()
    let task = controller.resetTask

    let operationCount = driver.operations.count
    controller.prepareForAccountSwitch()
    gate.release()
    await task?.value

    XCTAssertEqual(driver.operations.count, operationCount)
    XCTAssertNil(controller.reset)
    XCTAssertNil(controller.legacyCleanup)
    XCTAssertNil(controller.funnel)
  }

  func testGivenFetchedEstablishment_WhenFetchedModification_ThenRoutedToHookNotGenericApply() {
    let record = SyncedEstablishment(generation: 2, establishedAt: Date()).toCKRecord(in: zoneID)

    let controller = makeController()
    controller.start()
    controller.startupTask?.cancel()

    var capturedRecord: CKRecord?
    var captureCount = 0
    controller.onFetchedEstablishment = { record in
      capturedRecord = record
      captureCount += 1
    }

    controller.handle(
      .fetchedRecordZoneChanges(modifications: [record], deletions: []))

    XCTAssertEqual(captureCount, 1)
    XCTAssertEqual(capturedRecord?.recordID.recordName, SyncedEstablishment.recordName)
    XCTAssertTrue(store.failedApplies.isEmpty)
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
    remoteRecord[SyncedProfile.FieldKey.updatedAt.rawValue] = local.updatedAt.addingTimeInterval(-10)

    controller.handle(
      .fetchedRecordZoneChanges(modifications: [remoteRecord], deletions: []))

    XCTAssertTrue(
      pendingSaveNames().contains(id.uuidString),
      "CRA-1: §5.1 equal-version-divergence reenqueue is drained and reaches the driver as .saveRecord")
    XCTAssertNotNil(
      SyncConflictManager.shared.divergenceProfiles[id],
      "equal-version divergence surfaces a dedicated divergence conflict")
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
    server[SyncedProfile.FieldKey.updatedAt.rawValue] = local.updatedAt.addingTimeInterval(-10)
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
      SyncConflictManager.shared.divergenceProfiles[id], "branch E surfaces a divergence conflict")
  }

  func testGivenHigherLocalEpoch_WhenServerRecordLower_ThenLocalIsStrictlyNewer() {
    emergencyManager.seedForTesting(epoch: 5)
    let controller = makeController()
    let lowerServer = SyncedEmergencyEpoch(epoch: 3).toCKRecord(in: zoneID)
    let equalServer = SyncedEmergencyEpoch(epoch: 5).toCKRecord(in: zoneID)

    XCTAssertTrue(
      controller.localIsStrictlyNewer(
        SyncedEmergencyEpoch.recordType,
        name: SyncedEmergencyEpoch.recordName,
        server: lowerServer))
    XCTAssertFalse(
      controller.localIsStrictlyNewer(
        SyncedEmergencyEpoch.recordType,
        name: SyncedEmergencyEpoch.recordName,
        server: equalServer))
  }

  func testGivenEpochSaveServerRecordChanged_WhenLocalHigher_ThenStoresTagAndReaddsEpoch() {
    store.engineState = Data([0x01])
    emergencyManager.seedForTesting(epoch: 5)
    let controller = makeController()
    controller.start()
    controller.startupTask?.cancel()
    let sent = SyncedEmergencyEpoch(epoch: 5).toCKRecord(in: zoneID)
    let server = SyncedEmergencyEpoch(epoch: 3).toCKRecord(in: zoneID)
    let error = makeCKError(
      .serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: server])

    controller.handle(
      .sentRecordZoneChanges(
        savedRecords: [], failedRecordSaves: [(record: sent, error: error)],
        deletedRecordIDs: [], failedRecordDeletes: []))

    XCTAssertNotNil(store.systemFields(for: SyncedEmergencyEpoch.recordName))
    XCTAssertTrue(pendingSaveNames().contains(SyncedEmergencyEpoch.recordName))
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

    XCTAssertFalse(
      store.deleteTombstones.keys.contains(id.uuidString),
      "U-delete clears the tombstone")
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

    XCTAssertFalse(
      store.deleteTombstones.keys.contains(id.uuidString),
      "confirmed delete clears tombstone (I12)")
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

  func testGivenCancelledStartup_WhenZonePurgedBeforeItRuns_ThenStartupExitsWithoutDriverAccess()
    async
  {
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
    await controller.startupTask?.value

    XCTAssertEqual(controller.state, .purged, "T6")
    XCTAssertNil(store.engineState, "engine state discarded")
    XCTAssertNil(store.resetIntent)
    XCTAssertFalse(store.pendingSeedIntent)
    XCTAssertTrue(
      store.deleteTombstones.keys.contains("keep"),
      "tombstones survive (not consent-scoped)")
    XCTAssertFalse(SharedData.deviceSyncEnabled, "sync disabled")
    XCTAssertTrue(pendingSaveNames().isEmpty, "nothing enqueued")
    XCTAssertNil(controller.reset)
    XCTAssertNil(controller.legacyCleanup)
    XCTAssertNil(controller.funnel)
  }

  func testGivenStartupPastInitialGuard_WhenZonePurgedDuringRecovery_ThenStartupExitsCleanly()
    async
  {
    let gate = StartupRecoveryGate()
    let controller = makeController()
    controller.beforeDeleteIntentRecoveryForTest = { await gate.suspend() }
    controller.start()
    await gate.waitUntilEntered()

    controller.handle(
      .fetchedDatabaseChanges(
        modifiedZoneIDs: [], deletedZones: [(zoneID: zoneID, reason: .purged)]))
    gate.release()
    await controller.startupTask?.value

    XCTAssertEqual(controller.state, .purged)
    XCTAssertFalse(controller.hasLiveDriver)
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
    XCTAssertNil(controller.reset)
    XCTAssertNil(controller.legacyCleanup)
    XCTAssertNil(controller.funnel)
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
    XCTAssertTrue(
      store.deleteTombstones.keys.contains("keep"),
      "tombstones survive T11 (re-propagate via I12)")
    XCTAssertEqual(driver.sendChangesCount, 1, "best-effort final send")
    XCTAssertEqual(controller.state, .disabled)
    XCTAssertNil(controller.reset)
    XCTAssertNil(controller.legacyCleanup)
    XCTAssertNil(controller.funnel)
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
