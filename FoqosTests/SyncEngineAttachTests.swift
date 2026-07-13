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
  private var savedIsSyncReady = false
  private var savedController: (any SyncEngineControlling)?
  private var savedBufferDefaults: UserDefaults!
  private var bufferSuiteName: String!
  private var bufferDefaults: UserDefaults!

  override func setUp() async throws {
    try await super.setUp()
    testSuiteName = "SyncEngineAttachTests-\(UUID().uuidString)"
    SharedData.configure(suite: UserDefaults(suiteName: testSuiteName)!)
    container = try TestModelContainer.create()
    manager = ProfileSyncManager.shared
    savedEnabled = manager.isEnabled
    savedIsSyncReady = manager.isSyncReady
    savedController = manager.engineController
    savedBufferDefaults = manager.bufferDefaults
    bufferSuiteName = "SyncEngineAttachTests-buffer-\(UUID().uuidString)"
    bufferDefaults = UserDefaults(suiteName: bufferSuiteName)!
    manager.bufferDefaults = bufferDefaults
    manager.isSyncReady = false
  }

  override func tearDown() async throws {
    manager.engineController = savedController
    manager.isSyncReady = savedIsSyncReady
    manager.isEnabled = savedEnabled
    manager.bufferDefaults = savedBufferDefaults
    UserDefaults().removePersistentDomain(forName: bufferSuiteName)
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

  func testGivenPreAttachDeleteBuffer_WhenAttachEngine_ThenDrainedIntoStoreTombstone() async throws {
    manager.isEnabled = false
    let driver = CutoverRecordingDriver(stateSerialization: nil)
    let recordName = "pre-attach-\(UUID().uuidString)"
    let userRecordName = "user-attach-buffer-\(UUID().uuidString)"
    PreAttachDeleteBuffer.add(recordName, defaults: bufferDefaults)

    await manager.attachEngine(
      modelContext: container.mainContext,
      emergencyManager: EmergencyUnblockManager(),
      userRecordNameProvider: { userRecordName },
      driverFactory: { _ in driver })

    XCTAssertTrue(PreAttachDeleteBuffer.drainAll(defaults: bufferDefaults).isEmpty)
    let store = SyncEngineStore(userRecordName: userRecordName)
    XCTAssertTrue(
      store.deleteTombstones.keys.contains(recordName),
      "#305: attach must promote buffered pre-attach deletes into store tombstones")
    store.clearTombstone(recordName: recordName)
  }

  func testGivenPreAttachDeleteBufferedForAnotherUser_WhenAttachEngine_ThenEntrySurvivesForOriginalUser()
    async throws
  {
    manager.isEnabled = false
    let recordName = "pre-attach-\(UUID().uuidString)"
    let userA = "user-attach-buffer-A-\(UUID().uuidString)"
    let userB = "user-attach-buffer-B-\(UUID().uuidString)"
    PreAttachDeleteBuffer.add(recordName, userRecordName: userA, defaults: bufferDefaults)

    await manager.attachEngine(
      modelContext: container.mainContext,
      emergencyManager: EmergencyUnblockManager(),
      userRecordNameProvider: { userB },
      driverFactory: { _ in CutoverRecordingDriver(stateSerialization: nil) })

    let storeB = SyncEngineStore(userRecordName: userB)
    XCTAssertFalse(
      storeB.deleteTombstones.keys.contains(recordName),
      "a delete buffered under user A must not become a tombstone for user B")
    XCTAssertEqual(
      PreAttachDeleteBuffer.pending(defaults: bufferDefaults).map(\.recordName),
      [recordName],
      "mismatched provenance must remain pending for a later matching attach")

    manager.engineController = nil
    await manager.attachEngine(
      modelContext: container.mainContext,
      emergencyManager: EmergencyUnblockManager(),
      userRecordNameProvider: { userA },
      driverFactory: { _ in CutoverRecordingDriver(stateSerialization: nil) })

    let storeA = SyncEngineStore(userRecordName: userA)
    XCTAssertTrue(
      storeA.deleteTombstones.keys.contains(recordName),
      "the original user's later attach must promote its buffered delete")
    XCTAssertTrue(PreAttachDeleteBuffer.pending(defaults: bufferDefaults).isEmpty)
    storeA.clearTombstone(recordName: recordName)
  }

  func testGivenEngineAttachedWhileDisabled_WhenSyncEnabledLater_ThenStartupMarksReadyAndDrainsDeferredDelete()
    async throws
  {
    manager.isEnabled = false
    let driver = CutoverRecordingDriver(stateSerialization: nil)

    await manager.attachEngine(
      modelContext: container.mainContext,
      emergencyManager: EmergencyUnblockManager(),
      userRecordNameProvider: { "user-attach-enable-later" },
      driverFactory: { _ in driver })

    let id = UUID()
    XCTAssertThrowsError(try manager.enqueueProfileDelete(id)) { error in
      XCTAssertEqual(error as? SyncEngineControllingError, .notAttached)
    }

    manager.isEnabled = true
    let controller = try XCTUnwrap(manager.engineController as? SyncEngineController)
    await controller.startupTask?.value

    XCTAssertTrue(manager.isSyncReady)
    XCTAssertTrue(manager.hasNoDeferredMutations)
    XCTAssertTrue(
      driver.enqueuedDeleteNames.contains(id.uuidString),
      "the deferred delete is replayed after enable-time startup completes")
    XCTAssertGreaterThan(driver.sendChangesCount, 0, "ready flush sends after T1 has completed")
  }
}
