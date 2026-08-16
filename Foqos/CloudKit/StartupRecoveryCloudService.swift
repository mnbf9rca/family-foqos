import CloudKit
import Foundation

enum StartupRecoveryMembershipObservation: Equatable {
  case accountUnavailable
  case accountIndeterminate
  case zoneListSucceededWithoutPolicyZone(ownerUserRecordName: String)
  case sharedZoneIndeterminate
  case recordAbsent(ownerUserRecordName: String)
  case recordFetchFailed
  case recordZoneMissing
  case recordRole(role: String, ownerUserRecordName: String)
}

enum StartupRecoveryProfileFetchOutcome: Equatable {
  case success
  case zoneListSucceededWithoutSyncZone
  case zoneFetchReportedMissing
  case indeterminate
}

struct StartupRecoveryProfileRecordFold: Equatable {
  private var profileRecordNames: Set<String> = []

  var profileCount: Int { profileRecordNames.count }

  mutating func applyModification(recordName: String, recordType: String) {
    guard recordType == SyncedProfile.recordType else { return }
    profileRecordNames.insert(recordName)
  }

  mutating func applyDeletion(recordName: String, recordType: String) {
    guard recordType == SyncedProfile.recordType else { return }
    profileRecordNames.remove(recordName)
  }
}

final class StartupRecoveryCloudService: @unchecked Sendable {  // SAFETY: Immutable CKContainer; each lookup keeps mutable state call-local
  private let container: CKContainer

  init(
    container: CKContainer = CKContainer(identifier: CloudKitConstants.containerIdentifier)
  ) {
    self.container = container
  }

  static func resolveMembership(
    _ observation: StartupRecoveryMembershipObservation
  ) -> StartupRecoveryMembershipResult {
    switch observation {
    case .zoneListSucceededWithoutPolicyZone(let ownerUserRecordName),
      .recordAbsent(let ownerUserRecordName):
      return .confirmedNone(ownerUserRecordName: ownerUserRecordName)
    case .recordRole(let roleValue, let ownerUserRecordName):
      guard let role = FamilyRole(rawValue: roleValue) else { return .indeterminate }
      return .member(role: role, ownerUserRecordName: ownerUserRecordName)
    case .accountUnavailable, .accountIndeterminate, .sharedZoneIndeterminate,
      .recordFetchFailed, .recordZoneMissing:
      return .indeterminate
    }
  }

  static func resolveProfileCount(
    fold: StartupRecoveryProfileRecordFold,
    outcome: StartupRecoveryProfileFetchOutcome
  ) -> StartupRecoveryProfileCountResult {
    switch outcome {
    case .success:
      return .confirmed(fold.profileCount)
    case .zoneListSucceededWithoutSyncZone:
      return .confirmed(0)
    case .zoneFetchReportedMissing, .indeterminate:
      return .indeterminate
    }
  }

  func lookupMembership() async -> StartupRecoveryMembershipResult {
    let accountStatus: CKAccountStatus
    do {
      accountStatus = try await container.accountStatus()
    } catch {
      Log.error(
        "Startup recovery could not determine the iCloud account state: \(redactedErrorForLog(error))",
        category: .cloudKit)
      return Self.resolveMembership(.accountIndeterminate)
    }

    guard accountStatus == .available else {
      return Self.resolveMembership(.accountUnavailable)
    }

    let userRecordID: CKRecord.ID
    do {
      userRecordID = try await container.userRecordID()
    } catch {
      Log.error(
        "Startup recovery could not identify the iCloud account: \(redactedErrorForLog(error))",
        category: .cloudKit)
      return Self.resolveMembership(.accountIndeterminate)
    }

    let database = container.sharedCloudDatabase
    let policyZoneID: CKRecordZone.ID
    do {
      let zones = try await database.allRecordZones()
      guard
        let matchingZone = zones.first(where: {
          $0.zoneID.zoneName == CloudKitConstants.policyZoneName
        })
      else {
        return Self.resolveMembership(
          .zoneListSucceededWithoutPolicyZone(
            ownerUserRecordName: userRecordID.recordName))
      }
      policyZoneID = matchingZone.zoneID
    } catch {
      Log.error(
        "Startup recovery could not inspect the shared family zone: \(redactedErrorForLog(error))",
        category: .cloudKit)
      return Self.resolveMembership(.sharedZoneIndeterminate)
    }

    var observation = await fetchMembershipObservation(
      in: policyZoneID,
      userRecordName: userRecordID.recordName,
      database: database)
    if observation == .recordZoneMissing {
      observation = await recheckPolicyZoneAfterMissingFetch(
        ownerUserRecordName: userRecordID.recordName,
        database: database)
    }
    return Self.resolveMembership(observation)
  }

