import SwiftData
import XCTest

@testable import FamilyFoqos

/// Regression tests for issue #198: the app-group ProfileSnapshot must reflect
/// trigger/schedule edits persisted via TriggerConfigurationModel.saveToProfile,
/// otherwise the FoqosDeviceMonitor extension enforces from a stale snapshot and
/// scheduled blocking never starts in the background.
@MainActor
final class ProfileSaveSnapshotTests: XCTestCase {

  private var container: ModelContainer!
  private var context: ModelContext!
  private var testSuiteName: String!

  override func setUp() async throws {
    try await super.setUp()
    testSuiteName = "ProfileSaveSnapshotTests-\(UUID().uuidString)"
    SharedData.configure(
      suite: UserDefaults(suiteName: testSuiteName)!
    )
    container = try TestModelContainer.create()
    context = container.mainContext
  }

  override func tearDown() async throws {
    UserDefaults().removePersistentDomain(forName: testSuiteName)
    try await super.tearDown()
  }

  func testGivenNewProfileWithScheduleStartTrigger_WhenTriggerConfigSaved_ThenSnapshotContainsStartSchedule()
    throws
  {
    let now = Date()
    let profile = try BlockedProfiles.createProfile(in: context, name: "Evening")

    let config = TriggerConfigurationModel()
    try config.loadFromProfile(profile, in: context)
    config.startTriggers.schedule = true
    config.stopConditions.schedule = true
    config.startSchedule = ProfileScheduleTime(days: [.monday], hour: 21, minute: 0, updatedAt: now)
    config.stopSchedule = ProfileScheduleTime(days: [.monday], hour: 7, minute: 0, updatedAt: now)

    config.saveToProfile(profile)

    let snapshot = SharedData.snapshot(for: profile.id.uuidString)
    XCTAssertEqual(snapshot?.startTriggersSchedule, true)
    XCTAssertEqual(snapshot?.startSchedule?.hour, 21)
    XCTAssertEqual(snapshot?.startSchedule?.minute, 0)
  }

  func testGivenProfileWithStopSchedule_WhenTriggerConfigSaved_ThenSnapshotContainsStopSchedule()
    throws
  {
    let now = Date()
    let profile = try BlockedProfiles.createProfile(in: context, name: "Evening")

    let config = TriggerConfigurationModel()
    try config.loadFromProfile(profile, in: context)
    config.startTriggers.schedule = true
    config.stopConditions.schedule = true
    config.startSchedule = ProfileScheduleTime(days: [.monday], hour: 21, minute: 0, updatedAt: now)
    config.stopSchedule = ProfileScheduleTime(days: [.monday], hour: 7, minute: 30, updatedAt: now)

    config.saveToProfile(profile)

    let snapshot = SharedData.snapshot(for: profile.id.uuidString)
    XCTAssertEqual(snapshot?.stopConditionsSchedule, true)
    XCTAssertEqual(snapshot?.stopSchedule?.hour, 7)
    XCTAssertEqual(snapshot?.stopSchedule?.minute, 30)
  }

