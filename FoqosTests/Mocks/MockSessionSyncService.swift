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

  /// Number of times to simulate CAS conflicts before succeeding
  var simulateConflictCount = 0

  /// §6 opt-in: on stop of an absent record, create a stopped record create-if-absent.
  var stopOnAbsentCreatesRecord = false
  /// §6 opt-in: a concurrent fresh active start won the create race — the stop yields.
  var freshStartWinsRace = false

  func fetchSession(profileId: UUID) async -> SessionSyncService.FetchResult {
    if simulatedDelay > 0 {
      try? await Task.sleep(nanoseconds: simulatedDelay * 1_000_000)
    }

    if let session = records[profileId] {
      return .found(session)
    }
    return .notFound
  }

  func startSession(profileId: UUID, startTime: Date, deviceId: String) async
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
        isActive: true, sequenceNumber: 1, deviceId: "other-device", startTime: startTime)
      records[profileId] = winner
      return .alreadyActive(session: winner)
    }

    if simulateConflictCount > 0 {
      simulateConflictCount -= 1
      // Simulate conflict: another device won the race, session is already active
      var winner = records[profileId] ?? ProfileSessionRecord(profileId: profileId)
      let newSeq = winner.sequenceNumber + 1
      _ = winner.applyUpdate(
        isActive: true, sequenceNumber: newSeq, deviceId: "conflict-device", startTime: startTime)
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

  func stopSession(profileId: UUID, endTime: Date, deviceId: String) async
    -> SessionSyncService.StopResult
  {
    if simulatedDelay > 0 {
      try? await Task.sleep(nanoseconds: simulatedDelay * 1_000_000)
    }

    guard var session = records[profileId], session.isActive else {
      if stopOnAbsentCreatesRecord && records[profileId] == nil {
        if freshStartWinsRace {
          var winner = ProfileSessionRecord(profileId: profileId)
          _ = winner.applyUpdate(
            isActive: true, sequenceNumber: 1, deviceId: "other-device", startTime: endTime)
          records[profileId] = winner
          return .alreadyStopped
        }
        var created = ProfileSessionRecord(profileId: profileId)
        _ = created.applyUpdate(
          isActive: false, sequenceNumber: 1, deviceId: deviceId, endTime: endTime)
        records[profileId] = created
        return .stopped(sequenceNumber: 1)
      }
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
    simulateConflictCount = 0
  }

  /// Model an I6 zone recreation: the server zone is fresh, so any prior record is gone and
  /// the next write must be create-if-absent. Mirrors the real service flushing its cache
  /// (Task 102) so the first CAS after recreation goes down the .notFound create path.
  func simulateZoneRecreated() {
    records.removeAll()
  }

  func setSimulateConflictOnce(_ value: Bool) {
    simulateConflictOnce = value
  }

  func setSimulateConflictCount(_ value: Int) {
    simulateConflictCount = value
  }

  func setStopOnAbsentCreatesRecord(_ value: Bool) {
    stopOnAbsentCreatesRecord = value
  }

  func setFreshStartWinsRace(_ value: Bool) {
    freshStartWinsRace = value
  }

  func stopOnAbsentDebugRecord(for profileId: UUID) -> ProfileSessionRecord? {
    records[profileId]
  }
}
