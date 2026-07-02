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
    config.loadFromProfile(profile)
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
    config.loadFromProfile(profile)
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
    config.loadFromProfile(profile)
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
}
