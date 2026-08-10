import Combine
import XCTest

@testable import FamilyFoqos

@MainActor
final class SyncEngineFacadeTests: XCTestCase {
  var testSuiteName: String!
  var manager: ProfileSyncManager!
  var mock: MockSyncEngineControlling!
  private var savedEnabled = false
  private var savedIsSyncReady = false
  private var savedController: (any SyncEngineControlling)?
  private var savedBufferDefaults: UserDefaults!
  private var bufferSuiteName: String!
  private var bufferDefaults: UserDefaults!

  override func setUp() async throws {
    try await super.setUp()
    testSuiteName = "SyncEngineFacadeTests-\(UUID().uuidString)"
    SharedData.configure(suite: UserDefaults(suiteName: testSuiteName)!)
    manager = ProfileSyncManager.shared
    savedEnabled = manager.isEnabled
    savedIsSyncReady = manager.isSyncReady
    savedController = manager.engineController
    savedBufferDefaults = manager.bufferDefaults
    bufferSuiteName = "SyncEngineFacadeTests-buffer-\(UUID().uuidString)"
    bufferDefaults = UserDefaults(suiteName: bufferSuiteName)!
    manager.bufferDefaults = bufferDefaults
    manager.isSyncReady = false
    manager.isEnabled = false
    mock = MockSyncEngineControlling()
    manager.engineController = mock
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

  func testGivenController_WhenToggledOn_ThenStartIsCalledAndPersisted() {
    manager.isEnabled = true

    XCTAssertEqual(mock.startCount, 1)
    XCTAssertEqual(mock.stopCount, 0)
    XCTAssertTrue(SharedData.deviceSyncEnabled)
    XCTAssertEqual(manager.syncStatusSnapshot.status, .synced)
  }

  func testGivenController_WhenToggledOffAfterOn_ThenStopIsCalled() {
    manager.isEnabled = true
    manager.isEnabled = false

    XCTAssertEqual(mock.startCount, 1)
    XCTAssertEqual(mock.stopCount, 1)
    XCTAssertFalse(SharedData.deviceSyncEnabled)
    XCTAssertEqual(manager.syncStatusSnapshot.status, .disabled)
  }

  func testGivenController_WhenFacadeVerbsCalled_ThenTheyForward() throws {
    let id = UUID()
    let now = Date()
    let event = SyncedEmergencyUnblockEvent(
      id: UUID(), deviceId: "device-A", consumedAt: now, resetEpoch: 1)
    manager.isSyncReady = true

    try manager.syncNow()
    try manager.resetSync(clearRemoteAppSelections: true)
    try manager.enqueueProfileSave(id)
    try manager.enqueueProfileDelete(id)
    try manager.enqueueLocationSave(id)
    try manager.enqueueLocationDelete(id)
    try manager.enqueueEmergencySettingsSave()
    try manager.enqueueEmergencyUnblockEvent(event)
    try manager.enqueueEmergencyEpochSave()
    try manager.enqueueEmergencyUnblockEventDelete(event.recordName)

    XCTAssertEqual(
      mock.requestSyncCount, 9,
      "syncNow (1) + eight enqueue verbs each flush once when ready (8)")
    XCTAssertEqual(mock.beginResetCalls, [true])
    XCTAssertEqual(mock.enqueuedProfileSaves, [id])
    XCTAssertEqual(mock.enqueuedProfileDeletes, [id])
    XCTAssertEqual(mock.enqueuedLocationSaves, [id])
    XCTAssertEqual(mock.enqueuedLocationDeletes, [id])
    XCTAssertEqual(mock.enqueuedEmergencySaves, 1)
    XCTAssertEqual(mock.enqueuedEmergencyUnblockEvents, [event])
    XCTAssertEqual(mock.enqueuedEmergencyEpochSaves, 1)
    XCTAssertEqual(mock.enqueuedEmergencyUnblockEventDeletes, [event.recordName])
  }

  func testGivenWipeReset_WhenForwarded_ThenControllerReceivesWipeFlag() throws {
    try manager.resetSync(wipe: true, clearRemoteAppSelections: false)

    XCTAssertEqual(mock.beginResetWipeFlags, [true])
    XCTAssertEqual(mock.beginResetCalls, [false])
  }

  func testGivenController_WhenRecordDisabledTombstone_ThenForwardedToController() {
    manager.isEnabled = false

    manager.recordDisabledDeleteTombstone(recordName: "p1")

    XCTAssertEqual(mock.recordedDisabledTombstones, ["p1"])
  }

  func testGivenNoController_WhenRecordDisabledTombstone_ThenNoCrashNoForward() {
    manager.engineController = nil

    manager.recordDisabledDeleteTombstone(recordName: "p1")

    XCTAssertEqual(mock.recordedDisabledTombstones, [])
    XCTAssertEqual(PreAttachDeleteBuffer.drainAll(defaults: bufferDefaults), ["p1"])
  }

  func testGivenReadyController_WhenEnqueueProfileSave_ThenRequestSyncIsScheduled() throws {
    manager.isSyncReady = true
    let id = UUID()

    try manager.enqueueProfileSave(id)

    XCTAssertEqual(mock.enqueuedProfileSaves, [id], "the save is forwarded to the engine")
    XCTAssertEqual(
      mock.requestSyncCount, 1,
      "a ready engine flushes a user-initiated save promptly, not on the next foreground")
  }

  func testGivenNotAttached_WhenEnqueueProfileSave_ThenIdIsDeferredAndReEnqueuedOnReady() throws {
    let id = UUID()
    manager.engineController = nil

    XCTAssertThrowsError(try manager.enqueueProfileSave(id)) { error in
      XCTAssertEqual(error as? SyncEngineControllingError, .notAttached)
    }

    let attached = MockSyncEngineControlling()
    manager.engineController = attached
    manager.markSyncReadyAndFlush()

    XCTAssertEqual(attached.enqueuedProfileSaves, [id], "the dropped save is retried on attach")
    XCTAssertEqual(attached.requestSyncCount, 1, "exactly one flush covers all drained mutations")
    XCTAssertTrue(manager.hasNoDeferredMutations, "the deferred sets are cleared after draining")
  }

  func testGivenNotAttached_WhenEnqueueLocationSave_ThenIdIsDeferredAndReEnqueuedOnReady() throws {
    let id = UUID()
    manager.engineController = nil

    XCTAssertThrowsError(try manager.enqueueLocationSave(id)) { error in
      XCTAssertEqual(error as? SyncEngineControllingError, .notAttached)
    }

    let attached = MockSyncEngineControlling()
    manager.engineController = attached
    manager.markSyncReadyAndFlush()

    XCTAssertEqual(attached.enqueuedLocationSaves, [id], "the dropped location save is retried on attach")
    XCTAssertEqual(attached.requestSyncCount, 1, "exactly one flush covers all drained mutations")
    XCTAssertTrue(manager.hasNoDeferredMutations, "the deferred sets are cleared after draining")
  }

  func testGivenNotAttached_WhenEnqueueEmergencySettingsSave_ThenSaveIsDeferredAndReEnqueuedOnReady()
    throws
  {
    manager.engineController = nil

    XCTAssertThrowsError(try manager.enqueueEmergencySettingsSave()) { error in
      XCTAssertEqual(error as? SyncEngineControllingError, .notAttached)
    }

    let attached = MockSyncEngineControlling()
    manager.engineController = attached
    manager.markSyncReadyAndFlush()

    XCTAssertEqual(attached.enqueuedEmergencySaves, 1, "the dropped emergency save is retried on attach")
    XCTAssertEqual(attached.requestSyncCount, 1, "exactly one flush covers all drained mutations")
    XCTAssertTrue(manager.hasNoDeferredMutations, "the deferred sets are cleared after draining")
  }

  func testGivenNotAttached_WhenEnqueueEmergencyUnblockEvent_ThenEventIsDeferredAndReEnqueuedOnReady()
    throws
  {
    let now = Date()
    let event = SyncedEmergencyUnblockEvent(
      id: UUID(), deviceId: "device-A", consumedAt: now, resetEpoch: 1)
    manager.engineController = nil

    XCTAssertThrowsError(try manager.enqueueEmergencyUnblockEvent(event)) { error in
      XCTAssertEqual(error as? SyncEngineControllingError, .notAttached)
    }

    let attached = MockSyncEngineControlling()
    manager.engineController = attached
    manager.markSyncReadyAndFlush()

    XCTAssertEqual(attached.enqueuedEmergencyUnblockEvents, [event])
    XCTAssertEqual(attached.requestSyncCount, 1, "exactly one flush covers all drained mutations")
    XCTAssertTrue(manager.hasNoDeferredMutations, "the deferred sets are cleared after draining")
  }

  func testGivenNotAttached_WhenEnqueueEmergencyEpochSave_ThenSaveIsDeferredAndReEnqueuedOnReady()
    throws
  {
    manager.engineController = nil

    XCTAssertThrowsError(try manager.enqueueEmergencyEpochSave()) { error in
      XCTAssertEqual(error as? SyncEngineControllingError, .notAttached)
    }

    let attached = MockSyncEngineControlling()
    manager.engineController = attached
    manager.markSyncReadyAndFlush()

    XCTAssertEqual(attached.enqueuedEmergencyEpochSaves, 1)
    XCTAssertEqual(attached.requestSyncCount, 1, "exactly one flush covers all drained mutations")
    XCTAssertTrue(manager.hasNoDeferredMutations, "the deferred sets are cleared after draining")
  }

  func testGivenNotAttached_WhenEnqueueEmergencyUnblockEventDelete_ThenDeleteIsReplayedOnReady()
    throws
  {
    let recordName = SyncedEmergencyUnblockEvent.recordNamePrefix + UUID().uuidString
    manager.engineController = nil

    XCTAssertThrowsError(try manager.enqueueEmergencyUnblockEventDelete(recordName)) { error in
      XCTAssertEqual(error as? SyncEngineControllingError, .notAttached)
    }

    let attached = MockSyncEngineControlling()
    manager.engineController = attached
    manager.markSyncReadyAndFlush()

    XCTAssertEqual(
      attached.deferredDeletes,
      [recordName],
      "a GC delete dropped before attach is replayed through the existing deferred-delete path")
    XCTAssertEqual(attached.requestSyncCount, 1)
    XCTAssertTrue(manager.hasNoDeferredMutations)
  }

  func testGivenNotAttached_WhenEnqueueProfileDelete_ThenDeleteIsBufferedDurably() throws {
    let id = UUID()
    manager.engineController = nil

    XCTAssertThrowsError(try manager.enqueueProfileDelete(id)) { error in
      XCTAssertEqual(error as? SyncEngineControllingError, .notAttached)
    }

    XCTAssertEqual(Set(PreAttachDeleteBuffer.drainAll(defaults: bufferDefaults)), [id.uuidString])

    let attached = MockSyncEngineControlling()
    manager.engineController = attached
    manager.markSyncReadyAndFlush()

    XCTAssertEqual(attached.deferredDeletes, [id.uuidString])
    XCTAssertTrue(manager.hasNoDeferredMutations)
  }

  func testGivenNotAttached_WhenEnqueueLocationDelete_ThenDeleteIsBufferedDurably() throws {
    let id = UUID()
    manager.engineController = nil

    XCTAssertThrowsError(try manager.enqueueLocationDelete(id)) { error in
      XCTAssertEqual(error as? SyncEngineControllingError, .notAttached)
    }

    XCTAssertEqual(Set(PreAttachDeleteBuffer.drainAll(defaults: bufferDefaults)), [id.uuidString])

    let attached = MockSyncEngineControlling()
    manager.engineController = attached
    manager.markSyncReadyAndFlush()

    XCTAssertEqual(attached.deferredDeletes, [id.uuidString])
    XCTAssertTrue(manager.hasNoDeferredMutations)
  }

  func testGivenNotAttached_WhenEnqueueProfileDelete_ThenTombstoneDeleteIsReplayedOnReady() throws {
    let id = UUID()
    manager.engineController = nil

    XCTAssertThrowsError(try manager.enqueueProfileDelete(id)) { error in
      XCTAssertEqual(error as? SyncEngineControllingError, .notAttached)
    }

    let attached = MockSyncEngineControlling()
    manager.engineController = attached
    manager.markSyncReadyAndFlush()

    XCTAssertEqual(
      attached.deferredDeletes,
      [id.uuidString],
      "a profile delete dropped before attach is replayed as a tombstone delete")
    XCTAssertEqual(attached.requestSyncCount, 1)
    XCTAssertTrue(manager.hasNoDeferredMutations)
  }

  func testGivenNotAttached_WhenEnqueueLocationDelete_ThenTombstoneDeleteIsReplayedOnReady() throws {
    let id = UUID()
    manager.engineController = nil

    XCTAssertThrowsError(try manager.enqueueLocationDelete(id)) { error in
      XCTAssertEqual(error as? SyncEngineControllingError, .notAttached)
    }

    let attached = MockSyncEngineControlling()
    manager.engineController = attached
    manager.markSyncReadyAndFlush()

    XCTAssertEqual(
      attached.deferredDeletes,
      [id.uuidString],
      "a location delete dropped before attach is replayed as a tombstone delete")
    XCTAssertEqual(attached.requestSyncCount, 1)
    XCTAssertTrue(manager.hasNoDeferredMutations)
  }

  func testGivenNotReady_WhenEnqueueProfileSave_ThenNoSendUntilReadyFlush() throws {
    manager.isSyncReady = false
    let id = UUID()

    try manager.enqueueProfileSave(id)
    XCTAssertEqual(mock.enqueuedProfileSaves, [id], "the change is enqueued")
    XCTAssertEqual(
      mock.requestSyncCount, 0,
      "no send may fire before the engine is ready; restored poison must be T1-stripped first (AB-4)")

    manager.markSyncReadyAndFlush()
    XCTAssertEqual(mock.requestSyncCount, 1, "the post-startup flush sends exactly once, post-T1")
  }

  func testGivenNotReady_WhenAnyFacadeEnqueueVerbRuns_ThenNoSendIsScheduled() throws {
    manager.isSyncReady = false
    let id = UUID()
    let now = Date()
    let event = SyncedEmergencyUnblockEvent(
      id: UUID(), deviceId: "device-A", consumedAt: now, resetEpoch: 1)

    try manager.enqueueProfileSave(id)
    try manager.enqueueProfileDelete(id)
    try manager.enqueueLocationSave(id)
    try manager.enqueueLocationDelete(id)
    try manager.enqueueEmergencySettingsSave()
    try manager.enqueueEmergencyUnblockEvent(event)
    try manager.enqueueEmergencyEpochSave()
    try manager.enqueueEmergencyUnblockEventDelete(event.recordName)

    XCTAssertEqual(mock.enqueuedProfileSaves, [id])
    XCTAssertEqual(mock.enqueuedProfileDeletes, [id])
    XCTAssertEqual(mock.enqueuedLocationSaves, [id])
    XCTAssertEqual(mock.enqueuedLocationDeletes, [id])
    XCTAssertEqual(mock.enqueuedEmergencySaves, 1)
    XCTAssertEqual(mock.enqueuedEmergencyUnblockEvents, [event])
    XCTAssertEqual(mock.enqueuedEmergencyEpochSaves, 1)
    XCTAssertEqual(mock.enqueuedEmergencyUnblockEventDeletes, [event.recordName])
    XCTAssertEqual(
      mock.requestSyncCount, 0,
      "no facade enqueue verb may send before startup completes and T1 has stripped restored state")
  }

  func testGivenSyncDisabled_WhenStartupCompletes_ThenReadyFlushIsSkipped() {
    manager.isEnabled = false

    manager.markSyncReadyAndFlushIfStillEnabled(for: mock)

    XCTAssertFalse(manager.isSyncReady)
    XCTAssertEqual(mock.requestSyncCount, 0)
  }

  // MARK: - Review fix: not-attached and genuine-throw propagation (findings #2–#6, #15)

  func testGivenNoEngineController_WhenSyncNow_ThenThrowsNotAttachedInsteadOfSilentNoOp() {
    manager.engineController = nil

    XCTAssertThrowsError(try manager.syncNow()) { error in
      XCTAssertEqual(error as? SyncEngineControllingError, .notAttached)
    }
  }

  func testGivenNoEngineController_WhenResetSync_ThenThrowsNotAttachedInsteadOfSilentNoOp() {
    manager.engineController = nil

    XCTAssertThrowsError(try manager.resetSync(clearRemoteAppSelections: false)) { error in
      XCTAssertEqual(error as? SyncEngineControllingError, .notAttached)
    }
  }

  func testGivenNoEngineController_WhenEnqueueProfileDelete_ThenThrowsNotAttachedInsteadOfSilentNoOp() {
    manager.engineController = nil

    XCTAssertThrowsError(try manager.enqueueProfileDelete(UUID())) { error in
      XCTAssertEqual(error as? SyncEngineControllingError, .notAttached)
    }
  }

  func testGivenEngineThrowsGenuineError_WhenEnqueueProfileDelete_ThenFacadePropagatesIt() {
    mock.errorToThrow = MutationFunnel.MutationFunnelError.entityNotFound

    XCTAssertThrowsError(try manager.enqueueProfileDelete(UUID())) { error in
      XCTAssertEqual(error as? MutationFunnel.MutationFunnelError, .entityNotFound)
    }
    XCTAssertTrue(mock.enqueuedProfileDeletes.isEmpty, "the throw must not be swallowed as a silent success")
  }
}
