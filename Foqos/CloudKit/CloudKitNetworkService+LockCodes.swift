import CloudKit
import Foundation

extension CloudKitNetworkService {

  // MARK: - Lock Code Management

  static func resolveSharedLockCodeFetch(
    codes: [FamilyLockCode],
    hasRecordFailures: Bool
  ) -> (codes: [FamilyLockCode], isConnected: Bool) {
    hasRecordFailures ? (codes: [], isConnected: false) : (codes: codes, isConnected: true)
  }

  func saveLockCode(_ lockCode: FamilyLockCode) async throws {
    Log.info("Saving lock code", category: .cloudKit)

    try await createPolicyZoneIfNeeded()
    try await ensureFamilyRootExists()

    let recordID = CKRecord.ID(recordName: lockCode.id.uuidString, zoneID: policyZoneID)

    let record: CKRecord
    do {
      record = try await privateDatabase.record(for: recordID)
      Log.debug("Updating existing lock code record", category: .cloudKit)
    } catch let error as CKError where error.code == .unknownItem {
      record = CKRecord(recordType: FamilyLockCode.recordType, recordID: recordID)
      Log.debug("Creating new lock code record", category: .cloudKit)
    }

    record["id"] = lockCode.id.uuidString
    record["codeHash"] = lockCode.codeHash
    record["codeSalt"] = lockCode.codeSalt
    record["createdAt"] = lockCode.createdAt
    record["updatedAt"] = lockCode.updatedAt

    let familyRootID = CKRecord.ID(recordName: familyRootRecordName, zoneID: policyZoneID)
    record.parent = CKRecord.Reference(recordID: familyRootID, action: .none)

    switch lockCode.scope {
    case .allChildren:
      record["scopeType"] = "all"
      record["scopeChildId"] = nil
    case .specificChild(let childId):
      record["scopeType"] = "specific"
      record["scopeChildId"] = childId
    }

    do {
      _ = try await privateDatabase.save(record)
      Log.info("Saved lock code successfully", category: .cloudKit)
    } catch {
      Log.error("Failed to save lock code: \(error)", category: .cloudKit)
      throw CloudKitError.saveFailed(error)
    }
  }

  func deleteLockCode(_ lockCode: FamilyLockCode) async throws {
    let recordID = CKRecord.ID(recordName: lockCode.id.uuidString, zoneID: policyZoneID)

    do {
      try await privateDatabase.deleteRecord(withID: recordID)
      Log.info("Deleted lock code successfully", category: .cloudKit)
    } catch {
      throw CloudKitError.deleteFailed(error)
    }
  }

  func fetchLockCodes() async throws -> [FamilyLockCode] {
    try await createPolicyZoneIfNeeded()

    let query = CKQuery(
      recordType: FamilyLockCode.recordType,
      predicate: NSPredicate(value: true)
    )

    do {
      let (results, _) = try await privateDatabase.records(
        matching: query,
        inZoneWith: policyZoneID
      )

      var codes: [FamilyLockCode] = []
      for (_, result) in results {
        if case .success(let record) = result,
          let code = FamilyLockCode(from: record)
        {
          codes.append(code)
        }
      }

      codes.sort { $0.createdAt < $1.createdAt }
      return codes
    } catch let error as CKError {
      if error.code == .zoneNotFound || error.code == .unknownItem {
        return []
      }
      throw CloudKitError.fetchFailed(error)
    }
  }

  func fetchSharedLockCodes() async throws -> (codes: [FamilyLockCode], isConnected: Bool) {
    guard let zone = await findSharedZoneByName() else {
      return (codes: [], isConnected: false)
    }

    let query = CKQuery(
      recordType: FamilyLockCode.recordType,
      predicate: NSPredicate(value: true)
    )

    var codes: [FamilyLockCode] = []
    do {
      let (results, _) = try await sharedDatabase.records(
        matching: query,
        inZoneWith: zone.zoneID
      )

      for (_, result) in results {
        switch result {
        case .success(let record):
          guard let code = FamilyLockCode(from: record) else {
            Log.error(
              "Failed to decode lock code record from zone \(zone.zoneID)",
              category: .cloudKit)
            return Self.resolveSharedLockCodeFetch(codes: [], hasRecordFailures: true)
          }
          codes.append(code)
        case .failure(let error):
          Log.error(
            "Failed to fetch lock code record from zone \(zone.zoneID): \(error)",
            category: .cloudKit)
          return Self.resolveSharedLockCodeFetch(codes: [], hasRecordFailures: true)
        }
      }
    } catch {
      Log.error(
        "Failed to fetch lock codes from zone \(zone.zoneID): \(error)", category: .cloudKit)
      // A CKError here means we could not read the family data — report DISCONNECTED so the
      // caller preserves the last-synced cache instead of treating [] as "parent cleared" (#197).
      return (codes: [], isConnected: false)
    }

    return Self.resolveSharedLockCodeFetch(codes: codes, hasRecordFailures: false)
  }

  /// Delete family sharing data from the FamilyPolicies zone.
  /// - Parameter clearEverything: If true, deletes ALL records including FamilyRoot and
  ///   FamilyMember. If false, only deletes FamilyLockCode and FamilyCommand records.
  func resetFamilySharing(clearEverything: Bool) async throws {
    var recordTypes = [
      FamilyLockCode.recordType,
      FamilyCommand.recordType,
    ]

    if clearEverything {
      recordTypes.append(contentsOf: [
        FamilyMember.recordType,
        "FamilyRoot",
      ])
    }

    for recordType in recordTypes {
      let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))

      do {
        let (results, _) = try await privateDatabase.records(
          matching: query,
          inZoneWith: policyZoneID
        )

        let recordIDs = results.compactMap { recordID, result -> CKRecord.ID? in
          if case .success = result { return recordID }
          return nil
        }

        guard !recordIDs.isEmpty else { continue }
        _ = try await privateDatabase.modifyRecords(saving: [], deleting: recordIDs)
        Log.info(
          "Deleted \(recordIDs.count) \(recordType) records from FamilyPolicies",
          category: .cloudKit)
      } catch {
        if let ckError = error as? CKError, ckError.code == .zoneNotFound {
          Log.debug("Policy zone not found, nothing to reset", category: .cloudKit)
          policyZoneVerified = false
          activeZoneShare = nil
          return
        } else {
          Log.error(
            "Failed to delete \(recordType) records from FamilyPolicies: \(error)",
            category: .cloudKit)
        }
      }
    }

    if clearEverything {
      policyZoneVerified = false
      activeZoneShare = nil
      Log.info("Reset all family sharing data", category: .cloudKit)
    } else {
      Log.info("Reset family rules (lock codes and commands)", category: .cloudKit)
    }
  }
}
