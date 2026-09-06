import CloudKit
import FoqosShared
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class SyncApplyServiceTests: XCTestCase {
  private var container: ModelContainer!
  private var context: ModelContext!
  private var store: SyncEngineStore!
  private var sessionController: MockSessionController!
  private var emergencyManager: EmergencyUnblockManager!
  private var suiteName: String!
  private var storeSuiteName: String!
  private var emergencySuiteName: String!
  private var storeDefaults: UserDefaults!
  private var emergencyDefaults: UserDefaults!
  private let deviceId = "device-A"
  private let zoneID = CKRecordZone.ID(
    zoneName: CloudKitConstants.syncZoneName, ownerName: CKCurrentUserDefaultName)

  override func setUp() async throws {
    try await super.setUp()
    suiteName = "SyncApplyServiceTests-\(UUID().uuidString)"
    SharedData.configure(suite: UserDefaults(suiteName: suiteName)!)
    storeSuiteName = "SyncApplyServiceTests-store-\(UUID().uuidString)"
    emergencySuiteName = "SyncApplyServiceTests-emg-\(UUID().uuidString)"
    storeDefaults = UserDefaults(suiteName: storeSuiteName)!
    emergencyDefaults = UserDefaults(suiteName: emergencySuiteName)!
    store = SyncEngineStore(userRecordName: "user-1", defaults: storeDefaults)
    container = try TestModelContainer.create()
    context = container.mainContext
    sessionController = MockSessionController()
    emergencyManager = EmergencyUnblockManager(defaults: emergencyDefaults)
    SyncConflictManager.shared.clearAll()
  }

  override func tearDown() async throws {
    SyncConflictManager.shared.clearAll()
    UserDefaults().removePersistentDomain(forName: suiteName)
    UserDefaults().removePersistentDomain(forName: storeSuiteName)
    UserDefaults().removePersistentDomain(forName: emergencySuiteName)
    for key in [
      "family_foqos_emergency_unblocks_remaining",
      "family_foqos_emergency_unblocks_reset_period_in_days",
      "family_foqos_last_emergency_unblocks_reset_date",
      "family_foqos_emergency_settings_locked",
      "family_foqos_emergency_settings_version",
    ] {
      UserDefaults.standard.removeObject(forKey: key)
    }
    try await super.tearDown()
  }

  private func makeService() -> SyncApplyService {
    SyncApplyService(
      modelContext: context, store: store, sessionController: sessionController,
      emergencyManager: emergencyManager, deviceId: deviceId)
  }

  private func makeService(
    scheduleProfileDeleteCommit: @escaping (@escaping @MainActor () -> Void) -> Void
  ) -> SyncApplyService {
    SyncApplyService(
      modelContext: context, store: store, sessionController: sessionController,
      emergencyManager: emergencyManager, deviceId: deviceId,
      scheduleProfileDeleteCommit: scheduleProfileDeleteCommit)
  }

  private func makeProfileRecord(
    id: UUID, name: String, version: Int, originDeviceId: String, schemaVersion: Int? = nil,
    now: Date
  ) -> CKRecord {
    let source = BlockedProfiles(id: id, name: name, syncVersion: version)
    if let schemaVersion { source.profileSchemaVersion = schemaVersion }
    var synced = SyncedProfile(from: source, originDeviceId: originDeviceId)
    synced.createdAt = now
    synced.updatedAt = now
    synced.version = version
    if let schemaVersion { synced.profileSchemaVersion = schemaVersion }
    return synced.toCKRecord(in: zoneID)
  }

  private let noPendingDelete: (String) -> Bool = { _ in false }

  // MARK: - S-27 (normal apply) / E-1

  func testGivenDeadWorldProfileAfterWipe_WhenApplied_ThenSkippedDeadWorld() throws {
    let now = Date()
    let id = UUID()
    store.establishmentGeneration = 1
    let record = makeProfileRecord(
      id: id, name: "Old", version: 1, originDeviceId: "device-B", now: now)
    record[SyncedProfile.FieldKey.generation.rawValue] = 0

    let outcome = makeService().applyFetchedModification(
      record, isPendingDeleteOrTombstoned: noPendingDelete)

    XCTAssertEqual(outcome, .skippedDeadWorld)
    XCTAssertNil(try BlockedProfiles.findProfile(byID: id, in: context))
  }

  func testGivenEqualGenerationProfile_WhenApplied_ThenMaterializes() throws {
    let now = Date()
    let id = UUID()
    store.establishmentGeneration = 1
    let record = makeProfileRecord(
      id: id, name: "Current", version: 1, originDeviceId: "device-B", now: now)
    record[SyncedProfile.FieldKey.generation.rawValue] = 1

    let outcome = makeService().applyFetchedModification(
      record, isPendingDeleteOrTombstoned: noPendingDelete)

    XCTAssertEqual(outcome, .applied)
    XCTAssertEqual(try BlockedProfiles.findProfile(byID: id, in: context)?.name, "Current")
  }

  func testGivenNewerGenerationProfile_WhenApplied_ThenSkippedForAdoptionRefetch() throws {
    let now = Date()
    let id = UUID()
    store.establishmentGeneration = 1
    let record = makeProfileRecord(
      id: id, name: "Future", version: 1, originDeviceId: "device-B", now: now)
    record[SyncedProfile.FieldKey.generation.rawValue] = 2

    let outcome = makeService().applyFetchedModification(
      record, isPendingDeleteOrTombstoned: noPendingDelete)

    XCTAssertEqual(outcome, .skippedNewerGeneration)
    XCTAssertNil(try BlockedProfiles.findProfile(byID: id, in: context))
  }

  func testGivenGenerationlessProfileAfterWipe_WhenApplied_ThenSkippedDeadWorld() throws {
    let now = Date()
    let id = UUID()
    store.establishmentGeneration = 1
    let record = makeProfileRecord(
      id: id, name: "V1", version: 1, originDeviceId: "device-B", now: now)
    record[SyncedProfile.FieldKey.generation.rawValue] = nil

    let outcome = makeService().applyFetchedModification(
      record, isPendingDeleteOrTombstoned: noPendingDelete)

    XCTAssertEqual(outcome, .skippedDeadWorld)
    XCTAssertNil(try BlockedProfiles.findProfile(byID: id, in: context))
  }

  func testGivenPreWipeGenerationZeroProfile_WhenApplied_ThenMaterializes() throws {
    let now = Date()
    let id = UUID()
    let record = makeProfileRecord(
      id: id, name: "PreWipe", version: 1, originDeviceId: "device-B", now: now)
    record[SyncedProfile.FieldKey.generation.rawValue] = nil

    let outcome = makeService().applyFetchedModification(
      record, isPendingDeleteOrTombstoned: noPendingDelete)

    XCTAssertEqual(outcome, .applied)
    XCTAssertEqual(try BlockedProfiles.findProfile(byID: id, in: context)?.name, "PreWipe")
  }

  func testGivenDeadWorldEmergencyEpoch_WhenApplied_ThenSkippedAndLedgerNotMerged() {
    store.establishmentGeneration = 1
    let record = SyncedEmergencyEpoch(epoch: 5, generation: 0).toCKRecord(in: zoneID)

    let outcome = makeService().applyFetchedModification(
      record, isPendingDeleteOrTombstoned: noPendingDelete)

    XCTAssertEqual(outcome, .skippedDeadWorld)
    XCTAssertEqual(emergencyManager.currentResetEpoch, 0)
  }

  func testGivenEmergencySettingsAfterWipe_WhenApplied_ThenPassesUngated() {
    let now = Date()
    store.establishmentGeneration = 1
    let settings = SyncedEmergencySettings(
      unblocksRemaining: 2, resetPeriodInDays: 14, lastResetDate: now,
      settingsLocked: true, version: 1, lastModified: now, originDeviceId: "device-B")

    let outcome = makeService().applyFetchedModification(
      settings.toCKRecord(in: zoneID), isPendingDeleteOrTombstoned: noPendingDelete)

    XCTAssertEqual(outcome, .applied)
    XCTAssertNotEqual(outcome, .skippedDeadWorld)
  }

  func testGivenAbsentProfile_WhenModificationApplied_ThenCreatedWithNeedsAppSelection() throws {
    let now = Date()
    let id = UUID()
    let record = makeProfileRecord(
      id: id, name: "Focus", version: 4, originDeviceId: "device-B", now: now)
    let service = makeService()

    let outcome = service.applyFetchedModification(record, isPendingDeleteOrTombstoned: noPendingDelete)

    XCTAssertEqual(outcome, .applied)
    let created = try BlockedProfiles.findProfile(byID: id, in: context)
    XCTAssertNotNil(created)
    XCTAssertEqual(created?.name, "Focus")
    XCTAssertEqual(created?.syncVersion, 4, "version applied verbatim (I2)")
    XCTAssertTrue(created?.needsAppSelection ?? false, "E-1: remote-created profile needs app selection")
    XCTAssertTrue(service.pendingReenqueues.isEmpty, "S-27: a plain apply enqueues nothing")
    XCTAssertNotNil(store.systemFields(for: id.uuidString), "systemFields stored after durable apply")
  }

  func testGivenConfirmedProfileDelete_WhenStaleEchoFetched_ThenProfileNotRecreated() throws {
    let now = Date()
    let id = UUID()
    store.setDeleteWatermark(recordName: id.uuidString, value: 3)
    let record = makeProfileRecord(
      id: id, name: "Stale", version: 3, originDeviceId: "device-B", now: now)

    let outcome = makeService().applyFetchedModification(
      record, isPendingDeleteOrTombstoned: noPendingDelete)

    XCTAssertEqual(outcome, .skippedStaleDelete)
    XCTAssertNil(
      try BlockedProfiles.findProfile(byID: id, in: context),
      "#315: a stale <=-version echo must not recreate the deleted profile")
    XCTAssertEqual(store.deleteWatermark(for: id.uuidString), 3)
  }

  func testGivenConfirmedProfileDelete_WhenHigherVersionRecreationFetched_ThenProfileCreated() throws {
    let now = Date()
    let id = UUID()
    store.setDeleteWatermark(recordName: id.uuidString, value: 3)
    let record = makeProfileRecord(
      id: id, name: "Recreated", version: 4, originDeviceId: "device-B", now: now)

    let outcome = makeService().applyFetchedModification(
      record, isPendingDeleteOrTombstoned: noPendingDelete)

    XCTAssertEqual(outcome, .applied)
    XCTAssertEqual(try BlockedProfiles.findProfile(byID: id, in: context)?.name, "Recreated")
    XCTAssertNil(
      store.deleteWatermark(for: id.uuidString),
      "higher-version recreation supersedes the delete watermark")
  }

  // MARK: - S-18 / I9

  func testGivenSchemaVersions_WhenProfileModificationApplied_ThenI9GatePreserved() throws {
    let now = Date()

    // (a) older incoming schema ⇒ reject data + conflict + auto-heal (bump + re-enqueue).
    let idOlder = UUID()
    let localOlder = BlockedProfiles(id: idOlder, name: "Local", syncVersion: 2)
    localOlder.profileSchemaVersion = 2
    context.insert(localOlder)
    try context.save()
    let olderIncoming = makeProfileRecord(
      id: idOlder, name: "FromOldApp", version: 9, originDeviceId: "device-B",
      schemaVersion: 1, now: now)
    let service = makeService()
    XCTAssertEqual(
      service.applyFetchedModification(olderIncoming, isPendingDeleteOrTombstoned: noPendingDelete),
      .applied)
    let afterOlder = try BlockedProfiles.findProfile(byID: idOlder, in: context)
    XCTAssertEqual(afterOlder?.name, "Local", "older-schema data is rejected, not applied")
    XCTAssertEqual(afterOlder?.syncVersion, 3, "auto-heal bumps syncVersion")
    XCTAssertTrue(service.pendingReenqueues.contains(olderIncoming.recordID), "auto-heal re-enqueues")
    XCTAssertNotNil(SyncConflictManager.shared.conflictedProfiles[idOlder])

    // (b) newer incoming schema than this app ⇒ reject data, mark read-only, no auto-heal.
    let idNewer = UUID()
    let localNewer = BlockedProfiles(id: idNewer, name: "Local2", syncVersion: 1)
    localNewer.profileSchemaVersion = 2
    context.insert(localNewer)
    try context.save()
    let newerIncoming = makeProfileRecord(
      id: idNewer, name: "FromNewApp", version: 7, originDeviceId: "device-B",
      schemaVersion: BlockedProfiles.currentSchemaVersion + 1, now: now)
    let service2 = makeService()
    XCTAssertEqual(
      service2.applyFetchedModification(newerIncoming, isPendingDeleteOrTombstoned: noPendingDelete),
      .applied)
    let afterNewer = try BlockedProfiles.findProfile(byID: idNewer, in: context)
    XCTAssertEqual(afterNewer?.name, "Local2", "newer-schema data is rejected")
    XCTAssertEqual(afterNewer?.profileSchemaVersion, BlockedProfiles.currentSchemaVersion + 1)
    XCTAssertEqual(afterNewer?.syncVersion, 7, "syncVersion advanced to stop re-processing")
    XCTAssertTrue(service2.pendingReenqueues.isEmpty, "newer device is authoritative — no auto-heal")
    XCTAssertNotNil(SyncConflictManager.shared.newerVersionProfiles[idNewer])

    // (c) same schema, newer version ⇒ apply.
    let idApply = UUID()
    let localApply = BlockedProfiles(id: idApply, name: "Old", syncVersion: 1)
    localApply.profileSchemaVersion = 2
    context.insert(localApply)
    try context.save()
    let applyIncoming = makeProfileRecord(
      id: idApply, name: "New", version: 5, originDeviceId: "device-B", schemaVersion: 2, now: now)
    let service3 = makeService()
    XCTAssertEqual(
      service3.applyFetchedModification(applyIncoming, isPendingDeleteOrTombstoned: noPendingDelete),
      .applied)
    XCTAssertEqual(try BlockedProfiles.findProfile(byID: idApply, in: context)?.name, "New")
  }

  // MARK: - S-27 (equal-version divergence)

  func testGivenEqualVersion_WhenProfileModificationApplied_ThenDivergenceBumpsAndEqualIsNoOp() throws {
    let now = Date()
    let id = UUID()
    let local = BlockedProfiles(id: id, name: "Focus", syncVersion: 5)
    local.profileSchemaVersion = 2
    local.createdAt = now
    local.updatedAt = now
    context.insert(local)
    try context.save()

    // Payload-equal echo at the same version ⇒ pure no-op.
    var equalSynced = SyncedProfile(from: local, originDeviceId: "device-B")
    equalSynced.version = 5
    let equalOutcome = makeService().applyFetchedModification(
      equalSynced.toCKRecord(in: zoneID), isPendingDeleteOrTombstoned: noPendingDelete)
    XCTAssertEqual(equalOutcome, .applied)
    XCTAssertEqual(try BlockedProfiles.findProfile(byID: id, in: context)?.syncVersion, 5, "no-op")

    // Payload-differing at the same version ⇒ bump + re-enqueue + conflict.
    var divergent = SyncedProfile(from: local, originDeviceId: "device-B")
    divergent.name = "Changed"
    divergent.version = 5
    let service = makeService()
    let record = divergent.toCKRecord(in: zoneID)
    let divergeOutcome = service.applyFetchedModification(
      record, isPendingDeleteOrTombstoned: noPendingDelete)
    XCTAssertEqual(divergeOutcome, .applied)
    let after = try BlockedProfiles.findProfile(byID: id, in: context)
    XCTAssertEqual(after?.name, "Focus", "local wins — incoming payload not applied")
    XCTAssertEqual(after?.syncVersion, 6, "conflict bump")
    XCTAssertTrue(service.pendingReenqueues.contains(record.recordID))
    XCTAssertTrue(SyncConflictManager.shared.shouldShowDivergenceBanner)
    XCTAssertNotNil(SyncConflictManager.shared.divergenceProfiles[id])
  }

  // MARK: - S-31

  func testGivenOwnOriginRecord_WhenApplied_ThenNewerHealsForwardAndEqualEchoNoOp() throws {
    let now = Date()
    let id = UUID()
    let local = BlockedProfiles(id: id, name: "Local", syncVersion: 2)
    local.profileSchemaVersion = 2
    context.insert(local)
    try context.save()

    // Own-origin (originDeviceId == self) newer version ⇒ applied (restore-from-backup heals).
    let ownNewer = makeProfileRecord(
      id: id, name: "Healed", version: 6, originDeviceId: deviceId, schemaVersion: 2, now: now)
    XCTAssertEqual(
      makeService().applyFetchedModification(ownNewer, isPendingDeleteOrTombstoned: noPendingDelete),
      .applied)
    XCTAssertEqual(
      try BlockedProfiles.findProfile(byID: id, in: context)?.name, "Healed",
      "own-origin records are applied, not skipped (§2, S-31)")

    // Own-origin equal-version payload-equal echo ⇒ no-op.
    let healed = try BlockedProfiles.findProfile(byID: id, in: context)!
    var echo = SyncedProfile(from: healed, originDeviceId: deviceId)
    echo.version = 6
    XCTAssertEqual(
      makeService().applyFetchedModification(
        echo.toCKRecord(in: zoneID),
        isPendingDeleteOrTombstoned: noPendingDelete),
      .applied)
    XCTAssertEqual(try BlockedProfiles.findProfile(byID: id, in: context)?.syncVersion, 6, "echo no-op")
  }

  // MARK: - S-30

  func testGivenThrowingCreate_WhenApplied_ThenRollbackNoSystemFieldsFailedApplyRecorded() throws {
    let now = Date()
    let id = UUID()
    let record = makeProfileRecord(
      id: id, name: "WillFail", version: 1, originDeviceId: "device-B", now: now)
    let service = makeService()
    struct BoomError: Error {}
    service.saveOverride = { throw BoomError() }

    let outcome = service.applyFetchedModification(record, isPendingDeleteOrTombstoned: noPendingDelete)

    XCTAssertEqual(outcome, .failed)
    XCTAssertNil(try BlockedProfiles.findProfile(byID: id, in: context), "rolled back")
    XCTAssertNil(store.systemFields(for: id.uuidString), "no systemFields after a thrown apply")
    XCTAssertTrue(service.pendingReenqueues.isEmpty, "no outbound effect")
    XCTAssertTrue(
      store.failedApplies.contains(
        FailedApply(recordName: id.uuidString, recordType: SyncedProfile.recordType, op: .upsert)))
  }

  // MARK: - N6 location merge

  func testGivenNewerRemoteLocation_WhenApplied_ThenClientClockMergeApplies() throws {
    let now = Date()
    let id = UUID()
    let local = SavedLocation(
      id: id, name: "Home", latitude: 1, longitude: 2, defaultRadiusMeters: 100,
      isLocked: false, updatedAt: now.addingTimeInterval(-100), syncVersion: 1)
    context.insert(local)
    try context.save()

    let newer = SyncedLocation(
      locationId: id, name: "Home Updated", latitude: 3, longitude: 4,
      defaultRadiusMeters: 250, isLocked: true, lastModified: now)
    let service = makeService()
    let record = newer.toCKRecord(in: zoneID)

    XCTAssertEqual(
      service.applyFetchedModification(record, isPendingDeleteOrTombstoned: noPendingDelete),
      .applied)
    let updated = try SavedLocation.find(byID: id, in: context)
    XCTAssertEqual(updated?.name, "Home Updated")
    XCTAssertEqual(updated?.latitude, 3)
    XCTAssertEqual(updated?.isLocked, true)
    XCTAssertNotNil(store.systemFields(for: id.uuidString))
  }

  func testGivenOlderRemoteLocation_WhenApplied_ThenFieldsUnchanged() throws {
    let now = Date()
    let id = UUID()
    let local = SavedLocation(
      id: id, name: "Home", latitude: 1, longitude: 2, defaultRadiusMeters: 100,
      isLocked: false, updatedAt: now, syncVersion: 1)
    context.insert(local)
    try context.save()

    let older = SyncedLocation(
      locationId: id, name: "Stale", latitude: 9, longitude: 9, defaultRadiusMeters: 999,
      isLocked: true, lastModified: now.addingTimeInterval(-500))
    XCTAssertEqual(
      makeService().applyFetchedModification(
        older.toCKRecord(in: zoneID), isPendingDeleteOrTombstoned: noPendingDelete),
      .applied)
    XCTAssertEqual(try SavedLocation.find(byID: id, in: context)?.name, "Home", "older remote ignored")
  }

  func testGivenAbsentLocation_WhenApplied_ThenCreated() throws {
    let now = Date()
    let id = UUID()
    let synced = SyncedLocation(
      locationId: id, name: "Cafe", latitude: 5, longitude: 6, defaultRadiusMeters: 80,
      isLocked: false, lastModified: now)
    XCTAssertEqual(
      makeService().applyFetchedModification(
        synced.toCKRecord(in: zoneID), isPendingDeleteOrTombstoned: noPendingDelete),
      .applied)
    XCTAssertEqual(try SavedLocation.find(byID: id, in: context)?.name, "Cafe")
  }

  func testGivenDeletedLocation_WhenStaleEchoFetched_ThenLocationNotRecreated() throws {
    let now = Date()
    let id = UUID()
    store.setDeleteWatermark(
      recordName: id.uuidString, value: now.timeIntervalSinceReferenceDate)
    let synced = SyncedLocation(
      locationId: id, name: "Stale Cafe", latitude: 5, longitude: 6, defaultRadiusMeters: 80,
      isLocked: false, lastModified: now)

    let outcome = makeService().applyFetchedModification(
      synced.toCKRecord(in: zoneID), isPendingDeleteOrTombstoned: noPendingDelete)

    XCTAssertEqual(outcome, .skippedStaleDelete)
    XCTAssertNil(
      try SavedLocation.find(byID: id, in: context),
      "#315: a location echo at or below the delete watermark must not recreate it")
    XCTAssertEqual(store.deleteWatermark(for: id.uuidString), now.timeIntervalSinceReferenceDate)
  }

  func testGivenDeletedLocation_WhenNewerRecreationFetched_ThenLocationCreated() throws {
    let now = Date()
    let id = UUID()
    store.setDeleteWatermark(
      recordName: id.uuidString, value: now.timeIntervalSinceReferenceDate)
    let synced = SyncedLocation(
      locationId: id, name: "New Cafe", latitude: 5, longitude: 6, defaultRadiusMeters: 80,
      isLocked: false, lastModified: now.addingTimeInterval(60))

    let outcome = makeService().applyFetchedModification(
      synced.toCKRecord(in: zoneID), isPendingDeleteOrTombstoned: noPendingDelete)

    XCTAssertEqual(outcome, .applied)
    XCTAssertEqual(try SavedLocation.find(byID: id, in: context)?.name, "New Cafe")
    XCTAssertNil(
      store.deleteWatermark(for: id.uuidString),
      "newer location recreation supersedes the delete watermark")
  }

  func testGivenNewerRemoteLocation_WhenApplied_ThenNothingReenqueued() throws {
    let now = Date()
    let apply = makeService()
    let locId = UUID()
    let location = SavedLocation(
      id: locId,
      name: "Home",
      latitude: 1,
      longitude: 2,
      updatedAt: now.addingTimeInterval(-3600)
    )
    context.insert(location)
    try context.save()

    let synced = SyncedLocation(
      locationId: locId,
      name: "Renamed",
      latitude: 1,
      longitude: 2,
      defaultRadiusMeters: 500,
      isLocked: false,
      lastModified: now
    )
    _ = apply.applyFetchedModification(
      synced.toCKRecord(in: zoneID), isPendingDeleteOrTombstoned: noPendingDelete)

    XCTAssertTrue(apply.drainReenqueues().isEmpty, "applying a location must never trigger a push")
  }

  func testGivenOlderRemoteLocation_WhenApplied_ThenNoOpAndNothingReenqueued() throws {
    let now = Date()
    let apply = makeService()
    let locId = UUID()
    let location = SavedLocation(
      id: locId, name: "Home", latitude: 1, longitude: 2, updatedAt: now)
    context.insert(location)
    try context.save()

    let synced = SyncedLocation(
      locationId: locId,
      name: "Stale",
      latitude: 9,
      longitude: 9,
      defaultRadiusMeters: 500,
      isLocked: false,
      lastModified: now.addingTimeInterval(-3600)
    )
    _ = apply.applyFetchedModification(
      synced.toCKRecord(in: zoneID), isPendingDeleteOrTombstoned: noPendingDelete)

    XCTAssertTrue(apply.drainReenqueues().isEmpty, "the N6 no-op branch must not push either")
  }

  // MARK: - Emergency versioned apply

  func testGivenNewerEmergencySettings_WhenApplied_ThenAppliedAndSystemFieldsStored() {
    let now = Date()
    let nextVersion = emergencyManager.emergencySettingsVersion + 1
    let remote = SyncedEmergencySettings(
      unblocksRemaining: 7, resetPeriodInDays: 21, lastResetDate: now,
      settingsLocked: true, version: nextVersion, lastModified: now, originDeviceId: "device-B")
    XCTAssertEqual(
      makeService().applyFetchedModification(
        remote.toCKRecord(in: zoneID), isPendingDeleteOrTombstoned: noPendingDelete),
      .applied)
    XCTAssertEqual(
      emergencyManager.getRemainingEmergencyUnblocks(), 3,
      "settings config no longer owns the derived count")
    XCTAssertEqual(emergencyManager.emergencySettingsVersion, nextVersion)
    XCTAssertNotNil(store.systemFields(for: SyncedEmergencySettings.recordName))
  }

  func testGivenOlderEmergencySettings_WhenApplied_ThenIgnoredNoSystemFields() {
    let now = Date()
    let baseline = emergencyManager.emergencySettingsVersion + 5
    emergencyManager.applyRemoteEmergencySettings(
      SyncedEmergencySettings(
        unblocksRemaining: 1, resetPeriodInDays: 28, lastResetDate: now,
        settingsLocked: false, version: baseline, lastModified: now, originDeviceId: "device-B"))
    let stale = SyncedEmergencySettings(
      unblocksRemaining: 99, resetPeriodInDays: 99, lastResetDate: now,
      settingsLocked: true, version: baseline - 1, lastModified: now, originDeviceId: "device-C")
    XCTAssertEqual(
      makeService().applyFetchedModification(
        stale.toCKRecord(in: zoneID), isPendingDeleteOrTombstoned: noPendingDelete),
      .applied)
    XCTAssertEqual(emergencyManager.getRemainingEmergencyUnblocks(), 3, "stale version ignored")
    XCTAssertNil(store.systemFields(for: SyncedEmergencySettings.recordName))
  }

  // MARK: - S-22

  func testGivenSessionModification_WhenApplied_ThenStopsMirrorAndAbsenceNeverStops() throws {
    let now = Date()
    let id = UUID()
    let profile = BlockedProfiles(id: id, name: "Focus", syncVersion: 1)
    context.insert(profile)
    try context.save()
    let localSession = BlockedProfileSession(tag: "local", blockedProfile: profile)

    func stoppedRecord() -> CKRecord {
      var session = ProfileSessionRecord(profileId: id)
      _ = session.applyUpdate(
        isActive: true, sequenceNumber: 1, deviceId: "device-B", startTime: now)
      _ = session.applyUpdate(
        isActive: false, sequenceNumber: 2, deviceId: "device-B", endTime: now)
      return session.toCKRecord(in: zoneID)
    }

    // (1) Remote stopped + local active ⇒ stop the mirror.
    sessionController.activeSession = localSession
    let service = makeService()
    XCTAssertEqual(
      service.applyFetchedModification(stoppedRecord(), isPendingDeleteOrTombstoned: noPendingDelete),
      .applied)
    XCTAssertTrue(sessionController.stopRemoteSessionCalled)
    XCTAssertEqual(sessionController.stopRemoteSessionProfileId, id)

    // (2) Remote stopped + NO local active session ⇒ nothing is stopped (absence never stops, I1).
    sessionController.activeSession = nil
    sessionController.stopRemoteSessionCalled = false
    sessionController.stopRemoteSessionProfileId = nil
    XCTAssertEqual(
      makeService().applyFetchedModification(
        stoppedRecord(), isPendingDeleteOrTombstoned: noPendingDelete),
      .applied)
    XCTAssertFalse(sessionController.stopRemoteSessionCalled)
  }

  func testGivenDifferentLocalProfileActive_WhenRemoteStartApplied_ThenDelegatesArbitration() throws {
    let now = Date(timeIntervalSinceReferenceDate: 1_000)
    let profileA = BlockedProfiles(name: "Local")
    let profileB = BlockedProfiles(name: "Remote")
    context.insert(profileA)
    context.insert(profileB)
    try context.save()
    sessionController.activeSession = BlockedProfileSession(
      tag: "local", blockedProfile: profileA, startTime: now.addingTimeInterval(-60))
    var remote = ProfileSessionRecord(profileId: profileB.id)
    _ = remote.applyUpdate(
      isActive: true,
      sequenceNumber: 1,
      deviceId: "device-B",
      startTime: now)

    XCTAssertEqual(
      makeService().applyFetchedModification(
        remote.toCKRecord(in: zoneID), isPendingDeleteOrTombstoned: noPendingDelete),
      .applied)

    XCTAssertTrue(sessionController.startRemoteSessionCalled)
    XCTAssertEqual(sessionController.startRemoteSessionProfileId, profileB.id)
  }

  func testGivenOwnSessionModification_WhenApplied_ThenSelfEchoFiltered() throws {
    let now = Date()
    let id = UUID()
    let profile = BlockedProfiles(id: id, name: "Focus", syncVersion: 1)
    context.insert(profile)
    try context.save()
    sessionController.activeSession = BlockedProfileSession(tag: "local", blockedProfile: profile)

    var own = ProfileSessionRecord(profileId: id)
    _ = own.applyUpdate(isActive: true, sequenceNumber: 1, deviceId: deviceId, startTime: now)
    _ = own.applyUpdate(isActive: false, sequenceNumber: 2, deviceId: deviceId, endTime: now)

    XCTAssertEqual(
      makeService().applyFetchedModification(
        own.toCKRecord(in: zoneID), isPendingDeleteOrTombstoned: noPendingDelete),
      .applied)
    XCTAssertFalse(sessionController.stopRemoteSessionCalled, "lastModifiedBy == self is ignored")
  }

  // MARK: - S-1

  func testGivenTombstonedProfile_WhenFetchedDeletionApplied_ThenOnlyThatProfileDeletedAndTombstoneCleared()
    throws
  {
    let keepId = UUID()
    let dropId = UUID()
    let keep = BlockedProfiles(id: keepId, name: "Keep", syncVersion: 1)
    let drop = BlockedProfiles(id: dropId, name: "Drop", syncVersion: 1)
    context.insert(keep)
    context.insert(drop)
    try context.save()
    store.setSystemFields(Data([0x01]), for: dropId.uuidString)
    store.setTombstone(recordName: dropId.uuidString, changeTag: "tag-1")

    let scheduler = ManualProfileDeleteCommitScheduler()
    let service = makeService(scheduleProfileDeleteCommit: scheduler.schedule)

    let outcome = service.applyFetchedDeletion(
      recordID: CKRecord.ID(recordName: dropId.uuidString, zoneID: zoneID),
      recordType: SyncedProfile.recordType)

    XCTAssertEqual(outcome, .deleted)
    XCTAssertNil(try BlockedProfiles.findProfile(byID: dropId, in: context))
    XCTAssertNotNil(try BlockedProfiles.findProfile(byID: keepId, in: context), "only the named id is deleted")
    XCTAssertNotNil(store.systemFields(for: dropId.uuidString), "bookkeeping waits for durable delete")
    XCTAssertEqual(store.deleteTombstones[dropId.uuidString] ?? nil, "tag-1")

    scheduler.runNext()

    XCTAssertNil(store.systemFields(for: dropId.uuidString))
    XCTAssertNil(store.deleteTombstones[dropId.uuidString] ?? nil, "matching tombstone cleared (I12)")
  }

  func testGivenLocationDeletion_WhenApplied_ThenLocalLocationDeleted() throws {
    let id = UUID()
    let location = SavedLocation(
      id: id, name: "Home", latitude: 1, longitude: 2, defaultRadiusMeters: 100,
      isLocked: false, syncVersion: 1)
    context.insert(location)
    try context.save()

    XCTAssertEqual(
      makeService().applyFetchedDeletion(
        recordID: CKRecord.ID(recordName: id.uuidString, zoneID: zoneID),
        recordType: SyncedLocation.recordType),
      .deleted)
    XCTAssertNil(try SavedLocation.find(byID: id, in: context))
  }

  func testGivenFetchedLocationDelete_WhenSameTimestampEchoFetched_ThenLocationNotRecreated()
    throws
  {
    let now = Date()
    let id = UUID()
    let location = SavedLocation(
      id: id, name: "Home", latitude: 1, longitude: 2, defaultRadiusMeters: 100,
      isLocked: false, updatedAt: now, syncVersion: 1)
    context.insert(location)
    try context.save()

    let service = makeService()
    XCTAssertEqual(
      service.applyFetchedDeletion(
        recordID: CKRecord.ID(recordName: id.uuidString, zoneID: zoneID),
        recordType: SyncedLocation.recordType),
      .deleted)

    let watermark = try XCTUnwrap(store.deleteWatermark(for: id.uuidString))
    XCTAssertEqual(watermark, now.timeIntervalSinceReferenceDate, accuracy: 0.000_001)

    let echo = SyncedLocation(
      locationId: id, name: "Echo", latitude: 1, longitude: 2, defaultRadiusMeters: 100,
      isLocked: false, lastModified: now)
    let outcome = service.applyFetchedModification(
      echo.toCKRecord(in: zoneID), isPendingDeleteOrTombstoned: noPendingDelete)

    XCTAssertEqual(outcome, .skippedStaleDelete)
    XCTAssertNil(
      try SavedLocation.find(byID: id, in: context),
      "#329: fetched-delete location watermarks must block same-timestamp echoes")
  }

  func testGivenReferencingProfile_WhenLocationDeletionApplied_ThenRepairedAndReenqueued()
    throws
  {
    let apply = makeService()
    let locId = UUID()
    let profileId = UUID()
    let location = SavedLocation(id: locId, name: "Library", latitude: 1, longitude: 2)
    context.insert(location)
    let profile = BlockedProfiles(id: profileId, name: "Homework", syncVersion: 4)
    profile.geofenceRule = ProfileGeofenceRule(
      ruleType: .outside,
      locationReferences: [ProfileLocationReference(savedLocationId: locId)],
      allowEmergencyOverride: true)
    context.insert(profile)
    try context.save()

    let outcome = apply.applyFetchedDeletion(
      recordID: CKRecord.ID(recordName: locId.uuidString, zoneID: zoneID),
      recordType: SyncedLocation.recordType)

    XCTAssertEqual(outcome, .deleted)
    XCTAssertNil(try SavedLocation.find(byID: locId, in: context))
    let reread = try XCTUnwrap(BlockedProfiles.findProfile(byID: profileId, in: context))
    XCTAssertNil(reread.geofenceRule, "dangling rule repaired on the peer")
    XCTAssertEqual(reread.syncVersion, 5, "bumped so the peer accepts the repaired payload")
    XCTAssertEqual(
      apply.drainReenqueues(),
      [CKRecord.ID(recordName: profileId.uuidString, zoneID: zoneID)],
      "repaired profile queued for re-push via the I2 exception")
  }

  func testGivenDanglingProfileButLocationAlreadyAbsent_WhenDeletionApplied_ThenStillRepairs()
    throws
  {
    let apply = makeService()
    let locId = UUID()
    let profileId = UUID()
    let profile = BlockedProfiles(id: profileId, name: "Homework", syncVersion: 4)
    profile.geofenceRule = ProfileGeofenceRule(
      ruleType: .outside,
      locationReferences: [ProfileLocationReference(savedLocationId: locId)],
      allowEmergencyOverride: true)
    context.insert(profile)
    try context.save()

    let outcome = apply.applyFetchedDeletion(
      recordID: CKRecord.ID(recordName: locId.uuidString, zoneID: zoneID),
      recordType: SyncedLocation.recordType)

    XCTAssertEqual(outcome, .deleted, "repaired a dangling ref means this is not a no-op")
    let reread = try XCTUnwrap(BlockedProfiles.findProfile(byID: profileId, in: context))
    XCTAssertNil(reread.geofenceRule, "dangling ref repaired even though the row was already gone")
    XCTAssertEqual(reread.syncVersion, 5)
    XCTAssertEqual(
      apply.drainReenqueues(), [CKRecord.ID(recordName: profileId.uuidString, zoneID: zoneID)])
  }

  func testGivenDeletionForAbsentProfile_WhenApplied_ThenNotPresentNoMutation() throws {
    let id = UUID()

    XCTAssertEqual(
      makeService().applyFetchedDeletion(
        recordID: CKRecord.ID(recordName: id.uuidString, zoneID: zoneID),
        recordType: SyncedProfile.recordType),
      .notPresent)
    XCTAssertEqual(
      sessionController.setRemoteSessionActiveCalls.map { $0.1 },
      [id],
      "a satisfied profile delete clears any durable remote-active lock for that profile")
    XCTAssertEqual(sessionController.setRemoteSessionActiveCalls.map { $0.0 }, [false])
  }

  func testGivenSessionDeletion_WhenLocalActive_ThenMirrorStopped() throws {
    let id = UUID()
    let profile = BlockedProfiles(id: id, name: "Focus", syncVersion: 1)
    context.insert(profile)
    try context.save()
    sessionController.activeSession = BlockedProfileSession(tag: "local", blockedProfile: profile)

    XCTAssertEqual(
      makeService().applyFetchedDeletion(
        recordID: CKRecord.ID(
          recordName: ProfileSessionRecord.recordName(for: id), zoneID: zoneID),
        recordType: ProfileSessionRecord.recordType),
      .deleted)
    XCTAssertTrue(sessionController.stopRemoteSessionCalled)
    XCTAssertEqual(sessionController.stopRemoteSessionProfileId, id)
  }

  // #203: a remote profile deletion for the active profile must stop the session
  // before deleting the profile.
  func testGivenActiveSessionProfile_WhenProfileDeletionApplied_ThenSessionStoppedThenDeleted()
    throws
  {
    let id = UUID()
    let profile = BlockedProfiles(id: id, name: "Focus", syncVersion: 1)
    context.insert(profile)
    let session = BlockedProfileSession(tag: "local", blockedProfile: profile)
    context.insert(session)
    try context.save()
    sessionController.activeSession = session

    let outcome = makeService().applyFetchedDeletion(
      recordID: CKRecord.ID(recordName: id.uuidString, zoneID: zoneID),
      recordType: SyncedProfile.recordType)

    XCTAssertEqual(outcome, .deleted)
    XCTAssertTrue(
      sessionController.stopRemoteSessionCalled,
      "the owned session must be stopped before the profile is deleted (#203)")
    XCTAssertEqual(sessionController.stopRemoteSessionProfileId, id)
    XCTAssertNil(
      try BlockedProfiles.findProfile(byID: id, in: context), "profile is still deleted")
  }

  func testGivenRemoteProfileDeletion_WhenApplied_ThenDeleteIsMarkedBeforeDeferredSaveAndBookkeepingClearedAfterCommit()
    throws
  {
    let id = UUID()
    let profile = BlockedProfiles(id: id, name: "RemoteDelete", syncVersion: 1)
    context.insert(profile)
    try context.save()
    store.setSystemFields(Data("cached".utf8), for: id.uuidString)

    let scheduler = ManualProfileDeleteCommitScheduler()
    let service = makeService(scheduleProfileDeleteCommit: scheduler.schedule)

    let outcome = service.applyFetchedDeletion(
      recordID: CKRecord.ID(recordName: id.uuidString, zoneID: zoneID),
      recordType: SyncedProfile.recordType)

    XCTAssertEqual(outcome, .deleted)
    XCTAssertEqual(scheduler.scheduledOperations.count, 1, "remote profile delete save is deferred")
    XCTAssertNil(
      try BlockedProfiles.findProfile(byID: id, in: context),
      "same context excludes the pending-deleted profile before save")
    XCTAssertNotNil(
      try BlockedProfiles.findProfile(byID: id, in: ModelContext(container)),
      "remote profile delete is not persisted until the deferred commit runs")
    XCTAssertNotNil(store.systemFields(for: id.uuidString), "bookkeeping waits for durable delete")

    scheduler.runNext()

    XCTAssertNil(try BlockedProfiles.findProfile(byID: id, in: ModelContext(container)))
    XCTAssertNil(store.systemFields(for: id.uuidString))
  }

  func testGivenRemoteActiveProfile_WhenFetchedProfileDeleteCommits_ThenRemoteActiveClearsAfterCommit()
    throws
  {
    let id = UUID()
    let profile = BlockedProfiles(id: id, name: "RemoteDelete", syncVersion: 1)
    context.insert(profile)
    try context.save()

    let scheduler = ManualProfileDeleteCommitScheduler()
    let service = makeService(scheduleProfileDeleteCommit: scheduler.schedule)

    XCTAssertEqual(
      service.applyFetchedDeletion(
        recordID: CKRecord.ID(recordName: id.uuidString, zoneID: zoneID),
        recordType: SyncedProfile.recordType),
      .deleted)
    XCTAssertTrue(
      sessionController.setRemoteSessionActiveCalls.isEmpty,
      "remote-active must not clear before the deferred delete is durably saved")

    scheduler.runNext()

    XCTAssertEqual(sessionController.setRemoteSessionActiveCalls.count, 1)
    XCTAssertEqual(sessionController.setRemoteSessionActiveCalls.first?.0, false)
    XCTAssertEqual(sessionController.setRemoteSessionActiveCalls.first?.1, id)
  }

  func testGivenFetchedProfileDeleteAtV3_WhenSameVersionRepushFetched_ThenProfileNotRecreated()
    throws
  {
    let now = Date()
    let id = UUID()
    let profile = BlockedProfiles(id: id, name: "RemoteDelete", syncVersion: 3)
    context.insert(profile)
    try context.save()

    let scheduler = ManualProfileDeleteCommitScheduler()
    let service = makeService(scheduleProfileDeleteCommit: scheduler.schedule)

    XCTAssertEqual(
      service.applyFetchedDeletion(
        recordID: CKRecord.ID(recordName: id.uuidString, zoneID: zoneID),
        recordType: SyncedProfile.recordType),
      .deleted)
    scheduler.runNext()

    XCTAssertEqual(store.deleteWatermark(for: id.uuidString), 3)
    XCTAssertNil(try BlockedProfiles.findProfile(byID: id, in: context))

    let repush = makeProfileRecord(
      id: id, name: "V1 Repush", version: 3, originDeviceId: "device-v1", now: now)
    let outcome = service.applyFetchedModification(repush, isPendingDeleteOrTombstoned: noPendingDelete)

    XCTAssertEqual(outcome, .skippedStaleDelete)
    XCTAssertNil(
      try BlockedProfiles.findProfile(byID: id, in: context),
      "#329: fetched-delete devices must not materialize same-version V1 re-pushes")
  }

  func testGivenFetchedProfileDeleteAtV3_WhenHigherVersionRecreationFetched_ThenProfileCreated()
    throws
  {
    let now = Date()
    let id = UUID()
    let profile = BlockedProfiles(id: id, name: "RemoteDelete", syncVersion: 3)
    context.insert(profile)
    try context.save()

    let scheduler = ManualProfileDeleteCommitScheduler()
    let service = makeService(scheduleProfileDeleteCommit: scheduler.schedule)

    XCTAssertEqual(
      service.applyFetchedDeletion(
        recordID: CKRecord.ID(recordName: id.uuidString, zoneID: zoneID),
        recordType: SyncedProfile.recordType),
      .deleted)
    scheduler.runNext()

    let recreation = makeProfileRecord(
      id: id, name: "Recreated", version: 4, originDeviceId: "device-B", now: now)
    let outcome = service.applyFetchedModification(recreation, isPendingDeleteOrTombstoned: noPendingDelete)

    XCTAssertEqual(outcome, .applied)
    XCTAssertEqual(try BlockedProfiles.findProfile(byID: id, in: context)?.name, "Recreated")
    XCTAssertNil(store.deleteWatermark(for: id.uuidString))
  }

  func testGivenRemoteProfileDeletionSaveFails_WhenDeferredCommitRuns_ThenCommitObserverNotCalled()
    throws
  {
    struct BoomError: Error {}

    let id = UUID()
    let profile = BlockedProfiles(id: id, name: "RemoteDelete", syncVersion: 1)
    context.insert(profile)
    try context.save()
    BlockedProfiles.updateSnapshot(for: profile)
    store.setSystemFields(Data("cached".utf8), for: id.uuidString)
    store.setTombstone(recordName: id.uuidString, changeTag: "tag-1")

    let scheduler = ManualProfileDeleteCommitScheduler()
    let service = makeService(scheduleProfileDeleteCommit: scheduler.schedule)
    var committedNames: [String] = []
    service.profileDeleteCommitObserver = { committedNames.append($0) }
    service.saveOverride = { throw BoomError() }

    XCTAssertEqual(
      service.applyFetchedDeletion(
        recordID: CKRecord.ID(recordName: id.uuidString, zoneID: zoneID),
        recordType: SyncedProfile.recordType),
      .deleted)
    XCTAssertNil(SharedData.snapshot(for: id.uuidString))

    scheduler.runNext()

    XCTAssertTrue(committedNames.isEmpty)
    XCTAssertTrue(
      sessionController.setRemoteSessionActiveCalls.isEmpty,
      "rollback must leave the remote-active lock intact for retry")
    XCTAssertNotNil(store.systemFields(for: id.uuidString), "failed commit keeps deletion bookkeeping")
    XCTAssertEqual(store.deleteTombstones[id.uuidString] ?? nil, "tag-1")
    XCTAssertNotNil(SharedData.snapshot(for: id.uuidString))
  }

  func testGivenTwoRemoteProfileDeletions_WhenFirstDeferredCommitRollsBackSecond_ThenSecondBookkeepingIsRetained()
    throws
  {
    struct BoomError: Error {}

    let firstId = UUID()
    let secondId = UUID()
    context.insert(BlockedProfiles(id: firstId, name: "FirstRemoteDelete", syncVersion: 1))
    context.insert(BlockedProfiles(id: secondId, name: "SecondRemoteDelete", syncVersion: 1))
    try context.save()
    store.setSystemFields(Data("first-cached".utf8), for: firstId.uuidString)
    store.setSystemFields(Data("second-cached".utf8), for: secondId.uuidString)
    store.setTombstone(recordName: firstId.uuidString, changeTag: "first-tag")
    store.setTombstone(recordName: secondId.uuidString, changeTag: "second-tag")

    let scheduler = ManualProfileDeleteCommitScheduler()
    let service = makeService(scheduleProfileDeleteCommit: scheduler.schedule)
    var committedNames: [String] = []
    service.profileDeleteCommitObserver = { committedNames.append($0) }

    service.saveOverride = { throw BoomError() }
    XCTAssertEqual(
      service.applyFetchedDeletion(
        recordID: CKRecord.ID(recordName: firstId.uuidString, zoneID: zoneID),
        recordType: SyncedProfile.recordType),
      .deleted)

    service.saveOverride = nil
    XCTAssertEqual(
      service.applyFetchedDeletion(
        recordID: CKRecord.ID(recordName: secondId.uuidString, zoneID: zoneID),
        recordType: SyncedProfile.recordType),
      .deleted)

    scheduler.runNext()
    scheduler.runNext()

    XCTAssertTrue(committedNames.isEmpty)
    XCTAssertNotNil(
      store.systemFields(for: secondId.uuidString),
      "rollback restored the second profile, so remote delete bookkeeping must remain")
    XCTAssertEqual(store.deleteTombstones[secondId.uuidString] ?? nil, "second-tag")
    XCTAssertNotNil(try BlockedProfiles.findProfile(byID: secondId, in: context))
  }

  // Negative: a remote profile deletion for a non-active profile must not touch the session.
  func testGivenDeletionForNonActiveProfile_WhenApplied_ThenNoSessionStop() throws {
    let activeId = UUID()
    let deleteId = UUID()
    let activeProfile = BlockedProfiles(id: activeId, name: "Active", syncVersion: 1)
    let deleteProfile = BlockedProfiles(id: deleteId, name: "Delete", syncVersion: 1)
    context.insert(activeProfile)
    context.insert(deleteProfile)
    let activeSession = BlockedProfileSession(tag: "local", blockedProfile: activeProfile)
    context.insert(activeSession)
    try context.save()
    sessionController.activeSession = activeSession

    XCTAssertEqual(
      makeService().applyFetchedDeletion(
        recordID: CKRecord.ID(recordName: deleteId.uuidString, zoneID: zoneID),
        recordType: SyncedProfile.recordType),
      .deleted)
    XCTAssertFalse(
      sessionController.stopRemoteSessionCalled, "unrelated profile deletion never stops the session")
    XCTAssertNil(try BlockedProfiles.findProfile(byID: deleteId, in: context))
    XCTAssertNotNil(try BlockedProfiles.findProfile(byID: activeId, in: context))
  }

  // MARK: - S-2

  func testGivenEmptyFetch_WhenApplied_ThenZeroLocalMutations() throws {
    let p1 = BlockedProfiles(id: UUID(), name: "A", syncVersion: 1)
    let p2 = BlockedProfiles(id: UUID(), name: "B", syncVersion: 1)
    context.insert(p1)
    context.insert(p2)
    try context.save()
    let before = try BlockedProfiles.fetchProfiles(in: context).count

    let service = makeService()
    for record in [CKRecord]() {
      _ = service.applyFetchedModification(record, isPendingDeleteOrTombstoned: noPendingDelete)
    }
    for pair in [(CKRecord.ID, CKRecord.RecordType)]() {
      _ = service.applyFetchedDeletion(recordID: pair.0, recordType: pair.1)
    }

    XCTAssertEqual(try BlockedProfiles.fetchProfiles(in: context).count, before, "empty fetch mutates nothing")
    XCTAssertTrue(service.pendingReenqueues.isEmpty)
  }

  // MARK: - S-32

  func testGivenPendingDeleteId_WhenModificationApplied_ThenSkippedPendingDelete() throws {
    let now = Date()
    let id = UUID()
    let record = makeProfileRecord(
      id: id, name: "Ghost", version: 3, originDeviceId: "device-B", now: now)
    let service = makeService()

    let outcome = service.applyFetchedModification(
      record, isPendingDeleteOrTombstoned: { $0 == id.uuidString })

    XCTAssertEqual(outcome, .skippedPendingDelete)
    XCTAssertNil(
      try BlockedProfiles.findProfile(byID: id, in: context), "no local create while a delete is pending")
    XCTAssertNil(store.systemFields(for: id.uuidString))
    XCTAssertTrue(service.pendingReenqueues.isEmpty)
  }

  // MARK: - S-34

  func testGivenEchoGuardId_WhenModificationApplied_ThenSkippedUntilDrained() throws {
    let now = Date()
    let id = UUID()
    let record = makeProfileRecord(
      id: id, name: "Recreated", version: 3, originDeviceId: "device-B", now: now)
    let service = makeService()

    // A cycle that started before the delete confirmation delivers an echo ⇒ skipped.
    service.recentlyConfirmedDeletes = [id.uuidString]
    XCTAssertEqual(
      service.applyFetchedModification(record, isPendingDeleteOrTombstoned: noPendingDelete),
      .skippedPendingDelete)
    XCTAssertNil(try BlockedProfiles.findProfile(byID: id, in: context))

    // After the guard drains (controller clears it at the next cycle's start), the same
    // record is a genuine recreation and must apply.
    service.recentlyConfirmedDeletes = []
    XCTAssertEqual(
      service.applyFetchedModification(record, isPendingDeleteOrTombstoned: noPendingDelete),
      .applied)
    XCTAssertNotNil(try BlockedProfiles.findProfile(byID: id, in: context), "genuine recreation applies")
  }

  func testGivenIncomingSafetyOptions_WhenLocallyConfirmedThenUpdated_ThenStartEligibilityAndSnapshotFollow() throws {
    let now = Date()
    let manager = StrategyManager()
    defer { manager.stopTimer() }
    for (adult, installs) in [(true, false), (false, true)] {
      let id = UUID()
      let record = makeProfileRecord(id: id, name: "Safety", version: 1, originDeviceId: "device-B", now: now)
      record["scheduleData"] = try JSONEncoder().encode(
        BlockedProfileSchedule(
          days: Weekday.allCases, startHour: 0, startMinute: 0, endHour: 23, endMinute: 59,
          updatedAt: now.addingTimeInterval(-120)))
      record["blockAdultWebsites"] = adult
      record["blockAppInstallation"] = installs
      XCTAssertEqual(makeService().applyFetchedModification(record, isPendingDeleteOrTombstoned: noPendingDelete), .applied)
      let profile = try XCTUnwrap(BlockedProfiles.findProfile(byID: id, in: context))
      XCTAssertEqual(profile.blockAdultWebsites, adult)
      XCTAssertEqual(profile.blockAppInstallation, installs)
      XCTAssertTrue(profile.needsAppSelection)
      XCTAssertNotNil(manager.rejectionForStart(profile, activeSessionProvider: { nil }))
      let needsSelection = BlockedProfiles.needsAppSelectionAfterLocalSave(
        currentNeedsAppSelection: profile.needsAppSelection, selection: profile.selectedActivity,
        blockAdultWebsites: profile.blockAdultWebsites, blockAppInstallation: profile.blockAppInstallation)
      _ = try BlockedProfiles.updateProfile(profile, in: context, now: now, needsAppSelection: needsSelection)
      XCTAssertNil(manager.rejectionForStart(profile, activeSessionProvider: { nil }))
      XCTAssertEqual(SharedData.snapshot(for: id.uuidString)?.blockAdultWebsites, adult)
      XCTAssertEqual(SharedData.snapshot(for: id.uuidString)?.blockAppInstallation, installs)
      record["version"] = 2
      record["blockAdultWebsites"] = false
      record["blockAppInstallation"] = false
      XCTAssertEqual(makeService().applyFetchedModification(record, isPendingDeleteOrTombstoned: noPendingDelete), .applied)
      XCTAssertFalse(profile.blockAdultWebsites)
      XCTAssertFalse(profile.blockAppInstallation)
      XCTAssertEqual(SharedData.snapshot(for: id.uuidString)?.blockAdultWebsites, false)
      XCTAssertEqual(SharedData.snapshot(for: id.uuidString)?.blockAppInstallation, false)
      XCTAssertTrue(profile.needsAppSelection)
      XCTAssertNotNil(manager.rejectionForStart(profile, activeSessionProvider: { nil }))
      let updatedSnapshot = try XCTUnwrap(SharedData.snapshot(for: id.uuidString))
      ScheduleTimerActivity().start(for: updatedSnapshot)
      XCTAssertNil(SharedData.getActiveSharedSession())
      let victim = SharedData.SessionSnapshot(id: "victim", tag: "t", blockedProfileId: UUID(), startTime: now, forceStarted: false)
      let victimProfile = BlockedProfiles(id: victim.blockedProfileId, name: "Victim", createdAt: now, updatedAt: now)
      victimProfile.stopConditions = ProfileStopConditions(manual: true)
      BlockedProfiles.updateSnapshot(for: victimProfile)
      SharedData.createActiveSharedSession(for: victim)
      ScheduleTimerActivity().start(for: updatedSnapshot)
      XCTAssertEqual(SharedData.getActiveSharedSession()?.id, "victim")
      SharedData.endActiveSharedSession()
      AppBlockerUtil().deactivateRestrictions()
    }
  }

  func testGivenLegacyProfileEnablingSafety_WhenOlderSchemaWinsVersion_ThenSafeguardsSurvive() throws {
    let now = Date()
    for (adult, installs) in [(true, false), (false, true)] {
      let profile = BlockedProfiles(name: "Legacy", createdAt: now, updatedAt: now, syncVersion: 1)
      profile.profileSchemaVersion = 1
      profile.blockingStrategyId = NFCBlockingStrategy.id
      context.insert(profile)
      try context.save()
      _ = try BlockedProfiles.updateProfile(
        profile, in: context, now: now, blockAdultWebsites: adult, blockAppInstallation: installs)
      let record = makeProfileRecord(
        id: profile.id, name: "Old-device rename", version: 100, originDeviceId: "device-B", schemaVersion: 1, now: now)
      record["blockAdultWebsites"] = nil
      record["blockAppInstallation"] = nil
      let service = makeService()
      XCTAssertEqual(service.applyFetchedModification(record, isPendingDeleteOrTombstoned: noPendingDelete), .applied)
      XCTAssertTrue(service.pendingReenqueues.contains(record.recordID))
      XCTAssertEqual(profile.blockAdultWebsites, adult)
      XCTAssertEqual(profile.blockAppInstallation, installs)
      XCTAssertEqual(profile.profileSchemaVersion, 2)
      XCTAssertTrue(profile.startTriggers.anyNFC)
      XCTAssertTrue(profile.stopConditions.sameNFC)
    }
  }

  func testGivenOtherRestrictionsRemain_WhenRemoteRemovesSafety_ThenProfileStaysEligible() throws {
    let now = Date()
    for (domains, allowApps, allowDomains) in [(["example.com"], false, false), ([], true, false), ([], false, true)] {
      let profile = BlockedProfiles(
        name: "Local", createdAt: now, updatedAt: now,
        blockAdultWebsites: true, syncVersion: 1)
      context.insert(profile)
      try context.save()
      let record = makeProfileRecord(id: profile.id, name: "Remote", version: 2, originDeviceId: "device-B", now: now)
      record["domains"] = domains
      record["enableAllowMode"] = allowApps
      record["enableAllowModeDomains"] = allowDomains
      XCTAssertEqual(makeService().applyFetchedModification(record, isPendingDeleteOrTombstoned: noPendingDelete), .applied)
      XCTAssertFalse(profile.needsAppSelection)
    }
  }

}
