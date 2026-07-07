import CloudKit
@preconcurrency import FoqosShared
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class MutationFunnelTests: XCTestCase {

  private var suiteName: String!
  private var defaults: UserDefaults!
  private let userRecordName = "phaseC-user"

  override func setUp() {
    super.setUp()
    suiteName = "MutationFunnelTests-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)!
    SharedData.configure(suite: defaults)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    defaults = nil
    suiteName = nil
    super.tearDown()
  }

  // MARK: - Helpers

  private func makeStore() -> SyncEngineStore {
    SyncEngineStore(userRecordName: userRecordName, defaults: defaults)
  }

  private var zoneID: CKRecordZone.ID {
    CKRecordZone.ID(zoneName: CloudKitConstants.syncZoneName, ownerName: CKCurrentUserDefaultName)
  }

  private func recordID(_ name: String) -> CKRecord.ID {
    CKRecord.ID(recordName: name, zoneID: zoneID)
  }

  @discardableResult
  private func insertProfile(
    in context: ModelContext,
    id: UUID,
    name: String,
    syncVersion: Int = 0
  ) throws -> BlockedProfiles {
    let profile = BlockedProfiles(id: id, name: name, syncVersion: syncVersion)
    context.insert(profile)
    try context.save()
    return profile
  }

  private func encodedSystemFields(recordName: String) -> Data {
    let record = CKRecord(recordType: SyncedProfile.recordType, recordID: recordID(recordName))
    let archiver = NSKeyedArchiver(requiringSecureCoding: true)
    record.encodeSystemFields(with: archiver)
    archiver.finishEncoding()
    return archiver.encodedData
  }

  @MainActor
  private final class ManualProfileDeleteCommitScheduler {
    private(set) var scheduledOperations: [@MainActor () -> Void] = []

    func schedule(_ operation: @escaping @MainActor () -> Void) {
      scheduledOperations.append(operation)
    }

    func runNext() {
      let operation = scheduledOperations.removeFirst()
      operation()
    }
  }

  // MARK: - S-15 / S-16: save bumps in the same write, enqueues once

  func testGivenProfile_WhenEnqueueSave_ThenBumpsVersionInSameWriteAndEnqueuesOnce() throws {
    // Given: a profile already saved by the "user" context, and the funnel on its own sync context.
    let now = Date()
    let profileId = UUID()
    let container = try TestModelContainer.create()
    let userContext = ModelContext(container)
    try insertProfile(in: userContext, id: profileId, name: "Focus", syncVersion: 3)

    let syncContext = ModelContext(container)
    let store = makeStore()
    let driver = MockSyncEngineDriver()
    let funnel = MutationFunnel(
      modelContext: syncContext,
      store: store,
      driver: driver,
      deviceId: "device-A"
    )

    // When
    try funnel.enqueueSave(profileId: profileId)

    // Then: version bumped exactly once, on the funnel's own context...
    let onSync = try XCTUnwrap(BlockedProfiles.findProfile(byID: profileId, in: syncContext))
    XCTAssertEqual(onSync.syncVersion, 4, "bump must be +1 in the same write")

    // ...and persisted (a fresh context observes the committed bump)...
    let verifyContext = ModelContext(container)
    let persisted = try XCTUnwrap(BlockedProfiles.findProfile(byID: profileId, in: verifyContext))
    XCTAssertEqual(persisted.syncVersion, 4)

    // ...and exactly one pending .saveRecord enqueued.
    XCTAssertEqual(driver.pendingRecordZoneChanges, [.saveRecord(recordID(profileId.uuidString))])
    _ = now
  }

  func testGivenEditBypassingFunnel_ThenNoBumpAndNoEnqueue() throws {
    // Given: a profile edited directly, NOT through the funnel (the locked-in regression).
    let now = Date()
    let profileId = UUID()
    let container = try TestModelContainer.create()
    let userContext = ModelContext(container)
    let profile = try insertProfile(in: userContext, id: profileId, name: "Focus", syncVersion: 3)

    let driver = MockSyncEngineDriver()

    // When: a plain field edit that bypasses MutationFunnel.
    profile.name = "Renamed"
    try userContext.save()

    // Then: no version bump and nothing enqueued — a bypassing edit cannot propagate.
    let reread = try XCTUnwrap(BlockedProfiles.findProfile(byID: profileId, in: userContext))
    XCTAssertEqual(reread.syncVersion, 3, "a bypassing edit must not bump the version")
    XCTAssertTrue(driver.pendingRecordZoneChanges.isEmpty, "a bypassing edit must not enqueue")
    _ = now
  }

  // MARK: - S-15: failed save operation does not bump or enqueue

  func testGivenMissingProfile_WhenEnqueueSave_ThenThrowsWithoutBumpOrEnqueue() throws {
    // Given: the profile does not exist on the funnel's sync context (deterministic failure surface).
    let now = Date()
    let container = try TestModelContainer.create()
    let syncContext = ModelContext(container)
    let store = makeStore()
    let driver = MockSyncEngineDriver()
    let funnel = MutationFunnel(
      modelContext: syncContext,
      store: store,
      driver: driver,
      deviceId: "device-A"
    )

    // When / Then: the operation fails and nothing is enqueued.
    XCTAssertThrowsError(try funnel.enqueueSave(profileId: UUID())) { error in
      XCTAssertEqual(error as? MutationFunnel.MutationFunnelError, .entityNotFound)
    }
    XCTAssertTrue(driver.pendingRecordZoneChanges.isEmpty)
    _ = now
  }

  // MARK: - I2 / S-14: newer-schema profiles are never enqueued for save

  func testGivenNewerSchemaProfile_WhenEnqueueSave_ThenNeverEnqueuedAndNoBump() throws {
    // Given: a profile whose schema version is newer than this app understands.
    let now = Date()
    let profileId = UUID()
    let container = try TestModelContainer.create()
    let userContext = ModelContext(container)
    let profile = try insertProfile(in: userContext, id: profileId, name: "FromFuture", syncVersion: 5)
    profile.profileSchemaVersion = BlockedProfiles.currentSchemaVersion + 1
    try userContext.save()

    let syncContext = ModelContext(container)
    let store = makeStore()
    let driver = MockSyncEngineDriver()
    let funnel = MutationFunnel(
      modelContext: syncContext,
      store: store,
      driver: driver,
      deviceId: "device-A"
    )

    // When
    try funnel.enqueueSave(profileId: profileId)

    // Then: no bump, no enqueue (I2; §5.4 refuse-to-materialize is upstream, this refuses at the source).
    let reread = try XCTUnwrap(BlockedProfiles.findProfile(byID: profileId, in: syncContext))
    XCTAssertEqual(reread.syncVersion, 5)
    XCTAssertTrue(driver.pendingRecordZoneChanges.isEmpty)
    _ = now
  }

  // MARK: - Location save: advances updatedAt, enqueues once

  func testGivenLocation_WhenEnqueueSave_ThenAdvancesUpdatedAtAndEnqueuesOnce() throws {
    // Given: a location whose updatedAt is well in the past.
    let now = Date()
    let past = now.addingTimeInterval(-3600)
    let locationId = UUID()
    let container = try TestModelContainer.create()
    let userContext = ModelContext(container)
    let location = SavedLocation(
      id: locationId,
      name: "Home",
      latitude: 1,
      longitude: 2,
      updatedAt: past
    )
    userContext.insert(location)
    try userContext.save()

    let syncContext = ModelContext(container)
    let store = makeStore()
    let driver = MockSyncEngineDriver()
    let funnel = MutationFunnel(
      modelContext: syncContext,
      store: store,
      driver: driver,
      deviceId: "device-A"
    )

    // When
    try funnel.enqueueSave(locationId: locationId)

    // Then: updatedAt advanced (design §2: locations advance updatedAt) and enqueued once.
    let reread = try XCTUnwrap(SavedLocation.find(byID: locationId, in: syncContext))
    XCTAssertGreaterThan(reread.updatedAt, past)
    XCTAssertEqual(driver.pendingRecordZoneChanges, [.saveRecord(recordID(locationId.uuidString))])
  }

  func testGivenAbsentLocation_WhenEnqueueSave_ThenThrowsWithoutEnqueue() throws {
    // Given: no location exists on the funnel's sync context (deterministic failure surface).
    let container = try TestModelContainer.create()
    let syncContext = ModelContext(container)
    let store = makeStore()
    let driver = MockSyncEngineDriver()
    let funnel = MutationFunnel(
      modelContext: syncContext,
      store: store,
      driver: driver,
      deviceId: "device-A"
    )

    // When / Then: the operation fails and nothing is enqueued.
    XCTAssertThrowsError(try funnel.enqueueSave(locationId: UUID())) { error in
      XCTAssertEqual(error as? MutationFunnel.MutationFunnelError, .entityNotFound)
    }
    XCTAssertTrue(driver.pendingRecordZoneChanges.isEmpty)
  }

  // MARK: - Emergency settings save: bumps version, enqueues the fixed-name record

  func testGivenEmergencySettings_WhenEnqueueSave_ThenBumpsVersionAndEnqueuesOnce() throws {
    let now = Date()
    let container = try TestModelContainer.create()
    let syncContext = ModelContext(container)
    let store = makeStore()
    let driver = MockSyncEngineDriver()
    let funnel = MutationFunnel(
      modelContext: syncContext,
      store: store,
      driver: driver,
      deviceId: "device-A"
    )
    let before = EmergencyUnblockManager.shared.emergencySettingsVersion

    // When
    funnel.enqueueEmergencySettingsSave()

    // Then: version bumped by one and the single fixed-name record enqueued once.
    XCTAssertEqual(EmergencyUnblockManager.shared.emergencySettingsVersion, before + 1)
    XCTAssertEqual(
      driver.pendingRecordZoneChanges,
      [.saveRecord(recordID(SyncedEmergencySettings.recordName))]
    )
    _ = now
  }

  // MARK: - S-15 / S-29: delete writes a tombstone carrying the change tag, enqueues once

  func testGivenSyncedProfile_WhenEnqueueDelete_ThenDeleteIsMarkedBeforeDeferredSaveAndEnqueuedAfterCommit()
    throws
  {
    let profileId = UUID()
    let recordName = profileId.uuidString
    let container = try TestModelContainer.create()
    let context = ModelContext(container)
    try insertProfile(in: context, id: profileId, name: "Homework", syncVersion: 2)

    let store = makeStore()
    let driver = MockSyncEngineDriver()
    let scheduler = ManualProfileDeleteCommitScheduler()
    let funnel = MutationFunnel(
      modelContext: context,
      store: store,
      driver: driver,
      deviceId: "device-A",
      scheduleProfileDeleteCommit: scheduler.schedule
    )

    try funnel.enqueueDelete(profileId: profileId)

    XCTAssertTrue(store.deleteTombstones.keys.contains(recordName), "tombstone is durable immediately")
    XCTAssertEqual(scheduler.scheduledOperations.count, 1, "save is deferred one UI turn")
    XCTAssertTrue(driver.pendingRecordZoneChanges.isEmpty, "deleteRecord is not enqueued before save")
    XCTAssertNil(
      try BlockedProfiles.findProfile(byID: profileId, in: context),
      "same context excludes the pending-deleted profile before save")

    let verifyBeforeSave = ModelContext(container)
    XCTAssertNotNil(
      try BlockedProfiles.findProfile(byID: profileId, in: verifyBeforeSave),
      "delete is not persisted until the deferred commit runs")

    scheduler.runNext()

    let verifyAfterSave = ModelContext(container)
    XCTAssertNil(try BlockedProfiles.findProfile(byID: profileId, in: verifyAfterSave))
    XCTAssertEqual(driver.pendingRecordZoneChanges, [.deleteRecord(recordID(recordName))])
  }

  func testGivenDeleteScheduledButCommitNotRun_WhenStoreReloads_ThenTombstoneSurvivesAndEntityStillExists()
    throws
  {
    let profileId = UUID()
    let recordName = profileId.uuidString
    let container = try TestModelContainer.create()
    let context = ModelContext(container)
    try insertProfile(in: context, id: profileId, name: "Homework", syncVersion: 2)

    let store = makeStore()
    let driver = MockSyncEngineDriver()
    let scheduler = ManualProfileDeleteCommitScheduler()
    let funnel = MutationFunnel(
      modelContext: context,
      store: store,
      driver: driver,
      deviceId: "device-A",
      scheduleProfileDeleteCommit: scheduler.schedule
    )

    try funnel.enqueueDelete(profileId: profileId)

    let reloadedStore = makeStore()
    XCTAssertTrue(
      reloadedStore.deleteTombstones.keys.contains(recordName),
      "the tombstone is durable before the deferred save runs")

    let verifyContext = ModelContext(container)
    XCTAssertNotNil(
      try BlockedProfiles.findProfile(byID: profileId, in: verifyContext),
      "a process death before deferred save leaves the profile present")
    XCTAssertTrue(driver.pendingRecordZoneChanges.isEmpty)
  }

  func testGivenSyncedProfile_WhenEnqueueDelete_ThenWritesTombstoneWithTagAndEnqueuesOnce() throws {
    // Given: a synced profile whose last-known server system-fields are cached in the store.
    let now = Date()
    let profileId = UUID()
    let recordName = profileId.uuidString
    let container = try TestModelContainer.create()
    let userContext = ModelContext(container)
    try insertProfile(in: userContext, id: profileId, name: "Focus", syncVersion: 2)

    let store = makeStore()
    let systemFields = encodedSystemFields(recordName: recordName)
    store.setSystemFields(systemFields, for: recordName)

    let syncContext = ModelContext(container)
    let driver = MockSyncEngineDriver()
    let scheduler = ManualProfileDeleteCommitScheduler()
    let funnel = MutationFunnel(
      modelContext: syncContext,
      store: store,
      driver: driver,
      deviceId: "device-A",
      scheduleProfileDeleteCommit: scheduler.schedule
    )

    // When
    try funnel.enqueueDelete(profileId: profileId)

    // Then: the entity is marked deleted on the funnel context...
    XCTAssertNil(try BlockedProfiles.findProfile(byID: profileId, in: syncContext))

    // ...a tombstone exists carrying exactly the change tag derived from the cached system fields...
    XCTAssertTrue(store.deleteTombstones.keys.contains(recordName), "tombstone must be written")
    XCTAssertEqual(
      store.deleteTombstones[recordName] ?? nil,
      MutationFunnel.changeTag(fromSystemFields: systemFields),
      "tombstone tag must come from the record's cached systemFields (I12)"
    )

    scheduler.runNext()

    let verifyAfterCommit = ModelContext(container)
    XCTAssertNil(try BlockedProfiles.findProfile(byID: profileId, in: verifyAfterCommit))

    // ...and exactly one pending .deleteRecord was enqueued.
    XCTAssertEqual(driver.pendingRecordZoneChanges, [.deleteRecord(recordID(recordName))])
    _ = now
  }

  // MARK: - S-15 / S-29: delete of a never-synced profile writes a nil-tag tombstone

  func testGivenNeverSyncedProfile_WhenEnqueueDelete_ThenWritesNilTagTombstoneAndEnqueuesOnce()
    throws
  {
    // Given: a profile with no cached systemFields (never synced to the server yet).
    let now = Date()
    let profileId = UUID()
    let recordName = profileId.uuidString
    let container = try TestModelContainer.create()
    let userContext = ModelContext(container)
    try insertProfile(in: userContext, id: profileId, name: "NeverSynced", syncVersion: 0)

    let store = makeStore()
    let syncContext = ModelContext(container)
    let driver = MockSyncEngineDriver()
    let scheduler = ManualProfileDeleteCommitScheduler()
    let funnel = MutationFunnel(
      modelContext: syncContext,
      store: store,
      driver: driver,
      deviceId: "device-A",
      scheduleProfileDeleteCommit: scheduler.schedule
    )

    // When
    try funnel.enqueueDelete(profileId: profileId)

    // Then: the entity is gone...
    XCTAssertNil(try BlockedProfiles.findProfile(byID: profileId, in: syncContext))

    // ...a tombstone exists with a nil change tag (never synced, no systemFields to derive one from)...
    XCTAssertTrue(store.deleteTombstones.keys.contains(recordName), "tombstone must be written")
    XCTAssertNil(
      store.deleteTombstones[recordName] ?? nil,
      "a never-synced record has no change tag"
    )

    scheduler.runNext()

    // ...and exactly one pending .deleteRecord was enqueued.
    XCTAssertEqual(driver.pendingRecordZoneChanges, [.deleteRecord(recordID(recordName))])
    _ = now
  }

  // MARK: - S-15: failed entity delete removes the tombstone before returning and enqueues nothing

  func testGivenFailedProfileDelete_WhenEnqueueDelete_ThenTombstoneRemovedRollbackAndNothingEnqueued()
    throws
  {
    // Given: a store already holding cached system fields for a recordName whose entity is ABSENT
    // on the sync context (deterministic delete-failure surface).
    let now = Date()
    let profileId = UUID()
    let recordName = profileId.uuidString
    let container = try TestModelContainer.create()
    let syncContext = ModelContext(container)

    let store = makeStore()
    store.setSystemFields(encodedSystemFields(recordName: recordName), for: recordName)

    let driver = MockSyncEngineDriver()
    let funnel = MutationFunnel(
      modelContext: syncContext,
      store: store,
      driver: driver,
      deviceId: "device-A"
    )

    // When / Then: the delete fails...
    XCTAssertThrowsError(try funnel.enqueueDelete(profileId: profileId)) { error in
      XCTAssertEqual(error as? MutationFunnel.MutationFunnelError, .entityNotFound)
    }

    // ...the tombstone written before the delete has been removed before returning...
    XCTAssertFalse(
      store.deleteTombstones.keys.contains(recordName),
      "a failed delete must not leave a lingering tombstone"
    )
    // ...(and it does not survive into a freshly-loaded store either)...
    let reloaded = makeStore()
    XCTAssertFalse(reloaded.deleteTombstones.keys.contains(recordName))

    // ...and nothing was enqueued.
    XCTAssertTrue(driver.pendingRecordZoneChanges.isEmpty)
    _ = now
  }

  // MARK: - S-29: never-synced entity ⇒ tombstone tag nil

  func testGivenNeverSyncedProfile_WhenEnqueueDelete_ThenTombstoneTagIsNil() throws {
    // Given: a profile with NO cached system fields (never synced).
    let now = Date()
    let profileId = UUID()
    let recordName = profileId.uuidString
    let container = try TestModelContainer.create()
    let userContext = ModelContext(container)
    try insertProfile(in: userContext, id: profileId, name: "Fresh", syncVersion: 0)

    let store = makeStore()
    XCTAssertNil(store.systemFields(for: recordName))

    let syncContext = ModelContext(container)
    let driver = MockSyncEngineDriver()
    let scheduler = ManualProfileDeleteCommitScheduler()
    let funnel = MutationFunnel(
      modelContext: syncContext,
      store: store,
      driver: driver,
      deviceId: "device-A",
      scheduleProfileDeleteCommit: scheduler.schedule
    )

    // When
    try funnel.enqueueDelete(profileId: profileId)

    // Then: tombstone written with a nil change tag, delete enqueued once.
    XCTAssertTrue(store.deleteTombstones.keys.contains(recordName))
    XCTAssertNil(store.deleteTombstones[recordName] ?? nil, "never-synced ⇒ tombstone tag is nil (I12)")
    scheduler.runNext()
    XCTAssertEqual(driver.pendingRecordZoneChanges, [.deleteRecord(recordID(recordName))])
    _ = now
  }

  // MARK: - #267 final-review: list-view swipe-delete, single shared ModelContext

  /// Regression guard for the list-view swipe-to-delete funnel reroute. Unlike the tests above
  /// (which use a separate `syncContext` instance), this mirrors production wiring exactly — the
  /// funnel's `modelContext` is the SAME instance the caller mutates on (both are
  /// `container.mainContext`, per `FoqosApp.attachEngine`).
  ///
  /// Calling `BlockedProfiles.deleteProfile(_, in:)` (which defers its `context.save()`) and THEN
  /// `funnel.enqueueDelete(profileId:)` on that same, single context throws `entityNotFound`: a
  /// pending (unsaved) `context.delete()` IS excluded from a subsequent `context.fetch()` on the
  /// SAME context instance, so the funnel's own re-find-by-id sees nothing, clears the tombstone,
  /// and rolls back — silently undoing the caller's own delete too. Proven by
  /// `testGivenPreDeletedThenEnqueueOnSharedContext_ThenThrowsEntityNotFound` below. So on a
  /// single shared context, the funnel alone must own the delete: the caller must NOT pre-delete.
  func testGivenSyncedProfile_WhenEnqueueDeleteAloneOnSharedContext_ThenDeletesTombstonesAndEnqueues()
    throws
  {
    let profileId = UUID()
    let recordName = profileId.uuidString
    let container = try TestModelContainer.create()
    let context = ModelContext(container)
    try insertProfile(in: context, id: profileId, name: "Homework", syncVersion: 2)

    let store = makeStore()
    let driver = MockSyncEngineDriver()
    let scheduler = ManualProfileDeleteCommitScheduler()
    let funnel = MutationFunnel(
      modelContext: context,
      store: store,
      driver: driver,
      deviceId: "device-A",
      scheduleProfileDeleteCommit: scheduler.schedule
    )

    // When: the funnel alone performs the delete on the shared context — no caller pre-delete.
    try funnel.enqueueDelete(profileId: profileId)

    // Then: the entity is marked deleted on the shared context...
    XCTAssertNil(try BlockedProfiles.findProfile(byID: profileId, in: context))

    // ...a tombstone was written...
    XCTAssertTrue(store.deleteTombstones.keys.contains(recordName), "tombstone must be written")

    scheduler.runNext()

    let verifyAfterCommit = ModelContext(container)
    XCTAssertNil(try BlockedProfiles.findProfile(byID: profileId, in: verifyAfterCommit))

    // ...and exactly one pending .deleteRecord was enqueued.
    XCTAssertEqual(driver.pendingRecordZoneChanges, [.deleteRecord(recordID(recordName))])
  }

  /// Documents the failure mode a caller MUST avoid on a shared context: pre-deleting (deferred
  /// save) before calling the funnel throws `entityNotFound`, because SwiftData excludes a
  /// pending, unsaved `context.delete()` from a subsequent fetch on that SAME context instance.
  func testGivenPreDeletedThenEnqueueOnSharedContext_ThenThrowsEntityNotFound() throws {
    let profileId = UUID()
    let container = try TestModelContainer.create()
    let context = ModelContext(container)
    let profile = try insertProfile(in: context, id: profileId, name: "Homework", syncVersion: 2)

    let store = makeStore()
    let driver = MockSyncEngineDriver()
    let scheduler = ManualProfileDeleteCommitScheduler()
    let funnel = MutationFunnel(
      modelContext: context,
      store: store,
      driver: driver,
      deviceId: "device-A",
      scheduleProfileDeleteCommit: scheduler.schedule
    )

    try BlockedProfiles.deleteProfile(profile, in: context)

    XCTAssertThrowsError(try funnel.enqueueDelete(profileId: profileId)) { error in
      XCTAssertEqual(error as? MutationFunnel.MutationFunnelError, .entityNotFound)
    }
    // The rollback also undoes the caller's own pending delete — nothing was persisted.
    let verifyContext = ModelContext(container)
    XCTAssertNotNil(
      try BlockedProfiles.findProfile(byID: profileId, in: verifyContext),
      "rollback undoes the caller's pre-delete too — this ordering must never be used")
  }

  // MARK: - S-29: kill before the enqueue is captured leaves a durable tombstone for recovery

  func testGivenProfileDelete_WhenReloadingStore_ThenTombstoneSurvivesForRecovery() throws {
    // Given a completed funnel delete, the tombstone is a crash-durable intent carrier: even if the
    // engine state (driver pending queue) is never persisted, a freshly-loaded store still sees the
    // tombstone, from which controller-start I12 recovery re-enqueues the delete.
    let now = Date()
    let profileId = UUID()
    let recordName = profileId.uuidString
    let container = try TestModelContainer.create()
    let userContext = ModelContext(container)
    try insertProfile(in: userContext, id: profileId, name: "Focus", syncVersion: 4)

    let store = makeStore()
    let syncContext = ModelContext(container)
    let funnel = MutationFunnel(
      modelContext: syncContext,
      store: store,
      driver: MockSyncEngineDriver(),
      deviceId: "device-A"
    )

    // When: the delete completes, then we simulate a kill by discarding the driver and reloading
    // the store from the same persistence.
    try funnel.enqueueDelete(profileId: profileId)
    let reloaded = makeStore()

    // Then: the tombstone survives for recovery.
    XCTAssertTrue(
      reloaded.deleteTombstones.keys.contains(recordName),
      "tombstone must survive process death so I12 recovery can re-enqueue the delete"
    )
    _ = now
  }

  // MARK: - Location delete: tombstone + enqueue once

  func testGivenLocation_WhenEnqueueDelete_ThenWritesTombstoneAndEnqueuesOnce() throws {
    let now = Date()
    let locationId = UUID()
    let recordName = locationId.uuidString
    let container = try TestModelContainer.create()
    let userContext = ModelContext(container)
    let location = SavedLocation(id: locationId, name: "Home", latitude: 1, longitude: 2)
    userContext.insert(location)
    try userContext.save()

    let store = makeStore()
    let syncContext = ModelContext(container)
    let driver = MockSyncEngineDriver()
    let funnel = MutationFunnel(
      modelContext: syncContext,
      store: store,
      driver: driver,
      deviceId: "device-A"
    )

    // When
    try funnel.enqueueDelete(locationId: locationId)

    // Then: entity gone, tombstone written, exactly one .deleteRecord enqueued.
    XCTAssertNil(try SavedLocation.find(byID: locationId, in: syncContext))
    XCTAssertTrue(store.deleteTombstones.keys.contains(recordName))
    XCTAssertEqual(driver.pendingRecordZoneChanges, [.deleteRecord(recordID(recordName))])
    _ = now
  }

  // MARK: - Location delete failure: tombstone removed, rollback, nothing enqueued

  func testGivenAbsentLocation_WhenEnqueueDelete_ThenTombstoneRemovedRollbackAndNothingEnqueued()
    throws
  {
    // Given: a store already holding cached system fields for a recordName whose entity is ABSENT
    // on the sync context (deterministic delete-failure surface).
    let now = Date()
    let locationId = UUID()
    let recordName = locationId.uuidString
    let container = try TestModelContainer.create()
    let syncContext = ModelContext(container)

    let store = makeStore()
    store.setSystemFields(encodedSystemFields(recordName: recordName), for: recordName)

    let driver = MockSyncEngineDriver()
    let funnel = MutationFunnel(
      modelContext: syncContext,
      store: store,
      driver: driver,
      deviceId: "device-A"
    )

    // When / Then: the delete fails...
    XCTAssertThrowsError(try funnel.enqueueDelete(locationId: locationId)) { error in
      XCTAssertEqual(error as? MutationFunnel.MutationFunnelError, .entityNotFound)
    }

    // ...the tombstone written before the delete has been removed before returning...
    XCTAssertFalse(
      store.deleteTombstones.keys.contains(recordName),
      "a failed delete must not leave a lingering tombstone"
    )
    // ...(and it does not survive into a freshly-loaded store either)...
    let reloaded = makeStore()
    XCTAssertFalse(reloaded.deleteTombstones.keys.contains(recordName))

    // ...and nothing was enqueued.
    XCTAssertTrue(driver.pendingRecordZoneChanges.isEmpty)
    _ = now
  }

  // MARK: - #267 final-review: profile-editor delete + location delete, single shared ModelContext

  /// Regression guard for the `BlockedProfileView` delete-confirmation reroute (mirrors the
  /// list-view swipe-delete guard above). Same production wiring: the funnel's `modelContext`
  /// is the SAME instance the view mutates on (`container.mainContext`), so the funnel alone
  /// must own the delete — the caller must NOT pre-delete first.
  func testGivenSyncedProfile_WhenEditorEnqueueDeleteAloneOnSharedContext_ThenDeletesTombstonesAndEnqueues()
    throws
  {
    let profileId = UUID()
    let recordName = profileId.uuidString
    let container = try TestModelContainer.create()
    let context = ModelContext(container)
    try insertProfile(in: context, id: profileId, name: "Bedtime", syncVersion: 1)

    let store = makeStore()
    let driver = MockSyncEngineDriver()
    let scheduler = ManualProfileDeleteCommitScheduler()
    let funnel = MutationFunnel(
      modelContext: context,
      store: store,
      driver: driver,
      deviceId: "device-A",
      scheduleProfileDeleteCommit: scheduler.schedule
    )

    // When: the funnel alone performs the delete on the shared context — no caller pre-delete.
    try funnel.enqueueDelete(profileId: profileId)

    // Then: the entity is marked deleted on the shared context...
    XCTAssertNil(try BlockedProfiles.findProfile(byID: profileId, in: context))

    // ...a tombstone was written...
    XCTAssertTrue(store.deleteTombstones.keys.contains(recordName), "tombstone must be written")

    scheduler.runNext()

    let verifyAfterCommit = ModelContext(container)
    XCTAssertNil(try BlockedProfiles.findProfile(byID: profileId, in: verifyAfterCommit))

    // ...and exactly one pending .deleteRecord was enqueued.
    XCTAssertEqual(driver.pendingRecordZoneChanges, [.deleteRecord(recordID(recordName))])
  }

  /// Regression guard for the `SavedLocationsView` delete reroute: on a shared context, a
  /// pre-delete (deferred save via `SavedLocation.delete(_:in:)`) before calling the funnel
  /// throws `entityNotFound`, silently swallowing the tombstone and undoing the caller's own
  /// delete — proving the view must let the funnel alone own the delete when sync is enabled.
  func testGivenSyncedLocation_WhenEnqueueDeleteAloneOnSharedContext_ThenDeletesTombstonesAndEnqueues()
    throws
  {
    let locationId = UUID()
    let recordName = locationId.uuidString
    let container = try TestModelContainer.create()
    let context = ModelContext(container)
    let location = SavedLocation(id: locationId, name: "School", latitude: 3, longitude: 4)
    context.insert(location)
    try context.save()

    let store = makeStore()
    let driver = MockSyncEngineDriver()
    let funnel = MutationFunnel(
      modelContext: context,
      store: store,
      driver: driver,
      deviceId: "device-A"
    )

    // When: the funnel alone performs the delete on the shared context — no caller pre-delete.
    try funnel.enqueueDelete(locationId: locationId)

    // Then: the entity is actually gone (locally and persisted)...
    XCTAssertNil(try SavedLocation.find(byID: locationId, in: context))
    let verifyContext = ModelContext(container)
    XCTAssertNil(try SavedLocation.find(byID: locationId, in: verifyContext))

    // ...a tombstone was written...
    XCTAssertTrue(store.deleteTombstones.keys.contains(recordName), "tombstone must be written")

    // ...and exactly one pending .deleteRecord was enqueued.
    XCTAssertEqual(driver.pendingRecordZoneChanges, [.deleteRecord(recordID(recordName))])
  }

  /// Documents the failure mode the `SavedLocationsView` fix avoids: pre-deleting the location
  /// (via `SavedLocation.delete(_:in:)`, whose `context.save()` commits immediately) before
  /// calling the funnel throws `entityNotFound`, because the funnel's own re-find-by-id on that
  /// SAME context instance sees nothing — proving the old pre-delete-then-enqueue ordering never
  /// propagates the delete.
  func testGivenPreDeletedLocationThenEnqueueOnSharedContext_ThenThrowsEntityNotFound() throws {
    let locationId = UUID()
    let container = try TestModelContainer.create()
    let context = ModelContext(container)
    let location = SavedLocation(id: locationId, name: "School", latitude: 3, longitude: 4)
    context.insert(location)
    try context.save()

    let store = makeStore()
    let driver = MockSyncEngineDriver()
    let funnel = MutationFunnel(
      modelContext: context,
      store: store,
      driver: driver,
      deviceId: "device-A"
    )

    try SavedLocation.delete(location, in: context)

    XCTAssertThrowsError(try funnel.enqueueDelete(locationId: locationId)) { error in
      XCTAssertEqual(error as? MutationFunnel.MutationFunnelError, .entityNotFound)
    }
    // Nothing enqueued — the old view ordering silently swallowed the delete instead of
    // propagating it.
    XCTAssertTrue(driver.pendingRecordZoneChanges.isEmpty)
  }

  // MARK: - change-tag extraction is crash-safe on nil / garbage input

  func testChangeTagFromSystemFields_HandlesNilAndGarbage() {
    XCTAssertNil(MutationFunnel.changeTag(fromSystemFields: nil))
    XCTAssertNil(MutationFunnel.changeTag(fromSystemFields: Data([0x00, 0x01, 0x02])))
  }
}