  func fetchSyncedProfileCount(
    expectedOwnerUserRecordName: String
  ) async -> StartupRecoveryProfileCountResult {
    do {
      guard try await container.accountStatus() == .available else {
        return .indeterminate
      }
    } catch {
      Log.error(
        "Startup recovery could not determine the profile account state: \(redactedErrorForLog(error))",
        category: .cloudKit)
      return .indeterminate
    }

    do {
      guard
        try await container.userRecordID().recordName == expectedOwnerUserRecordName
      else {
        return .indeterminate
      }
    } catch {
      Log.error(
        "Startup recovery could not verify the profile account: \(redactedErrorForLog(error))",
        category: .cloudKit)
      return .indeterminate
    }

    let zoneID = CKRecordZone.ID(
      zoneName: CloudKitConstants.syncZoneName,
      ownerName: CKCurrentUserDefaultName)
    let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
    configuration.previousServerChangeToken = nil
    configuration.desiredKeys = []

    let operation = CKFetchRecordZoneChangesOperation(
      recordZoneIDs: [zoneID],
      configurationsByRecordZoneID: [zoneID: configuration])
    operation.fetchAllChanges = true
    let accumulator = ProfileFetchAccumulator()

    operation.recordWasChangedBlock = { _, recordResult in
      switch recordResult {
      case .success(let record):
        accumulator.applyModification(
          recordName: record.recordID.recordName,
          recordType: record.recordType)
      case .failure:
        accumulator.markIndeterminate()
      }
    }
    operation.recordWithIDWasDeletedBlock = { recordID, recordType in
      accumulator.applyDeletion(recordName: recordID.recordName, recordType: recordType)
    }
    operation.recordZoneFetchResultBlock = { _, result in
      if case .failure(let error) = result {
        accumulator.recordZoneFailure(error)
      }
    }

    var outcome = await withCheckedContinuation { continuation in
      operation.fetchRecordZoneChangesResultBlock = { result in
        continuation.resume(returning: accumulator.outcome(for: result))
      }
      container.privateCloudDatabase.add(operation)
    }

    if outcome == .zoneFetchReportedMissing {
      do {
        let zones = try await container.privateCloudDatabase.allRecordZones()
        if !zones.contains(where: { $0.zoneID.zoneName == CloudKitConstants.syncZoneName }) {
          outcome = .zoneListSucceededWithoutSyncZone
        } else {
          outcome = .indeterminate
        }
      } catch {
        Log.error(
          "Startup recovery could not recheck the profile zone: \(redactedErrorForLog(error))",
          category: .cloudKit)
        outcome = .indeterminate
      }
    }

    let snapshot = accumulator.foldSnapshot()
    return Self.resolveProfileCount(fold: snapshot, outcome: outcome)
  }

  private func recheckPolicyZoneAfterMissingFetch(
    ownerUserRecordName: String,
    database: CKDatabase
  ) async -> StartupRecoveryMembershipObservation {
    do {
      let zones = try await database.allRecordZones()
      guard
        zones.contains(where: { $0.zoneID.zoneName == CloudKitConstants.policyZoneName })
      else {
        return .zoneListSucceededWithoutPolicyZone(
          ownerUserRecordName: ownerUserRecordName)
      }
      return .recordFetchFailed
    } catch {
      Log.error(
        "Startup recovery could not recheck the shared family zone: \(redactedErrorForLog(error))",
        category: .cloudKit)
      return .sharedZoneIndeterminate
    }
  }

  private func fetchMembershipObservation(
    in zoneID: CKRecordZone.ID,
    userRecordName: String,
    database: CKDatabase
  ) async -> StartupRecoveryMembershipObservation {
    let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
    configuration.previousServerChangeToken = nil
    configuration.desiredKeys = [
      FamilyMember.RecordKey.userRecordName,
      FamilyMember.RecordKey.role,
    ]

    let operation = CKFetchRecordZoneChangesOperation(
      recordZoneIDs: [zoneID],
      configurationsByRecordZoneID: [zoneID: configuration])
    operation.fetchAllChanges = true
    let accumulator = MembershipFetchAccumulator(userRecordName: userRecordName)

    operation.recordWasChangedBlock = { _, recordResult in
      switch recordResult {
      case .success(let record):
        accumulator.apply(record)
      case .failure:
        accumulator.markIndeterminate()
      }
    }
    operation.recordWithIDWasDeletedBlock = { recordID, _ in
      accumulator.applyDeletion(recordID: recordID)
    }
    operation.recordZoneFetchResultBlock = { _, result in
      if case .failure(let error) = result {
        accumulator.recordZoneFailure(error)
      }
    }

    return await withCheckedContinuation { continuation in
      operation.fetchRecordZoneChangesResultBlock = { result in
        continuation.resume(returning: accumulator.observation(for: result))
      }
      database.add(operation)
    }
  }
}