  func testGivenExistingProfileScheduleEdited_WhenTriggerConfigSaved_ThenSnapshotReflectsNewTime()
    throws
  {
    let now = Date()
    let profile = try BlockedProfiles.createProfile(in: context, name: "Evening")

    let config = TriggerConfigurationModel()
    try config.loadFromProfile(profile, in: context)
    config.startTriggers.schedule = true
    config.stopConditions.schedule = true
    config.startSchedule = ProfileScheduleTime(days: [.monday], hour: 21, minute: 0, updatedAt: now)
    config.stopSchedule = ProfileScheduleTime(days: [.monday], hour: 7, minute: 0, updatedAt: now)
    config.saveToProfile(profile)

    // User edits the start time in a later editing session
    config.startSchedule = ProfileScheduleTime(days: [.monday], hour: 22, minute: 30, updatedAt: now)
    config.saveToProfile(profile)

    let snapshot = SharedData.snapshot(for: profile.id.uuidString)
    XCTAssertEqual(snapshot?.startSchedule?.hour, 22)
    XCTAssertEqual(snapshot?.startSchedule?.minute, 30)
  }
  func testGivenLegacyEditor_WhenSafetyEnabledAndTriggerFormSaved_ThenMigratedConfigurationSurvives() throws {
    let now = Date()
    let profile = BlockedProfiles(
      name: "Legacy", createdAt: now, updatedAt: now,
      blockingStrategyId: NFCBlockingStrategy.id, physicalUnblockNFCTagId: "nfc-test",
      schedule: BlockedProfileSchedule(days: [.monday], startHour: 9, startMinute: 0, endHour: 17, endMinute: 0, updatedAt: now))
    profile.profileSchemaVersion = 1
    context.insert(profile)
    try context.save()
    let config = TriggerConfigurationModel()
    try config.loadFromProfile(profile, in: context)
    _ = try BlockedProfiles.updateProfile(profile, in: context, now: now, blockAdultWebsites: true)
    config.saveToProfile(profile)
    try context.save()
    XCTAssertEqual(profile.profileSchemaVersion, 2)
    XCTAssertTrue(profile.startTriggers.anyNFC)
    XCTAssertTrue(profile.stopConditions.specificNFC)
    XCTAssertEqual(profile.stopNFCTagId, "nfc-test")
    XCTAssertEqual(profile.startSchedule?.hour, 9)
    XCTAssertEqual(profile.stopSchedule?.hour, 17)
    let snapshot = try XCTUnwrap(SharedData.snapshot(for: profile.id.uuidString))
    XCTAssertEqual(snapshot.startTriggersSchedule, true)
    XCTAssertEqual(snapshot.stopConditions?.specificNFC, true)
    XCTAssertEqual(snapshot.startSchedule?.hour, 9)
    XCTAssertEqual(snapshot.blockAdultWebsites, true)

    // A deliberate edit after loading the migrated form remains authoritative.
    config.startTriggers.anyNFC = false
    config.startTriggers.manual = true
    config.saveToProfile(profile)
    XCTAssertTrue(profile.startTriggers.manual)
    XCTAssertFalse(profile.startTriggers.anyNFC)
  }

  func testGivenActiveLegacyEditor_WhenBlockingEndsAndReloads_ThenMigrationIsDeferredUntilReload() throws {
    let now = Date()
    let profile = BlockedProfiles(
      name: "Legacy", createdAt: now, updatedAt: now,
      blockingStrategyId: QRCodeBlockingStrategy.id)
    profile.profileSchemaVersion = 1
    context.insert(profile)
    try context.save()
    let config = TriggerConfigurationModel()
    try config.loadFromProfile(profile, in: context, hasActiveSession: true)
    XCTAssertEqual(profile.profileSchemaVersion, 1)
    try config.loadFromProfile(profile, in: context, hasActiveSession: false)
    XCTAssertEqual(profile.profileSchemaVersion, 2)
    XCTAssertTrue(config.startTriggers.anyQR)
    XCTAssertTrue(config.stopConditions.sameQR)
    XCTAssertTrue(config.hasLoadedProfile)
  }

  func testGivenMigrationCannotSave_WhenLoadRetried_ThenBothAttemptsFailAndFormStaysUnavailable() throws {
    let now = Date()
    let schema = Schema([BlockedProfiles.self, BlockedProfileSession.self, SavedLocation.self])
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("profiles.store")
    let id = UUID()
    do {
      let writable = try ModelContainer(
        for: schema,
        configurations: [
          ModelConfiguration(
            schema: schema, url: url, cloudKitDatabase: .none)
        ])
      let writeContext = ModelContext(writable)
      let profile = BlockedProfiles(id: id, name: "Legacy", createdAt: now, updatedAt: now)
      profile.profileSchemaVersion = 1
      writeContext.insert(profile)
      try writeContext.save()
    }
    let readOnlyContainer = try ModelContainer(
      for: schema,
      configurations: [
        ModelConfiguration(
          schema: schema, url: url, allowsSave: false, cloudKitDatabase: .none)
      ])
    let readOnlyContext = readOnlyContainer.mainContext
    let profile = try XCTUnwrap(BlockedProfiles.findProfile(byID: id, in: readOnlyContext))
    let config = TriggerConfigurationModel()
    let previous = BlockedProfiles(name: "Previously loaded", createdAt: now, updatedAt: now)
    context.insert(previous)
    try context.save()
    try config.loadFromProfile(previous, in: context)
    XCTAssertTrue(config.hasLoadedProfile)
    XCTAssertThrowsError(try config.loadFromProfile(profile, in: readOnlyContext))
    XCTAssertEqual(profile.profileSchemaVersion, 2)
    XCTAssertFalse(config.hasLoadedProfile)
    XCTAssertThrowsError(try config.loadFromProfile(profile, in: readOnlyContext))
    XCTAssertFalse(config.hasLoadedProfile)
  }

}
