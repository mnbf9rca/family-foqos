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
}
