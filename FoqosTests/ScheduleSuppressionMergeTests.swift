import FoqosShared
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class ScheduleSuppressionMergeTests: XCTestCase {
  private var container: ModelContainer!
  private var context: ModelContext!
  private var suiteName: String!

  override func setUp() async throws {
    try await super.setUp()
    suiteName = "ScheduleSuppressionMergeTests-\(UUID().uuidString)"
    SharedData.configure(suite: UserDefaults(suiteName: suiteName)!)
    container = try TestModelContainer.create()
    context = container.mainContext
  }

  override func tearDown() async throws {
    UserDefaults().removePersistentDomain(forName: suiteName)
    try await super.tearDown()
  }

  func testGivenExtensionWroteLaterStop_WhenMerging_ThenSwiftDataTakesSnapshotValue() throws {
    let now = Date()
    let earlier = now.addingTimeInterval(-3600)
    let profile = BlockedProfiles(name: "Sched")
    profile.scheduleLastStoppedAt = earlier
    context.insert(profile)
    try context.save()
    BlockedProfiles.updateSnapshot(for: profile)
    SharedData.setLastStoppedAt(for: profile.id.uuidString, at: now)

    PreActivationReminderScheduler.mergeExtensionScheduleSuppression(context: context)

    XCTAssertEqual(
      profile.scheduleLastStoppedAt, now,
      "SwiftData adopts the extension's later stop (#243)")
  }

  func testGivenSwiftDataNewerThanSnapshot_WhenMerging_ThenSwiftDataUnchanged() throws {
    let now = Date()
    let older = now.addingTimeInterval(-3600)
    let profile = BlockedProfiles(name: "Sched")
    profile.scheduleLastStoppedAt = now
    context.insert(profile)
    try context.save()
    BlockedProfiles.updateSnapshot(for: profile)
    SharedData.setLastStoppedAt(for: profile.id.uuidString, at: older)

    PreActivationReminderScheduler.mergeExtensionScheduleSuppression(context: context)

    XCTAssertEqual(profile.scheduleLastStoppedAt, now, "max() keeps the newer SwiftData value")
  }
}
