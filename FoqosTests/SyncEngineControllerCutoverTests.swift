import CloudKit
import SwiftData
import XCTest

@testable import FamilyFoqos

/// Task 131 (Phase F): `SyncEngineController` conforms to `SyncEngineControlling`.
/// Covers `requestSync` scheduling fetch+send on the driver, the `enqueue*` verbs
/// forwarding through the controller's `MutationFunnel`, and the T1/I11 bootstrap-seed
/// integration path (real store + a real ModelContext-backed profile + the recording driver).
@MainActor
final class SyncEngineControllerCutoverTests: XCTestCase {
  var testSuiteName: String!
  var container: ModelContainer!
  var context: ModelContext!
  var store: SyncEngineStore!
  var driver: CutoverRecordingDriver!
  var controller: SyncEngineController!
  var profileDeleteCommitScheduler: ManualProfileDeleteCommitScheduler!
  let zoneID = CKRecordZone.ID(
    zoneName: CloudKitConstants.syncZoneName, ownerName: CKCurrentUserDefaultName)

  override func setUp() async throws {
    try await super.setUp()
    testSuiteName = "SyncEngineControllerCutoverTests-\(UUID().uuidString)"
    SharedData.configure(suite: UserDefaults(suiteName: testSuiteName)!)
    container = try TestModelContainer.create()
    context = container.mainContext
    store = SyncEngineStore(userRecordName: "user-A", defaults: UserDefaults(suiteName: testSuiteName)!)
    driver = CutoverRecordingDriver(stateSerialization: nil)
    profileDeleteCommitScheduler = ManualProfileDeleteCommitScheduler()
    let deviceId = SharedData.deviceSyncId.uuidString
    let apply = SyncApplyService(
      modelContext: context, store: store, sessionController: MockSessionController(),
      emergencyManager: EmergencyUnblockManager(), deviceId: deviceId)
    let provider = RecordProvider(
      modelContext: context, store: store, emergencyManager: EmergencyUnblockManager(), deviceId: deviceId)
    controller = SyncEngineController(
      modelContext: context, store: store, driverFactory: { [driver] _ in driver! },
      apply: apply, provider: provider, sessionSync: MockSessionSyncFlushing(), deviceId: deviceId,
      scheduleProfileDeleteCommit: profileDeleteCommitScheduler.schedule)
  }

  override func tearDown() async throws {
    UserDefaults().removePersistentDomain(forName: testSuiteName)
    try await super.tearDown()
  }

  private func makeProfile(now: Date) -> BlockedProfiles {
    let profile = BlockedProfiles(id: UUID(), name: "Focus", createdAt: now, updatedAt: now)
    context.insert(profile)
    try? context.save()
    return profile
  }

  /// Drains fire-and-forget `Task { await ... }` work scheduled by a reset hook closure
  /// (e.g. `onFetchedResetCommand`, `onZoneChangeConfirmed`'s delete branch) so its
  /// async side effects are observable before assertions run.
  private func drainPendingTasks() async {
    for _ in 0..<10 { await Task.yield() }
  }

  func testGivenFreshEngineState_WhenStarted_ThenBootstrapSeedEnqueued() async throws {
    let now = Date()
    let profile = makeProfile(now: now)

    controller.start()
    await controller.startupTask?.value

    // I11: first bootstrap (engineState == nil) seeds the zone + all restorable records.
    XCTAssertTrue(driver.enqueuedZoneSaveNames.contains(CloudKitConstants.syncZoneName))
    XCTAssertTrue(driver.enqueuedSaveNames.contains(profile.id.uuidString))
    XCTAssertTrue(driver.enqueuedSaveNames.contains(SyncedEmergencySettings.recordName))
    XCTAssertTrue(store.pendingSeedIntent)
  }

  func testGivenStartedController_WhenRequestSync_ThenFetchAndSendScheduled() {
    controller.start()
    let fetchBefore = driver.fetchChangesCount
    let sendBefore = driver.sendChangesCount

    controller.requestSync()

    XCTAssertEqual(driver.fetchChangesCount, fetchBefore + 1)
    XCTAssertEqual(driver.sendChangesCount, sendBefore + 1)
  }

  func testGivenStartedController_WhenEnqueueProfileSave_ThenFunnelEnqueuesOnDriver() throws {
    let now = Date()
    let profile = makeProfile(now: now)
    controller.start()
    let before = driver.enqueuedSaveNames.filter { $0 == profile.id.uuidString }.count

    try controller.enqueueProfileSave(profile.id)

    let after = driver.enqueuedSaveNames.filter { $0 == profile.id.uuidString }.count
    XCTAssertEqual(after, before + 1)
    let refreshed = try XCTUnwrap(try BlockedProfiles.findProfile(byID: profile.id, in: context))
    XCTAssertGreaterThanOrEqual(refreshed.syncVersion, 1)  // funnel bumped in the same write
  }

  // MARK: - Review fix: funnel-not-created-yet surfaces (findings #2–#6, #15)

  func testGivenControllerNotStarted_WhenEnqueueProfileSave_ThenThrowsNotAttached() {
    // `funnel` is only created in `start()` — before that, the enqueue verbs must throw
    // instead of silently no-op'ing (review root cause).
    XCTAssertThrowsError(try controller.enqueueProfileSave(UUID())) { error in
      XCTAssertEqual(error as? SyncEngineControllingError, .notAttached)
    }
  }

