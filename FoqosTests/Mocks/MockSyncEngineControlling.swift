import Foundation

@testable import FamilyFoqos

@MainActor
final class MockSyncEngineControlling: SyncEngineControlling {
  private(set) var startCount = 0
  private(set) var stopCount = 0
  private(set) var requestSyncCount = 0
  private(set) var beginResetCalls: [Bool] = []
  private(set) var enqueuedProfileSaves: [UUID] = []
  private(set) var enqueuedProfileDeletes: [UUID] = []
  private(set) var enqueuedLocationSaves: [UUID] = []
  private(set) var enqueuedLocationDeletes: [UUID] = []
  private(set) var enqueuedEmergencySaves = 0
  private(set) var enqueuedEmergencyUnblockEvents: [SyncedEmergencyUnblockEvent] = []
  private(set) var enqueuedEmergencyEpochSaves = 0
  private(set) var enqueuedEmergencyUnblockEventDeletes: [String] = []
  private(set) var deferredDeletes: [String] = []
  private(set) var recordedDisabledTombstones: [String] = []

  /// Set by a test to make every `enqueue*` verb below throw instead of recording — used to
  /// verify a genuine funnel throw propagates through the facade instead of being swallowed
  /// (review finding #15) and that `.notAttached` specifically drives delete call sites to
  /// their local-delete fallback (review findings #4–#6).
  var errorToThrow: Error?

  func start() { startCount += 1 }
  func stop() { stopCount += 1 }
  func requestSync() { requestSyncCount += 1 }
  func beginReset(clearRemoteAppSelections: Bool) { beginResetCalls.append(clearRemoteAppSelections) }
  func enqueueProfileSave(_ id: UUID) throws {
    if let errorToThrow { throw errorToThrow }
    enqueuedProfileSaves.append(id)
  }
  func enqueueProfileDelete(_ id: UUID) throws {
    try enqueueProfileDelete(id, requestSyncAfterPendingDelete: false)
  }
  func enqueueProfileDelete(_ id: UUID, requestSyncAfterPendingDelete: Bool) throws {
    if let errorToThrow { throw errorToThrow }
    enqueuedProfileDeletes.append(id)
    if requestSyncAfterPendingDelete { requestSync() }
  }
  func enqueueLocationSave(_ id: UUID) throws {
    if let errorToThrow { throw errorToThrow }
    enqueuedLocationSaves.append(id)
  }
  func enqueueLocationDelete(_ id: UUID) throws {
    if let errorToThrow { throw errorToThrow }
    enqueuedLocationDeletes.append(id)
  }
  func enqueueEmergencySettingsSave() throws {
    if let errorToThrow { throw errorToThrow }
    enqueuedEmergencySaves += 1
  }
  func enqueueEmergencyUnblockEvent(_ event: SyncedEmergencyUnblockEvent) throws {
    if let errorToThrow { throw errorToThrow }
    enqueuedEmergencyUnblockEvents.append(event)
  }
  func enqueueEmergencyEpochSave() throws {
    if let errorToThrow { throw errorToThrow }
    enqueuedEmergencyEpochSaves += 1
  }
  func enqueueEmergencyUnblockEventDelete(_ recordName: String) throws {
    if let errorToThrow { throw errorToThrow }
    enqueuedEmergencyUnblockEventDeletes.append(recordName)
  }
  func enqueueDeferredDelete(recordName: String) {
    deferredDeletes.append(recordName)
  }
  func recordDisabledDeleteTombstone(recordName: String) {
    recordedDisabledTombstones.append(recordName)
  }
}
