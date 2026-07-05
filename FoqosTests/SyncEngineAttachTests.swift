import CloudKit
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class SyncEngineAttachTests: XCTestCase {
  var testSuiteName: String!
  var container: ModelContainer!
  var manager: ProfileSyncManager!
  private var savedEnabled = false
  private var savedController: (any SyncEngineControlling)?

  override func setUp() async throws {
    try await super.setUp()
    testSuiteName = "SyncEngineAttachTests-\(UUID().uuidString)"
    SharedData.configure(suite: UserDefaults(suiteName: testSuiteName)!)
    container = try TestModelContainer.create()
    manager = ProfileSyncManager.shared
    savedEnabled = manager.isEnabled
    savedController = manager.engineController
  }

  override func tearDown() async throws {
    manager.engineController = savedController
    manager.isEnabled = savedEnabled
    UserDefaults().removePersistentDomain(forName: testSuiteName)
    try await super.tearDown()
  }

  func testGivenContext_WhenAttachEngine_ThenControllerConstructedStartedAndWired() async throws {
    manager.isEnabled = true
    let driver = CutoverRecordingDriver(stateSerialization: nil)

    await manager.attachEngine(
      modelContext: container.mainContext,
      emergencyManager: EmergencyUnblockManager(),
      userRecordNameProvider: { "user-attach-A" },
      driverFactory: { _ in driver })

    XCTAssertNotNil(manager.engineController)  // I10: built only with a context
    // start() ran because isEnabled — first bootstrap seeds the zone.
    XCTAssertTrue(driver.enqueuedZoneSaveNames.contains(CloudKitConstants.syncZoneName))
  }

  func testGivenSyncDisabled_WhenAttachEngine_ThenControllerWiredButNotStarted() async throws {
    manager.isEnabled = false
    let driver = CutoverRecordingDriver(stateSerialization: nil)

    await manager.attachEngine(
      modelContext: container.mainContext,
      emergencyManager: EmergencyUnblockManager(),
      userRecordNameProvider: { "user-attach-B" },
      driverFactory: { _ in driver })

    XCTAssertNotNil(manager.engineController)
    XCTAssertTrue(driver.enqueuedZoneSaveNames.isEmpty)  // start() not called
  }
}
