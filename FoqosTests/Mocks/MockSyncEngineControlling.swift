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

  func start() { startCount += 1 }
  func stop() { stopCount += 1 }
  func requestSync() { requestSyncCount += 1 }
  func beginReset(clearRemoteAppSelections: Bool) { beginResetCalls.append(clearRemoteAppSelections) }
  func enqueueProfileSave(_ id: UUID) { enqueuedProfileSaves.append(id) }
  func enqueueProfileDelete(_ id: UUID) { enqueuedProfileDeletes.append(id) }
  func enqueueLocationSave(_ id: UUID) { enqueuedLocationSaves.append(id) }
  func enqueueLocationDelete(_ id: UUID) { enqueuedLocationDeletes.append(id) }
  func enqueueEmergencySettingsSave() { enqueuedEmergencySaves += 1 }
}
