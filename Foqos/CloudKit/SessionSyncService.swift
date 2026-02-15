import CloudKit
import Foundation
import os

/// Manages session state synchronization using CloudKit with CAS (Compare-And-Swap).
/// Ensures only one authoritative session record exists per profile.
actor SessionSyncService {
  static let shared = SessionSyncService()

  // MARK: - CloudKit Configuration

  private lazy var container: CKContainer = {
    CKContainer(identifier: CloudKitConstants.containerIdentifier)
  }()

  private var privateDatabase: CKDatabase {
    container.privateCloudDatabase
  }

  private var syncZoneID: CKRecordZone.ID {
    CKRecordZone.ID(zoneName: CloudKitConstants.syncZoneName, ownerName: CKCurrentUserDefaultName)
  }

  private var deviceId: String {
    SharedData.deviceSyncId.uuidString
  }

  // MARK: - Local Cache

  /// Cached session records, keyed by profile ID
  private var cachedRecords: [UUID: (record: CKRecord, session: ProfileSessionRecord)] = [:]

  // MARK: - Result Types

  enum StartResult {
    case started(sequenceNumber: Int)
    case alreadyActive(session: ProfileSessionRecord)
    case error(Error)
  }

  enum StopResult {
    case stopped(sequenceNumber: Int)
    case alreadyStopped
    case conflict(currentSession: ProfileSessionRecord)
    case error(Error)
  }

  enum FetchResult {
    case found(ProfileSessionRecord)
    case notFound
    case error(Error)
  }

  // MARK: - Fetch Operations

  /// Fetch the current session record for a profile
  func fetchSession(profileId: UUID) async -> FetchResult {
    let recordName = ProfileSessionRecord.recordName(for: profileId)
    let recordID = CKRecord.ID(recordName: recordName, zoneID: syncZoneID)

    do {
      let record = try await privateDatabase.record(for: recordID)
      guard let session = ProfileSessionRecord(from: record) else {
        return .error(SessionSyncError.invalidRecord)
      }

      // Cache for CAS operations
      cachedRecords[profileId] = (record, session)

      return .found(session)
    } catch let error as CKError {
      if error.code == .unknownItem {
        return .notFound
      }
      return .error(error)
    } catch {
      return .error(error)
    }
  }

  // MARK: - Start Session (with CAS)

  private static let maxCASRetries = 3

  /// Attempt to start a session. Uses CAS with iterative retry loop.
  func startSession(profileId: UUID, startTime: Date = Date()) async -> StartResult {
    for attempt in 0..<Self.maxCASRetries {
      // Backoff with jitter on retries (not on first attempt)
      if attempt > 0 {
        let baseDelay = UInt64(100_000_000 * (attempt + 1))  // 200ms, 300ms
        let jitter = UInt64.random(in: 0...100_000_000)  // 0-100ms
        try? await Task.sleep(nanoseconds: baseDelay + jitter)
        Log.info(
          "CAS retry attempt \(attempt + 1)/\(Self.maxCASRetries) for \(profileId)",
          category: .sync
        )
      }

      // Fetch current state
      let fetchResult = await fetchSession(profileId: profileId)

      switch fetchResult {
      case .found(let existing):
        if existing.isActive {
          Log.info("Session already active for \(profileId), joining", category: .sync)
          return .alreadyActive(session: existing)
        }
        // Session exists but inactive - try to activate it
        guard let cached = cachedRecords[profileId] else {
          return .error(SessionSyncError.noCachedRecord)
        }
        let (existingRecord, existingSession) = cached
        let newSequence = existingSession.sequenceNumber + 1

        var updatedSession = existingSession
        updatedSession.resetForNewSession()
        _ = updatedSession.applyUpdate(
          isActive: true,
          sequenceNumber: newSequence,
          deviceId: deviceId,
          startTime: startTime
        )
        updatedSession.updateCKRecord(existingRecord)

        let saveResult = await attemptCASSave(
          record: existingRecord,
          profileId: profileId,
          newSequence: newSequence
        )
        switch saveResult {
        case .success:
          return .started(sequenceNumber: newSequence)
        case .conflict:
          continue  // Retry the loop
        case .error(let error):
          return .error(error)
        }

      case .notFound:
        // No record exists - create new one
        var session = ProfileSessionRecord(profileId: profileId)
        _ = session.applyUpdate(
          isActive: true,
          sequenceNumber: 1,
          deviceId: deviceId,
          startTime: startTime
        )
        let record = session.toCKRecord(in: syncZoneID)

        let saveResult = await attemptCASSave(
          record: record,
          profileId: profileId,
          newSequence: 1
        )
        switch saveResult {
        case .success:
          return .started(sequenceNumber: 1)
        case .conflict:
          continue  // Retry the loop
        case .error(let error):
          return .error(error)
        }

      case .error(let error):
        return .error(error)
      }
    }

    Log.error(
      "CAS max retries (\(Self.maxCASRetries)) exceeded for \(profileId)",
      category: .sync
    )
    return .error(SessionSyncError.maxRetriesExceeded)
  }

  /// Internal CAS save result (not exposed publicly)
  private enum CASSaveResult {
    case success
    case conflict
    case error(Error)
  }

  /// Attempt a single CAS save. Returns .conflict if server record changed.
  private func attemptCASSave(
    record: CKRecord,
    profileId: UUID,
    newSequence: Int
  ) async -> CASSaveResult {
    do {
      let savedRecord = try await saveRecordWithPolicy(
        record, policy: .ifServerRecordUnchanged)

      if let session = ProfileSessionRecord(from: savedRecord) {
        cachedRecords[profileId] = (savedRecord, session)
      }

      Log.info(
        "CAS save succeeded for \(profileId) with seq=\(newSequence)",
        category: .sync
      )
      return .success
    } catch let error as CKError {
      if error.code == .serverRecordChanged {
        Log.info(
          "CAS conflict for \(profileId), will retry",
          category: .sync
        )
        return .conflict
      }
      return .error(error)
    } catch {
      return .error(error)
    }
  }

  // MARK: - Stop Session (with CAS)

  /// Attempt to stop a session. Uses CAS to handle concurrent stops.
  func stopSession(profileId: UUID, endTime: Date = Date()) async -> StopResult {
    // Fetch current state
    let fetchResult = await fetchSession(profileId: profileId)

    switch fetchResult {
    case .found(let existing):
      if !existing.isActive {
        Log.info("Session already stopped for \(profileId)", category: .sync)
        return .alreadyStopped
      }
      return await deactivateSession(profileId: profileId, endTime: endTime)

    case .notFound:
      // No record - nothing to stop
      return .alreadyStopped

    case .error(let error):
      return .error(error)
    }
  }

  private func deactivateSession(profileId: UUID, endTime: Date) async -> StopResult {
    guard let cached = cachedRecords[profileId] else {
      return .error(SessionSyncError.noCachedRecord)
    }

    let (existingRecord, existingSession) = cached
    let newSequence = existingSession.sequenceNumber + 1

    // Prepare updated record
    var updatedSession = existingSession
    _ = updatedSession.applyUpdate(
      isActive: false,
      sequenceNumber: newSequence,
      deviceId: deviceId,
      endTime: endTime
    )
    updatedSession.updateCKRecord(existingRecord)

    do {
      let savedRecord = try await saveRecordWithPolicy(
        existingRecord, policy: .ifServerRecordUnchanged)

      // Update cache
      if let session = ProfileSessionRecord(from: savedRecord) {
        cachedRecords[profileId] = (savedRecord, session)
      }

      Log.info("Stopped session for \(profileId) with seq=\(newSequence)", category: .sync)
      return .stopped(sequenceNumber: newSequence)

    } catch let error as CKError {
      if error.code == .serverRecordChanged {
        // Conflict - fetch current state
        Log.info("CAS conflict on stop for \(profileId)", category: .sync)
        let refetchResult = await fetchSession(profileId: profileId)

        switch refetchResult {
        case .found(let current):
          if !current.isActive {
            return .alreadyStopped
          }
          return .conflict(currentSession: current)
        case .notFound:
          return .alreadyStopped
        case .error(let fetchError):
          return .error(fetchError)
        }
      }
      return .error(error)
    } catch {
      return .error(error)
    }
  }

  // MARK: - Helper

  private func saveRecordWithPolicy(
    _ record: CKRecord, policy: CKModifyRecordsOperation.RecordSavePolicy
  ) async throws -> CKRecord {
    try await withCheckedThrowingContinuation { continuation in
      let operation = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
      operation.savePolicy = policy
      operation.qualityOfService = .userInitiated

      let hasResumed = OSAllocatedUnfairLock(initialState: false)

      operation.perRecordSaveBlock = { _, result in
        let alreadyResumed = hasResumed.withLock { resumed -> Bool in
          if resumed { return true }
          resumed = true
          return false
        }
        guard !alreadyResumed else { return }
        switch result {
        case .success(let savedRecord):
          continuation.resume(returning: savedRecord)
        case .failure(let error):
          continuation.resume(throwing: error)
        }
      }

      operation.modifyRecordsResultBlock = { result in
        let alreadyResumed = hasResumed.withLock { resumed -> Bool in
          if resumed { return true }
          resumed = true
          return false
        }
        guard !alreadyResumed else { return }
        switch result {
        case .success:
          // For single-record saves, perRecordSaveBlock should fire instead.
          // If we reach here without it, we can't return the updated record.
          continuation.resume(throwing: SessionSyncError.unexpectedState)
        case .failure(let error):
          continuation.resume(throwing: error)
        }
      }

      privateDatabase.add(operation)
    }
  }

  // MARK: - Cache Management

  func clearCache() {
    cachedRecords.removeAll()
  }

  func clearCache(for profileId: UUID) {
    cachedRecords.removeValue(forKey: profileId)
  }
}

// MARK: - Errors

enum SessionSyncError: LocalizedError {
  case noCachedRecord
  case invalidRecord
  case unexpectedState
  case maxRetriesExceeded

  var errorDescription: String? {
    switch self {
    case .noCachedRecord:
      return "No cached record available for CAS operation"
    case .invalidRecord:
      return "CloudKit record could not be parsed"
    case .unexpectedState:
      return "Unexpected state during sync operation"
    case .maxRetriesExceeded:
      return "Failed to sync session after maximum retry attempts"
    }
  }
}
