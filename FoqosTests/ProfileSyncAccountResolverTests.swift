import CloudKit
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class ProfileSyncAccountResolverTests: XCTestCase {
  var suiteName: String!
  var bufferSuiteName: String!
  var defaults: UserDefaults!
  var bufferDefaults: UserDefaults!
  var container: ModelContainer!
  var manager: ProfileSyncManager!
  var savedEnabled = false
  var savedIsSyncReady = false
  var savedController: (any SyncEngineControlling)?
  var savedBufferDefaults: UserDefaults!
  var emergencyManager: EmergencyUnblockManager!
  let recA = CKRecord.ID(recordName: "userA")
  let recB = CKRecord.ID(recordName: "userB")

  override func setUp() async throws {
    try await super.setUp()
    suiteName = "ProfileSyncAccountResolverTests-\(UUID().uuidString)"
    bufferSuiteName = "ProfileSyncAccountResolverTests-buffer-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)!
    bufferDefaults = UserDefaults(suiteName: bufferSuiteName)!
    SharedData.configure(suite: defaults)
    container = try TestModelContainer.create()
    manager = ProfileSyncManager.shared
    savedEnabled = manager.isEnabled
    savedIsSyncReady = manager.isSyncReady
    savedController = manager.engineController
    savedBufferDefaults = manager.bufferDefaults
    manager.bufferDefaults = bufferDefaults
    emergencyManager = EmergencyUnblockManager(defaults: defaults)
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
    UserDefaults().removePersistentDomain(forName: bufferSuiteName)
    UserDefaults().removePersistentDomain(forName: suiteName)
    try await super.tearDown()
  }

  func testAvailabilityMapping() {
    let recordID = CKRecord.ID(recordName: "user-A")

    XCTAssertEqual(
      AccountAvailability(from: .available, recordID: recordID, error: nil),
      .available(recordID))
    XCTAssertEqual(
      AccountAvailability(from: .noAccount, recordID: nil, error: nil),
      .noAccount)
    XCTAssertEqual(
      AccountAvailability(from: .couldNotDetermine, recordID: nil, error: nil),
      .ambiguous)
    XCTAssertEqual(
      AccountAvailability(from: .temporarilyUnavailable, recordID: nil, error: nil),
      .ambiguous)
    XCTAssertEqual(
      AccountAvailability(from: .restricted, recordID: nil, error: nil),
      .ambiguous)
    XCTAssertEqual(
      AccountAvailability(from: .available, recordID: recordID, error: CKError(.networkUnavailable)),
      .ambiguous)
  }

  func testConfirmedSameUserRestartsWhenDisabled() async throws {
    try await makeAttachedManager(namespace: "userA", isEnabled: true, engineState: .disabled)

    manager.resolveAccountChange(availability: .available(recA), newName: "userA")

    XCTAssertNil(manager.accountChangeConflict)
    XCTAssertNil(manager.syncPausedReason)
    XCTAssertTrue(manager.didCallStartForTest)
  }

  func testConfirmedSameUserPurgedDoesNotRestart() async throws {
    try await makeAttachedManager(namespace: "userA", isEnabled: true, engineState: .purged)

    manager.resolveAccountChange(availability: .available(recA), newName: "userA")

    XCTAssertFalse(manager.didCallStartForTest)
  }

  func testConfirmedNoAccountPauses() async throws {
    try await makeAttachedManager(namespace: "userA", isEnabled: true, engineState: .steady)

    manager.resolveAccountChange(availability: .noAccount, newName: nil)

    XCTAssertEqual(manager.syncPausedReason, .signedOut)
    XCTAssertNil(manager.accountChangeConflict)
  }

  func testAmbiguousNeitherPausesNorPrompts() async throws {
    try await makeAttachedManager(namespace: "userA", isEnabled: true, engineState: .steady)

    manager.resolveAccountChange(availability: .ambiguous, newName: nil)

    XCTAssertNil(manager.syncPausedReason)
    XCTAssertNil(manager.accountChangeConflict)
    XCTAssertFalse(manager.didTearDownForTest)
  }

  func testSentinelTreatedAsAmbiguousNeverPrompts() async throws {
    try await makeAttachedManager(namespace: "userA", isEnabled: true, engineState: .steady)

    manager.resolveAccountChange(
      availability: .available(nil), newName: CloudKitConstants.defaultUserRecordName)

    XCTAssertNil(manager.accountChangeConflict)
    XCTAssertNil(manager.syncPausedReason)
  }

  func testDefaultUserSentinelConstantRetainsFallbackNamespaceValue() {
    XCTAssertEqual(CloudKitConstants.defaultUserRecordName, "__default_user__")
  }

  func testConfirmedDifferentUserTearsDownAndPublishesConflict() async throws {
    try await makeAttachedManager(namespace: "userA", isEnabled: true, engineState: .steady)

    manager.resolveAccountChange(availability: .available(recB), newName: "userB")

    XCTAssertEqual(manager.accountChangeConflict?.newUserRecordName, "userB")
    XCTAssertEqual(manager.syncPausedReason, .accountChanged)
    XCTAssertTrue(manager.didTearDownForTest)
    XCTAssertFalse(manager.isSyncReady)
  }

  func testCombineReattachesWithForcedSeedWithoutWiping() async throws {
    try await makeAttachedManager(namespace: "userA", isEnabled: true, engineState: .steady)
    manager.resolveAccountChange(availability: .available(recB), newName: "userB")
    seedLocalProfiles(count: 2)

    await manager.resolveConflictCombine()

    XCTAssertEqual(manager.attachedUserRecordName, "userB")
    XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<BlockedProfiles>()).count, 2)
    XCTAssertTrue(manager.lastReattachForceSeedForTest)
    XCTAssertNil(manager.accountChangeConflict)
  }

  func testSwitchWipesLocalAndEmergencyThenReattaches() async throws {
    try await makeAttachedManager(namespace: "userA", isEnabled: true, engineState: .steady)
    manager.resolveAccountChange(availability: .available(recB), newName: "userB")
    let now = Date()
    seedLocalProfiles(count: 2, now: now)
    let location = SavedLocation(
      name: "Library", latitude: 51.5, longitude: -0.1, createdAt: now, updatedAt: now)
    container.mainContext.insert(location)
    try container.mainContext.save()
    _ = emergencyManager.recordAndEnqueueUnblock(now: now)

    await manager.resolveConflictSwitchToCloud()

    XCTAssertEqual(manager.attachedUserRecordName, "userB")
    XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<BlockedProfiles>()).count, 0)
    XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<SavedLocation>()).count, 0)
    XCTAssertEqual(emergencyManager.getRemainingEmergencyUnblocks(), 3)
    XCTAssertNil(manager.accountChangeConflict)
  }

  func testSwitchWipeFailureKeepsConflictWithoutReattachOrEmergencyReset() async throws {
    try await makeAttachedManager(namespace: "userA", isEnabled: true, engineState: .steady)
    manager.resolveAccountChange(availability: .available(recB), newName: "userB")
    let now = Date()
    seedLocalProfiles(count: 1, now: now)
    _ = emergencyManager.recordAndEnqueueUnblock(now: now)
    manager.resetAccountChangeDebugCountersForTest()
    manager.failNextSwitchWipeFinalSaveForTest = true

    // Reattaching after a failed wipe with forceSeed=false would seed leftover local data into
    // the new account's fresh namespace, silently turning Switch into unconsented Combine.
    await manager.resolveConflictSwitchToCloud()

    XCTAssertEqual(manager.attachedUserRecordName, "userA")
    XCTAssertEqual(manager.syncPausedReason, .accountChanged)
    XCTAssertEqual(manager.accountChangeConflict?.newUserRecordName, "userB")
    XCTAssertEqual(manager.pendingConflictName, "userB")
    XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<BlockedProfiles>()).count, 1)
    XCTAssertEqual(emergencyManager.getRemainingEmergencyUnblocks(), 2)
    XCTAssertFalse(manager.didTearDownForTest)
  }

  func testSwitchWithActiveSessionEndsItAndClearsRestrictions() async throws {
    try await makeAttachedManager(namespace: "userA", isEnabled: true, engineState: .steady)
    manager.resolveAccountChange(availability: .available(recB), newName: "userB")
    let now = Date()
    let profile = seedLocalProfiles(count: 1, now: now).first!
    let session = startActiveSession(for: profile, now: now)
    var removedStartSchedules: Set<UUID> = []
    var removedStopSchedules: Set<UUID> = []
    var canceledPreActivationReminders: Set<UUID> = []
    let cleanup = BlockedProfiles.DeleteCleanup(
      removeStartSchedule: { removedStartSchedules.insert($0.id) },
      removeStopSchedule: { removedStopSchedules.insert($0.id) },
      cancelPreActivationReminders: { canceledPreActivationReminders.insert($0) },
      removeBreakBackstop: { _ in },
      removeOneMoreMinuteBackstop: { _ in }
    )

    try await manager.wipeAndReattachForTest(cleanup: cleanup, newName: "userB")

    XCTAssertNotNil(session.endTime)
    XCTAssertTrue(removedStartSchedules.contains(profile.id))
    XCTAssertTrue(removedStopSchedules.contains(profile.id))
    XCTAssertTrue(canceledPreActivationReminders.contains(profile.id))
    XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<BlockedProfiles>()).count, 0)
  }

  func testAdoptHigherEstablishmentGenerationWipesBookkeepingAndForcesRefetch() async throws {
    try await makeAttachedManager(namespace: "userA", isEnabled: true, engineState: .steady)
    let store = SyncEngineStore(userRecordName: "userA")
    store.establishmentGeneration = 1
    store.engineState = Data([0x01])
    store.setTombstone(recordName: "dead", changeTag: "tag")
    store.setDeleteWatermark(recordName: "dead", value: 3)
    store.setSystemFields(Data([0x02]), for: "dead")
    store.addFailedApply(FailedApply(recordName: "dead", recordType: SyncedProfile.recordType, op: .upsert))
    let processed = UUID()
    store.markProcessed(processed)
    let now = Date()
    seedLocalProfiles(count: 2, now: now)
    let location = SavedLocation(
      name: "Library", latitude: 51.5, longitude: -0.1, createdAt: now, updatedAt: now)
    container.mainContext.insert(location)
    try container.mainContext.save()

    await manager.adoptEstablishmentGeneration(2)

    XCTAssertEqual(store.establishmentGeneration, 2)
    XCTAssertNil(store.engineState)
    XCTAssertTrue(store.deleteTombstones.isEmpty)
    XCTAssertNil(store.deleteWatermark(for: "dead"))
    XCTAssertNil(store.systemFields(for: "dead"))
    XCTAssertTrue(store.failedApplies.isEmpty)
    XCTAssertTrue(store.processedResetCommandIds.contains(processed))
    XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<BlockedProfiles>()).count, 0)
    XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<SavedLocation>()).count, 0)
    XCTAssertEqual(manager.attachedUserRecordName, "userA")
    XCTAssertFalse(manager.lastReattachForceSeedForTest)
  }

  func testAdoptionFirstCancelsLiveDeletingWipeAndDequeuesItsZoneDelete() async throws {
    try await makeAttachedManager(namespace: "userA", isEnabled: true, engineState: .steady)
    let store = SyncEngineStore(userRecordName: "userA")
    let resetId = UUID()
    store.establishmentGeneration = 1
    store.resetIntent = ResetIntent(
      id: resetId, clear: false, wipe: true, stage: .deleting, priorCommandId: nil)
    let zoneID = CKRecordZone.ID(
      zoneName: CloudKitConstants.syncZoneName, ownerName: CKCurrentUserDefaultName)
    let driver = try XCTUnwrap((manager.engineController as? SyncEngineController)?.driver as? MockSyncEngineDriver)
    driver.add(pendingDatabaseChanges: [.deleteZone(zoneID)])
    seedLocalProfiles(count: 1)

    await manager.adoptEstablishmentGeneration(2)

    XCTAssertEqual(store.establishmentGeneration, 2)
    XCTAssertNil(store.resetIntent, "adoption must disarm the losing deleting wipe")
    XCTAssertFalse(
      driver.pendingDatabaseChanges.contains(.deleteZone(zoneID)),
      "adoption must dequeue the losing wipe's pending zone delete before reattachment")
  }

  func testEstablishmentSaveConflictAdoptsThroughReattachAndRejectsStaleStateUpdates() async throws {
    try await makeAttachedManager(namespace: "userA", isEnabled: true, engineState: .steady)
    let store = SyncEngineStore(userRecordName: "userA")
    store.establishmentGeneration = 2
    store.engineState = Data([0x01])
    store.resetIntent = ResetIntent(
      id: UUID(), clear: false, wipe: true, stage: .wiping, priorCommandId: nil)
    seedLocalProfiles(count: 1)
    let oldController = try XCTUnwrap(manager.engineController as? SyncEngineController)
    let zoneID = CKRecordZone.ID(
      zoneName: CloudKitConstants.syncZoneName, ownerName: CKCurrentUserDefaultName)
    let now = Date()
    let sent = SyncedEstablishment(generation: 2, establishedAt: now).toCKRecord(in: zoneID)
    let server = SyncedEstablishment(generation: 3, establishedAt: now).toCKRecord(in: zoneID)
    let error = CKError(
      _nsError: NSError(
        domain: CKErrorDomain,
        code: CKError.serverRecordChanged.rawValue,
        userInfo: [CKRecordChangedErrorServerRecordKey: server]))
    let adoptionFinished = expectation(description: "establishment conflict adoption finished")
    let observer = NotificationCenter.default.addObserver(
      forName: .syncEstablishmentGenerationAdopted,
      object: nil,
      queue: nil
    ) { _ in
      adoptionFinished.fulfill()
    }
    defer { NotificationCenter.default.removeObserver(observer) }

    oldController.handle(
      .sentRecordZoneChanges(
        savedRecords: [], failedRecordSaves: [(record: sent, error: error)],
        deletedRecordIDs: [], failedRecordDeletes: []))
    oldController.handle(.stateUpdate(serialization: Data([0x09])))
    await fulfillment(of: [adoptionFinished], timeout: 1)
    oldController.handle(.stateUpdate(serialization: Data([0x0A])))

    XCTAssertEqual(store.establishmentGeneration, 3)
    XCTAssertNil(store.engineState)
    XCTAssertNil(store.resetIntent)
    XCTAssertFalse(manager.engineController === oldController)
    XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<BlockedProfiles>()).count, 0)
  }

  func testSW6GenerationZeroDeviceAdoptsAndDiscardsLocalProfiles() async throws {
    try await makeAttachedManager(namespace: "userA", isEnabled: true, engineState: .steady)
    let store = SyncEngineStore(userRecordName: "userA")
    store.establishmentGeneration = 0
    seedLocalProfiles(count: 2)

    await manager.adoptEstablishmentGeneration(2)

    XCTAssertEqual(store.establishmentGeneration, 2)
    XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<BlockedProfiles>()).count, 0)
    XCTAssertFalse(manager.lastReattachForceSeedForTest)
  }

  func testAdoptEqualEstablishmentGenerationIsNoOp() async throws {
    try await makeAttachedManager(namespace: "userA", isEnabled: true, engineState: .steady)
    let store = SyncEngineStore(userRecordName: "userA")
    store.establishmentGeneration = 2
    seedLocalProfiles(count: 1)

    await manager.adoptEstablishmentGeneration(2)

    XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<BlockedProfiles>()).count, 1)
    XCTAssertFalse(manager.didTearDownForTest)
  }

  func testAdoptionClearsEmergencyLedgerButPreservesSettingsLock() async throws {
    try await makeAttachedManager(namespace: "userA", isEnabled: true, engineState: .steady)
    let now = Date()
    let store = SyncEngineStore(userRecordName: "userA")
    store.establishmentGeneration = 1
    _ = emergencyManager.recordAndEnqueueUnblock(now: now)
    emergencyManager.applyRemoteEmergencySettings(
      SyncedEmergencySettings(
        unblocksRemaining: 1, resetPeriodInDays: 14, lastResetDate: now,
        settingsLocked: true, version: 7, lastModified: now, originDeviceId: "parent"))

    await manager.adoptEstablishmentGeneration(2)

    XCTAssertEqual(emergencyManager.currentResetEpoch, 0)
    XCTAssertEqual(emergencyManager.getRemainingEmergencyUnblocks(), 3)
    XCTAssertTrue(emergencyManager.currentEmergencySettings(deviceId: "device").settingsLocked)
    XCTAssertEqual(emergencyManager.currentEmergencySettings(deviceId: "device").resetPeriodInDays, 14)
  }

  func testConcurrentAdoptionsCoalesceToMaxAndPostOneNotice() async throws {
    try await makeAttachedManager(namespace: "userA", isEnabled: true, engineState: .steady)
    let syncManager = try XCTUnwrap(manager)
    let store = SyncEngineStore(userRecordName: "userA")
    store.establishmentGeneration = 1
    seedLocalProfiles(count: 1)
    let noticePosted = expectation(description: "one coalesced establishment adoption notice")
    noticePosted.assertForOverFulfill = true
    let observer = NotificationCenter.default.addObserver(
      forName: .syncEstablishmentGenerationAdopted,
      object: nil,
      queue: nil
    ) { _ in
      noticePosted.fulfill()
    }
    defer { NotificationCenter.default.removeObserver(observer) }

    async let generationTwo: Void = syncManager.adoptEstablishmentGeneration(2)
    async let generationThree: Void = syncManager.adoptEstablishmentGeneration(3)
    _ = await (generationTwo, generationThree)
    await fulfillment(of: [noticePosted], timeout: 0.1)

    XCTAssertEqual(store.establishmentGeneration, 3)
    XCTAssertEqual(syncManager.establishmentAdoptionNoticeCountForTest, 1)
    XCTAssertEqual(syncManager.maxConcurrentReattachCountForTest, 1)
  }

  func testGenerationWipeStopsEnforcementBeforeDeletingActiveProfile() async throws {
    try await makeAttachedManager(namespace: "userA", isEnabled: true, engineState: .steady)
    let now = Date()
    let profile = seedLocalProfiles(count: 1, now: now).first!
    _ = startActiveSession(for: profile, now: now)
    var events: [String] = []
    let cleanup = BlockedProfiles.DeleteCleanup(
      removeStartSchedule: { _ in events.append("delete") },
      removeStopSchedule: { _ in },
      cancelPreActivationReminders: { _ in },
      removeBreakBackstop: { _ in },
      removeOneMoreMinuteBackstop: { _ in })

    try manager.wipeLocalSyncedEntitiesForGeneration(
      cleanup: cleanup,
      stopRemoteSession: { context, profileId in
        XCTAssertNotNil(try? BlockedProfiles.findProfile(byID: profileId, in: context))
        events.append("stop")
      },
      clearResidualEnforcement: { _ in events.append("restrictions") },
      endLiveActivity: { events.append("live-activity") })

    XCTAssertEqual(events, ["stop", "restrictions", "live-activity", "delete"])
    XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<BlockedProfiles>()).count, 0)
  }

  func testOriginWipeFailureAfterEntityDeleteDoesNotAdvanceGeneration() async throws {
    try await makeAttachedManager(namespace: "userA", isEnabled: true, engineState: .steady)
    let store = SyncEngineStore(userRecordName: "userA")
    store.establishmentGeneration = 1
    seedLocalProfiles(count: 1)
    let controller = try XCTUnwrap(manager.engineController as? SyncEngineController)
    let reset = try XCTUnwrap(controller.reset)

    try manager.resetSync(wipe: true, clearRemoteAppSelections: false)
    await reset.handleZoneDeleteConfirmed()
    manager.failNextGenerationWipeFinalSaveForTest = true

    reset.handleZoneSaveConfirmed()

    XCTAssertEqual(store.establishmentGeneration, 1, "a failed local delete commit must not bump")
    XCTAssertEqual(store.resetIntent?.stage, .recreating, "the wipe remains retryable")
    let recordDeletes = controller.driver.pendingRecordZoneChanges.filter {
      if case .deleteRecord = $0 { return true }
      return false
    }
    XCTAssertTrue(recordDeletes.isEmpty, "origin wipe deletion must stay local-only")
  }

  func testNotNowLeavesEngineOffButRePromptable() async throws {
    try await makeAttachedManager(namespace: "userA", isEnabled: true, engineState: .steady)
    manager.resolveAccountChange(availability: .available(recB), newName: "userB")
    seedLocalProfiles(count: 2)

    manager.resolveConflictNotNow()

    XCTAssertNil(manager.accountChangeConflict)
    XCTAssertEqual(manager.syncPausedReason, .accountChanged)
    XCTAssertEqual(manager.pendingConflictName, "userB")
    XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<BlockedProfiles>()).count, 2)
    XCTAssertEqual(manager.attachedUserRecordName, "userA")
    XCTAssertFalse((manager.engineController as? SyncEngineController)?.hasLiveDriver ?? true)
  }

  func testAccountResolutionRetryCancelsOnDisableBeforeFiring() async throws {
    try await makeAttachedManager(namespace: "userA", isEnabled: true, engineState: .steady)
    manager.disableAccountResolutionRetryForTest = false
    manager.accountResolutionRetryDelayNanosecondsForTest = 10_000_000

    manager.resolveAccountChange(availability: .ambiguous, newName: nil)

    XCTAssertTrue(manager.hasAccountResolutionRetryTaskForTest)

    manager.isEnabled = false

    XCTAssertFalse(manager.hasAccountResolutionRetryTaskForTest)
    try await Task.sleep(nanoseconds: 30_000_000)
    XCTAssertFalse(manager.didCallStartForTest)
  }

  func testAccountResolutionRetryCancelsOnConfirmedSameUserResolution() async throws {
    try await makeAttachedManager(namespace: "userA", isEnabled: true, engineState: .steady)
    manager.disableAccountResolutionRetryForTest = false
    manager.accountResolutionRetryDelayNanosecondsForTest = 10_000_000

    manager.resolveAccountChange(availability: .ambiguous, newName: nil)

    XCTAssertTrue(manager.hasAccountResolutionRetryTaskForTest)

    manager.resolveAccountChange(availability: .available(recA), newName: "userA")

    XCTAssertFalse(manager.hasAccountResolutionRetryTaskForTest)
    try await Task.sleep(nanoseconds: 30_000_000)
    XCTAssertFalse(manager.didCallStartForTest)
  }

  private func makeAttachedManager(
    namespace: String, isEnabled: Bool, engineState: SyncEngineState
  ) async throws {
    manager.engineController = nil
    manager.isEnabled = false
    manager.isSyncReady = false
    let driver = MockSyncEngineDriver()
    await manager.attachEngine(
      modelContext: container.mainContext,
      emergencyManager: emergencyManager,
      userRecordNameProvider: { namespace },
      driverFactory: { _ in driver })
    manager.isEnabled = isEnabled
    if isEnabled {
      await (manager.engineController as? SyncEngineController)?.startupTask?.value
    }
    (manager.engineController as? SyncEngineController)?.forceStateForTest(engineState)
    manager.resetAccountChangeDebugCountersForTest()
  }

  @discardableResult
  private func seedLocalProfiles(count: Int, now: Date = Date()) -> [BlockedProfiles] {
    let profiles = (0..<count).map {
      BlockedProfiles(name: "Focus \($0)", createdAt: now, updatedAt: now)
    }
    for profile in profiles {
      container.mainContext.insert(profile)
    }
    try? container.mainContext.save()
    return profiles
  }

  private func startActiveSession(for profile: BlockedProfiles, now: Date) -> BlockedProfileSession {
    let session = BlockedProfileSession(tag: "manual", blockedProfile: profile, startTime: now)
    container.mainContext.insert(session)
    try? container.mainContext.save()
    return session
  }
}
