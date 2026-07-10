import CloudKit
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class RecordProviderTests: XCTestCase {
  private var container: ModelContainer!
  private var context: ModelContext!
  private var store: SyncEngineStore!
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
    suiteName = "RecordProviderTests-\(UUID().uuidString)"
    SharedData.configure(suite: UserDefaults(suiteName: suiteName)!)
    storeSuiteName = "RecordProviderTests-store-\(UUID().uuidString)"
    emergencySuiteName = "RecordProviderTests-emg-\(UUID().uuidString)"
    storeDefaults = UserDefaults(suiteName: storeSuiteName)!
    emergencyDefaults = UserDefaults(suiteName: emergencySuiteName)!
    store = SyncEngineStore(userRecordName: "user-1", defaults: storeDefaults)
    container = try TestModelContainer.create()
    context = container.mainContext
    emergencyManager = EmergencyUnblockManager(defaults: emergencyDefaults)
  }

  override func tearDown() async throws {
    UserDefaults().removePersistentDomain(forName: suiteName)
    UserDefaults().removePersistentDomain(forName: storeSuiteName)
    UserDefaults().removePersistentDomain(forName: emergencySuiteName)
    try await super.tearDown()
  }

  private func makeProvider() -> RecordProvider {
    RecordProvider(
      modelContext: context, store: store, emergencyManager: emergencyManager, deviceId: deviceId)
  }

  func testGivenLocalProfile_WhenMaterializedFresh_ThenBuildsProfileRecordInSyncZone() throws {
    let id = UUID()
    let profile = BlockedProfiles(id: id, name: "Focus", syncVersion: 3)
    context.insert(profile)
    try context.save()

    let record = makeProvider().record(forRecordName: id.uuidString)

    XCTAssertNotNil(record)
    XCTAssertEqual(record?.recordType, SyncedProfile.recordType)
    XCTAssertEqual(record?.recordID.recordName, id.uuidString)
    XCTAssertEqual(record?.recordID.zoneID.ownerName, CKCurrentUserDefaultName)
    XCTAssertEqual(record?[SyncedProfile.FieldKey.name.rawValue] as? String, "Focus")
    XCTAssertEqual(record?[SyncedProfile.FieldKey.version.rawValue] as? Int, 3)
    XCTAssertEqual(record?[SyncedProfile.FieldKey.originDeviceId.rawValue] as? String, deviceId)
  }

  func testGivenCachedSystemFields_WhenProfileMaterialized_ThenReusesCachedRecordID() throws {
    let id = UUID()
    let profile = BlockedProfiles(id: id, name: "Focus", syncVersion: 1)
    context.insert(profile)
    try context.save()
    // Seed cached system fields from a record in a SENTINEL zone — proves cache reuse.
    let sentinelZone = CKRecordZone.ID(zoneName: "DeviceSync", ownerName: "sentinel-owner")
    let cached = CKRecord(
      recordType: SyncedProfile.recordType,
      recordID: CKRecord.ID(recordName: id.uuidString, zoneID: sentinelZone))
    store.setSystemFields(CKRecordSystemFieldsCodec.encode(cached), for: id.uuidString)

    let record = makeProvider().record(forRecordName: id.uuidString)

    XCTAssertEqual(record?.recordID.zoneID.ownerName, "sentinel-owner")
    XCTAssertEqual(record?[SyncedProfile.FieldKey.name.rawValue] as? String, "Focus")
  }

  func testGivenLocalLocation_WhenMaterialized_ThenBuildsLocationRecord() throws {
    let id = UUID()
    let location = SavedLocation(
      id: id, name: "Home", latitude: 1, longitude: 2, defaultRadiusMeters: 150,
      isLocked: true, syncVersion: 1)
    context.insert(location)
    try context.save()

    let record = makeProvider().record(forRecordName: id.uuidString)

    XCTAssertEqual(record?.recordType, SyncedLocation.recordType)
    XCTAssertEqual(record?[SyncedLocation.FieldKey.name.rawValue] as? String, "Home")
    XCTAssertEqual(record?[SyncedLocation.FieldKey.isLocked.rawValue] as? Bool, true)
  }

  func testGivenEmergencyRecordName_WhenMaterialized_ThenBuildsEmergencyRecord() {
    let now = Date()
    emergencyManager.seedForTesting(allowance: 3, epoch: 1)
    _ = emergencyManager.consumeUnblockEvent(now: now)
    emergencyManager.applyRemoteEmergencySettings(
      SyncedEmergencySettings(
        unblocksRemaining: 99, resetPeriodInDays: 14, lastResetDate: now,
        settingsLocked: true, version: 4, lastModified: now, originDeviceId: "remote"))

    let record = makeProvider().record(forRecordName: SyncedEmergencySettings.recordName)

    XCTAssertEqual(record?.recordType, SyncedEmergencySettings.recordType)
    XCTAssertEqual(record?.recordID.recordName, SyncedEmergencySettings.recordName)
    XCTAssertEqual(record?[SyncedEmergencySettings.FieldKey.unblocksRemaining.rawValue] as? Int, 2)
    XCTAssertEqual(record?[SyncedEmergencySettings.FieldKey.version.rawValue] as? Int, 4)
  }

  func testGivenEmergencyEpochRecordName_WhenMaterialized_ThenBuildsEpochRecord() {
    emergencyManager.seedForTesting(allowance: 3, epoch: 4)

    let record = makeProvider().record(forRecordName: SyncedEmergencyEpoch.recordName)

    XCTAssertEqual(record?.recordType, SyncedEmergencyEpoch.recordType)
    XCTAssertEqual(record?.recordID.recordName, SyncedEmergencyEpoch.recordName)
    XCTAssertEqual(record?[SyncedEmergencyEpoch.FieldKey.epoch.rawValue] as? Int, 4)
  }

  func testGivenEmergencyUnblockEventRecordName_WhenMaterialized_ThenBuildsEventRecord() {
    let now = Date()
    emergencyManager.seedForTesting(allowance: 3, epoch: 2)
    let event = emergencyManager.consumeUnblockEvent(now: now)

    let record = makeProvider().record(forRecordName: event.recordName)

    XCTAssertEqual(record?.recordType, SyncedEmergencyUnblockEvent.recordType)
    XCTAssertEqual(record?.recordID.recordName, event.recordName)
    XCTAssertEqual(
      record?[SyncedEmergencyUnblockEvent.FieldKey.id.rawValue] as? String,
      event.id.uuidString)
    XCTAssertEqual(record?[SyncedEmergencyUnblockEvent.FieldKey.resetEpoch.rawValue] as? Int, 2)
  }

  func testGivenAbsentEntity_WhenMaterialized_ThenNil() {
    XCTAssertNil(makeProvider().record(forRecordName: UUID().uuidString))
  }

  func testGivenNewerSchemaProfile_WhenMaterialized_ThenNil() throws {
    let id = UUID()
    let profile = BlockedProfiles(id: id, name: "Future", syncVersion: 1)
    profile.profileSchemaVersion = BlockedProfiles.currentSchemaVersion + 1
    context.insert(profile)
    try context.save()

    XCTAssertNil(makeProvider().record(forRecordName: id.uuidString))
  }

  func testGivenSessionRecordName_WhenMaterialized_ThenNil() {
    let name = ProfileSessionRecord.recordName(for: UUID())
    XCTAssertNil(makeProvider().record(forRecordName: name))
  }
}
