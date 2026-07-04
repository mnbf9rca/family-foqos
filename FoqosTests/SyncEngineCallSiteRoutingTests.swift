import CloudKit
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class SyncEngineCallSiteRoutingTests: XCTestCase {
  var testSuiteName: String!
  var container: ModelContainer!
  var manager: ProfileSyncManager!
  var driver: CutoverRecordingDriver!
  private var savedEnabled = false
  private var savedController: (any SyncEngineControlling)?

  override func setUp() async throws {
    try await super.setUp()
    testSuiteName = "SyncEngineCallSiteRoutingTests-\(UUID().uuidString)"
    SharedData.configure(suite: UserDefaults(suiteName: testSuiteName)!)
    container = try TestModelContainer.create()
    manager = ProfileSyncManager.shared
    savedEnabled = manager.isEnabled
    savedController = manager.engineController
    manager.isEnabled = true
    driver = CutoverRecordingDriver(stateSerialization: nil)
    await manager.attachEngine(
      modelContext: container.mainContext,
      emergencyManager: EmergencyUnblockManager(),
      userRecordNameProvider: { "user-routing-A" },
      driverFactory: { [driver] _ in driver! })
  }

  override func tearDown() async throws {
    manager.engineController = savedController
    manager.isEnabled = savedEnabled
    UserDefaults().removePersistentDomain(forName: testSuiteName)
    try await super.tearDown()
  }

  func testGivenStartedEngine_WhenFacadeEnqueuesProfileSave_ThenDriverReceivesSave() throws {
    let now = Date()
    let profile = BlockedProfiles(id: UUID(), name: "P", createdAt: now, updatedAt: now)
    container.mainContext.insert(profile)
    try container.mainContext.save()
    let before = driver.enqueuedSaveNames.filter { $0 == profile.id.uuidString }.count

    try manager.enqueueProfileSave(profile.id)

    let after = driver.enqueuedSaveNames.filter { $0 == profile.id.uuidString }.count
    XCTAssertEqual(after, before + 1)
  }

  func testGivenStartedEngine_WhenSyncNow_ThenFetchScheduled() throws {
    let before = driver.fetchChangesCount
    try manager.syncNow()
    XCTAssertEqual(driver.fetchChangesCount, before + 1)
  }

  // MARK: - Review fix: engine-not-attached surfaces instead of silent no-op (findings #2–#6)

  func testGivenNoEngineAttached_WhenEnqueueProfileDelete_ThenThrowsNotAttached() {
    manager.engineController = nil

    XCTAssertThrowsError(try manager.enqueueProfileDelete(UUID())) { error in
      XCTAssertEqual(error as? SyncEngineControllingError, .notAttached)
    }
  }

  func testGivenNoEngineAttached_WhenSyncNow_ThenThrowsNotAttached() {
    manager.engineController = nil

    XCTAssertThrowsError(try manager.syncNow()) { error in
      XCTAssertEqual(error as? SyncEngineControllingError, .notAttached)
    }
  }
}
