import CloudKit
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class ProfileSyncAccountResolverTests: XCTestCase {
  var suiteName: String!
  var bufferSuiteName: String!
  var defaults: UserDefaults!
  var bufferDefaults: UserDefaults!
  var container: ModelContainer!
  var manager: ProfileSyncManager!
  var savedEnabled = false
  var savedIsSyncReady = false
  var savedController: (any SyncEngineControlling)?
  var savedBufferDefaults: UserDefaults!
  let recA = CKRecord.ID(recordName: "userA")
  let recB = CKRecord.ID(recordName: "userB")

  override func setUp() async throws {
    try await super.setUp()
    suiteName = "ProfileSyncAccountResolverTests-\(UUID().uuidString)"
    bufferSuiteName = "ProfileSyncAccountResolverTests-buffer-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)!
    bufferDefaults = UserDefaults(suiteName: bufferSuiteName)!
    SharedData.configure(suite: defaults)
    container = try TestModelContainer.create()
    manager = ProfileSyncManager.shared
    savedEnabled = manager.isEnabled
    savedIsSyncReady = manager.isSyncReady
    savedController = manager.engineController
    savedBufferDefaults = manager.bufferDefaults
    manager.bufferDefaults = bufferDefaults
    manager.engineController = nil
    manager.isSyncReady = false
    manager.isEnabled = false
    manager.clearAccountChangeStateForTest()
  }

  override func tearDown() async throws {
    manager.engineController = savedController
    manager.isSyncReady = savedIsSyncReady
    manager.isEnabled = savedEnabled
    manager.bufferDefaults = savedBufferDefaults
    manager.clearAccountChangeStateForTest()
    UserDefaults().removePersistentDomain(forName: bufferSuiteName)
    UserDefaults().removePersistentDomain(forName: suiteName)
    try await super.tearDown()
  }

  func testAvailabilityMapping() {
    let recordID = CKRecord.ID(recordName: "user-A")

    XCTAssertEqual(
      AccountAvailability(from: .available, recordID: recordID, error: nil),
      .available(recordID))
    XCTAssertEqual(
      AccountAvailability(from: .noAccount, recordID: nil, error: nil),
      .noAccount)
    XCTAssertEqual(
      AccountAvailability(from: .couldNotDetermine, recordID: nil, error: nil),
      .ambiguous)
    XCTAssertEqual(
      AccountAvailability(from: .temporarilyUnavailable, recordID: nil, error: nil),
      .ambiguous)
    XCTAssertEqual(
      AccountAvailability(from: .restricted, recordID: nil, error: nil),
      .ambiguous)
    XCTAssertEqual(
      AccountAvailability(from: .available, recordID: recordID, error: CKError(.networkUnavailable)),
      .ambiguous)
  }

  func testConfirmedSameUserRestartsWhenDisabled() async throws {
    try await makeAttachedManager(namespace: "userA", isEnabled: true, engineState: .disabled)

    manager.resolveAccountChange(availability: .available(recA), newName: "userA")

    XCTAssertNil(manager.accountChangeConflict)
    XCTAssertNil(manager.syncPausedReason)
    XCTAssertTrue(manager.didCallStartForTest)
  }

  func testConfirmedSameUserPurgedDoesNotRestart() async throws {
    try await makeAttachedManager(namespace: "userA", isEnabled: true, engineState: .purged)

    manager.resolveAccountChange(availability: .available(recA), newName: "userA")

    XCTAssertFalse(manager.didCallStartForTest)
  }

  func testConfirmedNoAccountPauses() async throws {
    try await makeAttachedManager(namespace: "userA", isEnabled: true, engineState: .steady)

    manager.resolveAccountChange(availability: .noAccount, newName: nil)

    XCTAssertEqual(manager.syncPausedReason, .signedOut)
    XCTAssertNil(manager.accountChangeConflict)
  }

  func testAmbiguousNeitherPausesNorPrompts() async throws {
    try await makeAttachedManager(namespace: "userA", isEnabled: true, engineState: .steady)

    manager.resolveAccountChange(availability: .ambiguous, newName: nil)

    XCTAssertNil(manager.syncPausedReason)
    XCTAssertNil(manager.accountChangeConflict)
    XCTAssertFalse(manager.didTearDownForTest)
  }

  func testSentinelTreatedAsAmbiguousNeverPrompts() async throws {
    try await makeAttachedManager(namespace: "userA", isEnabled: true, engineState: .steady)

    manager.resolveAccountChange(availability: .available(nil), newName: "__default_user__")

    XCTAssertNil(manager.accountChangeConflict)
    XCTAssertNil(manager.syncPausedReason)
  }

  func testConfirmedDifferentUserTearsDownAndPublishesConflict() async throws {
    try await makeAttachedManager(namespace: "userA", isEnabled: true, engineState: .steady)

    manager.resolveAccountChange(availability: .available(recB), newName: "userB")

    XCTAssertEqual(manager.accountChangeConflict?.newUserRecordName, "userB")
    XCTAssertEqual(manager.syncPausedReason, .accountChanged)
    XCTAssertTrue(manager.didTearDownForTest)
    XCTAssertFalse(manager.isSyncReady)
  }

  private func makeAttachedManager(
    namespace: String, isEnabled: Bool, engineState: SyncEngineState
  ) async throws {
    manager.engineController = nil
    manager.isEnabled = false
    manager.isSyncReady = false
    let driver = MockSyncEngineDriver()
    await manager.attachEngine(
      modelContext: container.mainContext,
      emergencyManager: EmergencyUnblockManager(defaults: defaults),
      userRecordNameProvider: { namespace },
      driverFactory: { _ in driver })
    manager.isEnabled = isEnabled
    if isEnabled {
      await (manager.engineController as? SyncEngineController)?.startupTask?.value
    }
    (manager.engineController as? SyncEngineController)?.forceStateForTest(engineState)
    manager.resetAccountChangeDebugCountersForTest()
  }
}
