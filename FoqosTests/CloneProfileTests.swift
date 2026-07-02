import SwiftData
import XCTest

@testable import FamilyFoqos

/// Regression tests for issues #209 and #223 in BlockedProfiles.cloneProfile:
/// - #209: the clone must get its own SharedData snapshot so the FoqosDeviceMonitor
///   extension can resolve it when its DeviceActivity schedule fires.
/// - #223: cloning an unmigrated V1 profile must not stamp the clone as V2 with
///   all-false triggers; the clone must carry migrated, startable triggers.
@MainActor
final class CloneProfileTests: XCTestCase {

  private var container: ModelContainer!
  private var context: ModelContext!
  private var testSuiteName: String!

  override func setUp() async throws {
    try await super.setUp()
    testSuiteName = "CloneProfileTests-\(UUID().uuidString)"
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

  private func makeScheduledProfile(now: Date) throws -> BlockedProfiles {
    let profile = try BlockedProfiles.createProfile(in: context, name: "School Hours")
    var startTriggers = profile.startTriggers
    startTriggers.schedule = true
    profile.startTriggers = startTriggers
    var stopConditions = profile.stopConditions
    stopConditions.schedule = true
    profile.stopConditions = stopConditions
    profile.startSchedule = ProfileScheduleTime(days: [.monday], hour: 21, minute: 0, updatedAt: now)
    profile.stopSchedule = ProfileScheduleTime(days: [.monday], hour: 7, minute: 0, updatedAt: now)
    try context.save()
    return profile
  }

  // MARK: - #209: clone snapshot

  func testGivenScheduledProfile_WhenCloned_ThenCloneSnapshotExists() throws {
    let now = Date()
    let source = try makeScheduledProfile(now: now)

    let cloned = try BlockedProfiles.cloneProfile(source, in: context, newName: "School Hours Copy")

    let snapshot = SharedData.snapshot(for: cloned.id.uuidString)
    XCTAssertNotNil(snapshot, "Clone must have a SharedData snapshot so extensions can read it")
    XCTAssertEqual(snapshot?.id, cloned.id)
    XCTAssertEqual(snapshot?.name, "School Hours Copy")
  }

  func testGivenScheduledProfile_WhenCloned_ThenCloneSnapshotReflectsTriggerSchedule() throws {
    let now = Date()
    let source = try makeScheduledProfile(now: now)

    let cloned = try BlockedProfiles.cloneProfile(source, in: context, newName: "School Hours Copy")

    let snapshot = SharedData.snapshot(for: cloned.id.uuidString)
    XCTAssertEqual(snapshot?.startTriggersSchedule, true)
    XCTAssertEqual(snapshot?.startSchedule?.hour, 21)
    XCTAssertEqual(snapshot?.stopConditionsSchedule, true)
    XCTAssertEqual(snapshot?.stopSchedule?.hour, 7)
  }

  func testGivenScheduledProfile_WhenCloned_ThenSourceSnapshotUntouched() throws {
    let now = Date()
    let source = try makeScheduledProfile(now: now)

    _ = try BlockedProfiles.cloneProfile(source, in: context, newName: "School Hours Copy")

    let sourceSnapshot = SharedData.snapshot(for: source.id.uuidString)
    XCTAssertEqual(sourceSnapshot?.id, source.id)
    XCTAssertEqual(sourceSnapshot?.name, "School Hours")
  }

  // MARK: - #223: cloning an unmigrated V1 profile

  func testGivenUnmigratedV1NFCProfile_WhenCloned_ThenCloneIsV2WithMigratedTriggers() throws {
    let source = BlockedProfiles(name: "V1 NFC")
    source.profileSchemaVersion = 1
    source.blockingStrategyId = "NFCBlockingStrategy"
    context.insert(source)
    try context.save()

    let cloned = try BlockedProfiles.cloneProfile(source, in: context, newName: "V1 NFC Copy")

    XCTAssertEqual(cloned.profileSchemaVersion, 2)
    XCTAssertTrue(cloned.startTriggers.anyNFC, "NFC strategy must migrate to NFC start trigger")
    XCTAssertTrue(cloned.stopConditions.sameNFC, "NFC strategy must migrate to same-NFC stop")
    XCTAssertTrue(cloned.stopConditions.isValid, "Clone must be startable")
  }

  func testGivenUnmigratedV1PhysicalUnlockProfile_WhenCloned_ThenCloneGetsSpecificNFCStop() throws {
    let source = BlockedProfiles(name: "V1 Physical")
    source.profileSchemaVersion = 1
    source.blockingStrategyId = "NFCManualBlockingStrategy"
    source.physicalUnblockNFCTagId = "tag-123"
    context.insert(source)
    try context.save()

    let cloned = try BlockedProfiles.cloneProfile(source, in: context, newName: "V1 Physical Copy")

    XCTAssertTrue(cloned.stopConditions.specificNFC)
    XCTAssertEqual(cloned.stopNFCTagId, "tag-123")
  }

  func testGivenUnmigratedV1Profile_WhenCloned_ThenSourceRemainsV1() throws {
    let source = BlockedProfiles(name: "V1 NFC")
    source.profileSchemaVersion = 1
    source.blockingStrategyId = "NFCBlockingStrategy"
    context.insert(source)
    try context.save()

    _ = try BlockedProfiles.cloneProfile(source, in: context, newName: "V1 NFC Copy")

    XCTAssertEqual(source.profileSchemaVersion, 1, "Cloning must not migrate the source")
    XCTAssertTrue(source.needsMigration, "Source must stay eligible for the normal migration pass")
  }

  func testGivenV2ProfileWithManualTriggers_WhenCloned_ThenTriggersCopiedUnchanged() throws {
    let source = try BlockedProfiles.createProfile(in: context, name: "Manual")
    var startTriggers = source.startTriggers
    startTriggers.manual = true
    source.startTriggers = startTriggers
    var stopConditions = source.stopConditions
    stopConditions.manual = true
    source.stopConditions = stopConditions
    try context.save()

    let cloned = try BlockedProfiles.cloneProfile(source, in: context, newName: "Manual Copy")

    XCTAssertEqual(cloned.profileSchemaVersion, 2)
    XCTAssertTrue(cloned.startTriggers.manual)
    XCTAssertTrue(cloned.stopConditions.manual)
  }
}