  func testGivenControllerNotStarted_WhenEnqueueProfileDelete_ThenThrowsNotAttached() {
    XCTAssertThrowsError(try controller.enqueueProfileDelete(UUID())) { error in
      XCTAssertEqual(error as? SyncEngineControllingError, .notAttached)
    }
  }

  func testGivenStartedController_WhenEnqueueDeleteForMissingProfile_ThenGenuineThrowPropagates() {
    // A genuine funnel throw (entityNotFound) must reach the caller, not be swallowed
    // (review finding #15).
    controller.start()

    XCTAssertThrowsError(try controller.enqueueProfileDelete(UUID())) { error in
      XCTAssertEqual(error as? MutationFunnel.MutationFunnelError, .entityNotFound)
    }
  }

  func testGivenReadyProfileDelete_WhenDeferredCommitRuns_ThenSendHappensAfterPendingDeleteEnqueued()
    throws
  {
    let now = Date()
    let profile = makeProfile(now: now)
    controller.start()
    let sendBefore = driver.sendChangesCount

    try controller.enqueueProfileDelete(profile.id, requestSyncAfterPendingDelete: true)

    XCTAssertEqual(profileDeleteCommitScheduler.scheduledOperations.count, 1)
    XCTAssertFalse(
      driver.enqueuedDeleteNames.contains(profile.id.uuidString),
      "profile delete does not enqueue the CK delete until the deferred save commits")
    XCTAssertEqual(
      driver.sendChangesCount, sendBefore,
      "send must not run before the pending .deleteRecord exists")

    profileDeleteCommitScheduler.runNext()

    XCTAssertTrue(driver.enqueuedDeleteNames.contains(profile.id.uuidString))
    XCTAssertEqual(driver.sendChangesCount, sendBefore + 1)
  }

  // MARK: - Task 134b (CRA-4): ResetController + LegacyCleanupCoordinator wiring

  func testGivenFetchedForeignResetCommand_WhenHandled_ThenRoutedToResetControllerApplyCommand()
    async
  {
    controller.start()
    await controller.startupTask?.value
    let resetRequest = SyncResetRequest(clearRemoteAppSelections: false, originDeviceId: "device-B")
    let record = resetRequest.toCKRecord(in: zoneID)

    controller.handle(.fetchedRecordZoneChanges(modifications: [record], deletions: []))
    await drainPendingTasks()

    XCTAssertTrue(
      store.processedResetCommandIds.contains(resetRequest.requestId),
      "onFetchedResetCommand wired to ResetController.applyCommand")
    XCTAssertEqual(store.lastAppliedResetCommandId, resetRequest.requestId)
    XCTAssertNil(
      try? BlockedProfiles.findProfile(byID: resetRequest.requestId, in: context),
      "reset command never applied via the generic apply path")
  }

  func testGivenStartedController_WhenBeginReset_ThenResetIntentPersistedAsDeleting() {
    controller.start()

    controller.beginReset(clearRemoteAppSelections: true)

    XCTAssertEqual(
      store.resetIntent?.stage, .deleting,
      "beginReset(clearRemoteAppSelections:) reaches the composed ResetController")
    XCTAssertEqual(store.resetIntent?.clear, true)
    XCTAssertTrue(
      driver.pendingDatabaseChanges.contains {
        if case .deleteZone(let id) = $0 { return id == zoneID } else { return false }
      }, "deleteZone enqueued by ResetController.beginReset")
  }

  func testGivenDeletingStage_WhenZoneDeleteConfirmedEvent_ThenAdvancesToRecreating() async {
    controller.start()
    await controller.startupTask?.value
    controller.beginReset(clearRemoteAppSelections: false)
    XCTAssertEqual(store.resetIntent?.stage, .deleting)

    controller.handle(
      .sentDatabaseChanges(
        savedZones: [], failedZoneSaves: [], deletedZoneIDs: [zoneID], failedZoneDeletes: []))
    await drainPendingTasks()

    XCTAssertEqual(
      store.resetIntent?.stage, .recreating,
      "onZoneChangeConfirmed wired to ResetController.handleZoneDeleteConfirmed")
  }

  func testGivenFetchedLegacySyncedSession_WhenHandled_ThenIdentifiedDeleteEnqueuedNotAppliedAsProfile() {
    controller.start()
    let legacyRecord = CKRecord(
      recordType: LegacySyncedSession.recordType,
      recordID: CKRecord.ID(recordName: "legacy-session-1", zoneID: zoneID))

    controller.handle(.fetchedRecordZoneChanges(modifications: [legacyRecord], deletions: []))

    XCTAssertTrue(
      store.legacyCleanupIds.contains("legacy-session-1"),
      "legacyCleanup?.identify wired — id persisted")
    XCTAssertTrue(
      driver.enqueuedDeleteNames.contains("legacy-session-1"),
      "legacy record's delete enqueued")
    XCTAssertTrue(
      store.failedApplies.isEmpty,
      "legacy record never routed through the generic apply path")
  }
}
