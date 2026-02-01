import Foundation

@testable import FamilyFoqos

/// Mock implementation for testing session sync without CloudKit
actor MockSessionSyncService {

  /// Simulated CloudKit storage
  private var records: [UUID: ProfileSessionRecord] = [:]

  /// Simulate network delay (ms)
  var simulatedDelay: UInt64 = 0

  /// Simulate CAS conflict on next operation
  var simulateConflictOnce = false

  func fetchSession(profileId: UUID) async -> SessionSyncService.FetchResult {
    if simulatedDelay > 0 {
      try? await Task.sleep(nanoseconds: simulatedDelay * 1_000_000)
    }

    if let session = records[profileId] {
      return .found(session)
    }
    return .notFound
  }

  func startSession(profileId: UUID, startTime: Date = Date(), deviceId: String) async
    -> SessionSyncService.StartResult
  {
    if simulatedDelay > 0 {
      try? await Task.sleep(nanoseconds: simulatedDelay * 1_000_000)
    }

    if simulateConflictOnce {
      simulateConflictOnce = false
      // Simulate another device winning
      var winner = ProfileSessionRecord(profileId: profileId)
      _ = winner.applyUpdate(
        isActive: true, sequenceNumber: 1, deviceId: "other-device", startTime: Date())
      records[profileId] = winner
      return .alreadyActive(session: winner)
    }

    if let existing = records[profileId], existing.isActive {
      return .alreadyActive(session: existing)
    }

    var session = records[profileId] ?? ProfileSessionRecord(profileId: profileId)
    let newSeq = session.sequenceNumber + 1
    session.resetForNewSession()
    _ = session.applyUpdate(
      isActive: true, sequenceNumber: newSeq, deviceId: deviceId, startTime: startTime)
    records[profileId] = session

    return .started(sequenceNumber: newSeq)
  }

  func stopSession(profileId: UUID, endTime: Date = Date(), deviceId: String) async
    -> SessionSyncService.StopResult
  {
    if simulatedDelay > 0 {
      try? await Task.sleep(nanoseconds: simulatedDelay * 1_000_000)
    }

    guard var session = records[profileId], session.isActive else {
      return .alreadyStopped
    }

    let newSeq = session.sequenceNumber + 1
    _ = session.applyUpdate(
      isActive: false, sequenceNumber: newSeq, deviceId: deviceId, endTime: endTime)
    records[profileId] = session

    return .stopped(sequenceNumber: newSeq)
  }

  func reset() {
    records.removeAll()
    simulateConflictOnce = false
  }

  func setSimulateConflictOnce(_ value: Bool) {
    simulateConflictOnce = value
  }
}
