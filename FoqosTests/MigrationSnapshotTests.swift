import FoqosShared
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class MigrationSnapshotTests: XCTestCase {

  private var container: ModelContainer!
  private var context: ModelContext!
  private var testSuiteName: String!

  override func setUp() async throws {
    try await super.setUp()
    testSuiteName = "MigrationSnapshotTests-\(UUID().uuidString)"
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

  func testGivenV1ScheduledProfile_WhenMigrated_ThenAppGroupSnapshotContainsV2Schedule() throws {
    let now = Date()
    let profile = BlockedProfiles(
      name: "School",
      blockingStrategyId: ManualBlockingStrategy.id,
      schedule: BlockedProfileSchedule(
        days: [.monday],
        startHour: 9,
        startMinute: 0,
        endHour: 15,
        endMinute: 30,
        updatedAt: now
      )
    )
    profile.profileSchemaVersion = 1
    context.insert(profile)
    try context.save()
    BlockedProfiles.updateSnapshot(for: profile)

    ProfileMigrationUtil.migrateProfilesIfNeeded(context: context)

    XCTAssertFalse(profile.needsMigration)
    let snapshot = SharedData.snapshot(for: profile.id.uuidString)
    XCTAssertEqual(snapshot?.startTriggersSchedule, true)
    XCTAssertEqual(snapshot?.stopConditionsSchedule, true)
    XCTAssertEqual(snapshot?.startSchedule?.hour, 9)
    XCTAssertEqual(snapshot?.stopSchedule?.hour, 15)
  }
  func testActiveV1DefersUntilSessionEndThenPublishesPersistedV3() throws {
    let now = Date()
    let profile = BlockedProfiles(name: "Active legacy", createdAt: now, updatedAt: now, blockingStrategyId: "NFCTimerBlockingStrategy", strategyData: try JSONEncoder().encode(StrategyTimerData(durationInMinutes: 37)), physicalUnblockNFCTagId: "A0FF")
    profile.profileSchemaVersion = 1
    context.insert(profile)
    let session = BlockedProfileSession.createSession(in: context, withTag: "nfc:A0FF", withProfile: profile, startTime: now)
    try context.save()
    BlockedProfiles.updateSnapshot(for: profile)
    let oldSnapshot = SharedData.snapshot(for: profile.id.uuidString)
    let oldSession = SharedData.activeSharedSession
    XCTAssertEqual(ProfileMigrationUtil.migrateProfilesIfNeeded(context: context), 0)
    XCTAssertEqual(profile.profileSchemaVersion, 1)
    XCTAssertNil(profile.startTriggersData)
    XCTAssertNil(profile.stopConditionsData)
    XCTAssertEqual(profile.physicalUnblockNFCTagId, "A0FF")
    XCTAssertNil(session.endTime)
    XCTAssertEqual(SharedData.snapshot(for: profile.id.uuidString), oldSnapshot)
    XCTAssertEqual(SharedData.activeSharedSession, oldSession)
    session.endTime = now.addingTimeInterval(60)
    try context.save()
    XCTAssertEqual(ProfileMigrationUtil.migrateProfilesIfNeeded(context: context), 1)
    let durable = try XCTUnwrap(BlockedProfiles.findProfile(byID: profile.id, in: ModelContext(container)))
    XCTAssertEqual(durable.profileSchemaVersion, 3)
    XCTAssertEqual(durable.stopNFCTagIds, ["A0FF"])
    XCTAssertEqual(durable.stopConditions.timerDurationMinutes, 37)
    XCTAssertEqual(SharedData.snapshot(for: profile.id.uuidString)?.stopConditions, durable.stopConditions)
  }

  func testMigrationSaveFailureRestoresVersionBlobsAndTags() throws {
    let now = Date()
    let schema = Schema([BlockedProfiles.self, BlockedProfileSession.self, SavedLocation.self, SavedTag.self])
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("migration.store")
    let id = UUID()
    do {
      let writable = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
      let writeContext = ModelContext(writable)
      let profile = BlockedProfiles(id: id, name: "Legacy", createdAt: now, updatedAt: now, physicalUnblockNFCTagId: "A0FF")
      profile.profileSchemaVersion = 1
      writeContext.insert(profile)
      try writeContext.save()
    }
    let readOnly = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url, allowsSave: false, cloudKitDatabase: .none)])
    let readContext = readOnly.mainContext
    let profile = try XCTUnwrap(BlockedProfiles.findProfile(byID: id, in: readContext))
    BlockedProfiles.updateSnapshot(for: profile)
    let snapshot = SharedData.snapshot(for: id.uuidString)
    XCTAssertThrowsError(try profile.migrateIfEligible(hasActiveSession: false))
    XCTAssertEqual(profile.profileSchemaVersion, 1)
    XCTAssertNil(profile.startTriggersData)
    XCTAssertNil(profile.stopConditionsData)
    XCTAssertNil(profile.startScheduleData)
    XCTAssertNil(profile.stopScheduleData)
    XCTAssertEqual(profile.physicalUnblockNFCTagId, "A0FF")
    XCTAssertTrue(profile.stopNFCTagIds.isEmpty)
    XCTAssertTrue(try SavedTag.fetchAll(in: readContext).isEmpty)
    XCTAssertEqual(SharedData.snapshot(for: id.uuidString), snapshot)
  }

}
