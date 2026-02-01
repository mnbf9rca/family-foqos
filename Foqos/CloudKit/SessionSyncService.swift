import CloudKit
import Foundation

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
    let recordName = "ProfileSession_\(profileId.uuidString)"
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

  /// Attempt to start a session. Uses CAS to handle concurrent starts.
  func startSession(profileId: UUID, startTime: Date = Date()) async -> StartResult {
    // First, fetch current state
    let fetchResult = await fetchSession(profileId: profileId)

    switch fetchResult {
    case .found(let existing):
      if existing.isActive {
        // Session already active - join it instead of creating new
        print("SessionSyncService: Session already active for \(profileId), joining")
        return .alreadyActive(session: existing)
      }
      // Session exists but inactive - try to activate it
      return await activateExistingSession(profileId: profileId, startTime: startTime)

    case .notFound:
      // No record exists - create new one
      return await createNewSession(profileId: profileId, startTime: startTime)

    case .error(let error):
      return .error(error)
    }
  }

  private func activateExistingSession(profileId: UUID, startTime: Date) async -> StartResult {
    guard let cached = cachedRecords[profileId] else {
      return .error(SessionSyncError.noCachedRecord)
    }

    let (existingRecord, existingSession) = cached
    let newSequence = existingSession.sequenceNumber + 1

    // Prepare updated record
    var updatedSession = existingSession
    updatedSession.resetForNewSession()
    _ = updatedSession.applyUpdate(
      isActive: true,
      sequenceNumber: newSequence,
      deviceId: deviceId,
      startTime: startTime
    )
    updatedSession.updateCKRecord(existingRecord)

    // Attempt CAS save
    return await saveWithCAS(
      record: existingRecord,
      profileId: profileId,
      newSequence: newSequence,
      isStart: true,
      startTime: startTime
    )
  }

  private func createNewSession(profileId: UUID, startTime: Date) async -> StartResult {
    var session = ProfileSessionRecord(profileId: profileId)
    _ = session.applyUpdate(
      isActive: true,
      sequenceNumber: 1,
      deviceId: deviceId,
      startTime: startTime
    )

    let record = session.toCKRecord(in: syncZoneID)

    // Attempt save (will fail if another device created first)
    return await saveWithCAS(
      record: record,
      profileId: profileId,
      newSequence: 1,
      isStart: true,
      startTime: startTime
    )
  }

  private func saveWithCAS(
    record: CKRecord,
    profileId: UUID,
    newSequence: Int,
    isStart: Bool,
    startTime: Date? = nil
  ) async -> StartResult {
    do {
      let savedRecord = try await saveRecordWithPolicy(record, policy: .ifServerRecordUnchanged)

      // Update cache
      if let session = ProfileSessionRecord(from: savedRecord) {
        cachedRecords[profileId] = (savedRecord, session)
      }

      print(
        "SessionSyncService: \(isStart ? "Started" : "Updated") session for \(profileId) with seq=\(newSequence)"
      )
      return .started(sequenceNumber: newSequence)

    } catch let error as CKError {
      if error.code == .serverRecordChanged {
        // Another device won the race - fetch their version and join
        print("SessionSyncService: CAS conflict for \(profileId), fetching winner's session")
        let refetchResult = await fetchSession(profileId: profileId)

        switch refetchResult {
        case .found(let winnerSession):
          if winnerSession.isActive {
            return .alreadyActive(session: winnerSession)
          } else {
            // Winner's session is stopped - retry our start
            return await activateExistingSession(
              profileId: profileId, startTime: startTime ?? Date())
          }
        case .notFound:
          return .error(SessionSyncError.unexpectedState)
        case .error(let fetchError):
          return .error(fetchError)
        }
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
        print("SessionSyncService: Session already stopped for \(profileId)")
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

      print("SessionSyncService: Stopped session for \(profileId) with seq=\(newSequence)")
      return .stopped(sequenceNumber: newSequence)

    } catch let error as CKError {
      if error.code == .serverRecordChanged {
        // Conflict - fetch current state
        print("SessionSyncService: CAS conflict on stop for \(profileId)")
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

      var hasResumed = false

      operation.perRecordSaveBlock = { recordID, result in
        guard !hasResumed else { return }
        hasResumed = true
        switch result {
        case .success(let savedRecord):
          continuation.resume(returning: savedRecord)
        case .failure(let error):
          continuation.resume(throwing: error)
        }
      }

      operation.modifyRecordsResultBlock = { result in
        // Only handle if perRecordSaveBlock didn't fire
        guard !hasResumed else { return }
        hasResumed = true
        switch result {
        case .success:
          continuation.resume(returning: record)
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

  var errorDescription: String? {
    switch self {
    case .noCachedRecord:
      return "No cached record available for CAS operation"
    case .invalidRecord:
      return "CloudKit record could not be parsed"
    case .unexpectedState:
      return "Unexpected state during sync operation"
    }
  }
}
