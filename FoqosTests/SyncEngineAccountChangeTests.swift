import CloudKit
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class SyncEngineAccountChangeTests: XCTestCase {
  var suiteName: String!
  var defaults: UserDefaults!
  var container: ModelContainer!
  var context: ModelContext!
  var store: SyncEngineStore!
  var driver: MockSyncEngineDriver!
  var apply: SyncApplyService!
  var provider: RecordProvider!
  var emergencyManager: EmergencyUnblockManager!
  var sessionSync: MockSessionSyncFlushing!
  let deviceId = "device-A"
  let userRecordName = "user-A"

  override func setUp() async throws {
    try await super.setUp()
    suiteName = "SyncEngineAccountChangeTests-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)!
    SharedData.configure(suite: defaults)
    container = try TestModelContainer.create()
    context = container.mainContext
    store = SyncEngineStore(userRecordName: userRecordName, defaults: defaults)
    driver = MockSyncEngineDriver()
    emergencyManager = EmergencyUnblockManager(defaults: defaults)
    apply = SyncApplyService(
      modelContext: context, store: store, sessionController: MockSessionController(),
      emergencyManager: emergencyManager, deviceId: deviceId)
    provider = RecordProvider(
      modelContext: context, store: store, emergencyManager: emergencyManager, deviceId: deviceId)
    sessionSync = MockSessionSyncFlushing()
  }

  override func tearDown() async throws {
    UserDefaults().removePersistentDomain(forName: suiteName)
    try await super.tearDown()
  }

  func makeController() -> SyncEngineController {
    SyncEngineController(
      modelContext: context,
      store: store,
      driverFactory: { [driver] _ in driver! },
      apply: apply,
      provider: provider,
      sessionSync: sessionSync,
      deviceId: deviceId)
  }

  func testStopTransitionsToDisabled() throws {
    let controller = makeController()

    controller.start()
    XCTAssertNotEqual(controller.state, .disabled)

    controller.stop()

    XCTAssertEqual(controller.state, .disabled)
  }
}