private final class MembershipFetchAccumulator: @unchecked Sendable {  // SAFETY: NSLock guards every mutable field access
  private let lock = NSLock()
  private let userRecordName: String
  private var matchingRecordID: CKRecord.ID?
  private var roleValue: String?
  private var fetchFailed = false
  private var zoneWasRemoved = false

  init(userRecordName: String) {
    self.userRecordName = userRecordName
  }

  func apply(_ record: CKRecord) {
    guard record.recordType == FamilyMember.recordType,
      record[FamilyMember.RecordKey.userRecordName] as? String == userRecordName
    else { return }

    lock.withLock {
      matchingRecordID = record.recordID
      guard let role = record[FamilyMember.RecordKey.role] as? String else {
        fetchFailed = true
        return
      }
      roleValue = role
    }
  }

  func applyDeletion(recordID: CKRecord.ID) {
    lock.withLock {
      guard recordID == matchingRecordID else { return }
      matchingRecordID = nil
      roleValue = nil
    }
  }

  func markIndeterminate() {
    lock.withLock {
      fetchFailed = true
    }
  }

  func recordZoneFailure(_ error: Error) {
    lock.withLock {
      if startupRecoveryIsMissingZone(error) {
        zoneWasRemoved = true
      } else {
        fetchFailed = true
      }
    }
  }

  func observation(
    for operationResult: Result<Void, Error>
  ) -> StartupRecoveryMembershipObservation {
    lock.withLock {
      if zoneWasRemoved { return .recordZoneMissing }
      if fetchFailed { return .recordFetchFailed }
      if case .failure(let error) = operationResult {
        return startupRecoveryIsMissingZone(error) ? .recordZoneMissing : .recordFetchFailed
      }
      guard let roleValue else {
        return .recordAbsent(ownerUserRecordName: userRecordName)
      }
      return .recordRole(role: roleValue, ownerUserRecordName: userRecordName)
    }
  }
}

private final class ProfileFetchAccumulator: @unchecked Sendable {  // SAFETY: NSLock guards every mutable field access
  private let lock = NSLock()
  private var fold = StartupRecoveryProfileRecordFold()
  private var zoneFailureOutcome: StartupRecoveryProfileFetchOutcome?
  private var recordFailure = false

  func applyModification(recordName: String, recordType: String) {
    lock.withLock {
      fold.applyModification(recordName: recordName, recordType: recordType)
    }
  }

  func applyDeletion(recordName: String, recordType: String) {
    lock.withLock {
      fold.applyDeletion(recordName: recordName, recordType: recordType)
    }
  }

  func markIndeterminate() {
    lock.withLock {
      recordFailure = true
    }
  }

  func recordZoneFailure(_ error: Error) {
    lock.withLock {
      zoneFailureOutcome =
        startupRecoveryIsMissingZone(error) ? .zoneFetchReportedMissing : .indeterminate
    }
  }

  func outcome(for operationResult: Result<Void, Error>) -> StartupRecoveryProfileFetchOutcome {
    lock.withLock {
      if recordFailure { return .indeterminate }
      if let zoneFailureOutcome { return zoneFailureOutcome }
      switch operationResult {
      case .success:
        return .success
      case .failure(let error):
        return startupRecoveryIsMissingZone(error) ? .zoneFetchReportedMissing : .indeterminate
      }
    }
  }

  func foldSnapshot() -> StartupRecoveryProfileRecordFold {
    lock.withLock { fold }
  }

}

private func startupRecoveryIsMissingZone(_ error: Error) -> Bool {
  guard let cloudKitError = error as? CKError else { return false }
  switch cloudKitError.code {
  case .zoneNotFound, .userDeletedZone:
    return true
  case .partialFailure:
    guard
      let partialErrors = cloudKitError.partialErrorsByItemID,
      !partialErrors.isEmpty
    else { return false }
    return partialErrors.values.allSatisfy(startupRecoveryIsMissingZone)
  default:
    return false
  }
}
