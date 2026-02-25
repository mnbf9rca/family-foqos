import CloudKit
import Foundation

/// Result of verifying the current user's FamilyMember record against CloudKit
struct VerificationResult: Sendable {
  let isConnected: Bool
  let userRecordID: CKRecord.ID?
  let isSignedIn: Bool?
  let enforcedMode: AppMode?
}

/// Result of syncing share participants to FamilyMember records
struct ParticipantSyncResult: Sendable {
  let pendingParticipants: [CKShare.Participant]
  let familyMembers: [FamilyMember]
}

/// Contains all CloudKit network I/O, running on the cooperative thread pool (NOT @MainActor).
/// CloudKitManager delegates to this actor for every network call, then updates @Published
/// properties on the main actor with the results.
actor CloudKitNetworkService {

  // MARK: - CloudKit Infrastructure

  private lazy var container: CKContainer = {
    CKContainer(identifier: CloudKitConstants.containerIdentifier)
  }()

  private var privateDatabase: CKDatabase {
    container.privateCloudDatabase
  }

  private var sharedDatabase: CKDatabase {
    container.sharedCloudDatabase
  }

  private let policyZoneName = "FamilyPolicies"

  private var policyZoneID: CKRecordZone.ID {
    CKRecordZone.ID(zoneName: policyZoneName, ownerName: CKCurrentUserDefaultName)
  }

  private var policyZoneVerified = false
  private var activeZoneShare: CKShare?
  private let familyRootRecordName = "FamilyRoot"

  private static let staleCommandMaxAgeDays = 7
  private static let secondsPerDay: TimeInterval = 86400

  // MARK: - Account Status

  func checkAccountStatus() async -> (isSignedIn: Bool, userRecordID: CKRecord.ID?) {
    let start = CFAbsoluteTimeGetCurrent()
    Log.info("checkAccountStatus: starting", category: .cloudKit)
    do {
      let status = try await container.accountStatus()
      Log.info(
        "checkAccountStatus: got status (\(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - start))s)",
        category: .cloudKit)
      let signedIn = (status == .available)

      if signedIn {
        do {
          let recordID = try await container.userRecordID()
          Log.info(
            "checkAccountStatus: complete (\(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - start))s)",
            category: .cloudKit)
          return (isSignedIn: true, userRecordID: recordID)
        } catch {
          Log.error("Failed to fetch user record ID: \(error)", category: .cloudKit)
          return (isSignedIn: true, userRecordID: nil)
        }
      }

      Log.info(
        "checkAccountStatus: not signed in (\(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - start))s)",
        category: .cloudKit)
      return (isSignedIn: false, userRecordID: nil)
    } catch {
      Log.error("Account status error: \(error)", category: .cloudKit)
      return (isSignedIn: false, userRecordID: nil)
    }
  }

  // MARK: - User Record

  func ensureUserRecordID(cached: CKRecord.ID?) async throws -> CKRecord.ID {
    if let recordID = cached {
      return recordID
    }

    let result = await checkAccountStatus()

    guard result.isSignedIn else {
      throw CloudKitError.notSignedIn
    }

    guard let recordID = result.userRecordID else {
      throw CloudKitError.notSignedIn
    }

    return recordID
  }

  // MARK: - Zone Management

  func createPolicyZoneIfNeeded() async throws {
    if policyZoneVerified { return }

    let zone = CKRecordZone(zoneID: policyZoneID)

    do {
      _ = try await privateDatabase.save(zone)
      policyZoneVerified = true
      Log.info("Created policy zone: \(policyZoneName)", category: .cloudKit)
    } catch _ as CKError {
      do {
        _ = try await privateDatabase.recordZone(for: policyZoneID)
        policyZoneVerified = true
        Log.debug("Policy zone already exists: \(policyZoneName)", category: .cloudKit)
        return
      } catch {
        throw CloudKitError.zoneCreationFailed(error)
      }
    }
  }

  private func findSharedZoneByName() async -> CKRecordZone? {
    do {
      let zones = try await sharedDatabase.allRecordZones()
      return zones.first { $0.zoneID.zoneName == policyZoneName }
    } catch {
      Log.error("Failed to fetch shared zones: \(error)", category: .cloudKit)
      return nil
    }
  }

  private func ensureFamilyRootExists() async throws {
    let rootRecordID = CKRecord.ID(recordName: familyRootRecordName, zoneID: policyZoneID)

    do {
      _ = try await privateDatabase.record(for: rootRecordID)
      Log.debug("FamilyRoot exists", category: .cloudKit)
    } catch let error as CKError where error.code == .unknownItem {
      Log.info("Creating FamilyRoot record", category: .cloudKit)
      let rootRecord = CKRecord(recordType: "FamilyRoot", recordID: rootRecordID)
      rootRecord["createdAt"] = Date()
      _ = try await privateDatabase.save(rootRecord)
      Log.info("FamilyRoot created", category: .cloudKit)
    }
  }

  // MARK: - Family Member Management

  func saveFamilyMember(_ member: FamilyMember) async throws {
    Log.info(
      "Saving family member '\(member.displayName)' as \(member.role.displayName)",
      category: .cloudKit)

    try await createPolicyZoneIfNeeded()
    try await ensureFamilyRootExists()

    let record = member.toCKRecord(in: policyZoneID)

    do {
      _ = try await privateDatabase.save(record)
      Log.info("Saved family member: \(member.displayName)", category: .cloudKit)
    } catch {
      Log.error("Failed to save family member: \(error)", category: .cloudKit)
      throw CloudKitError.saveFailed(error)
    }
  }

  func deleteFamilyMember(_ member: FamilyMember) async throws {
    // First, try to remove them from the share
    await revokeShareAccess(forUserRecordName: member.userRecordName)

    // Then delete the FamilyMember record
    let recordID = CKRecord.ID(recordName: member.id.uuidString, zoneID: policyZoneID)

    do {
      try await privateDatabase.deleteRecord(withID: recordID)
      Log.info("Deleted family member: \(member.displayName)", category: .cloudKit)
    } catch {
      throw CloudKitError.deleteFailed(error)
    }
  }

  func removeShareParticipant(_ participant: CKShare.Participant) async throws {
    let rootRecordID = CKRecord.ID(recordName: familyRootRecordName, zoneID: policyZoneID)
    let rootRecord = try await privateDatabase.record(for: rootRecordID)

    guard let shareRef = rootRecord.share else {
      throw CloudKitError.shareNotFound
    }

    let shareRecord = try await privateDatabase.record(for: shareRef.recordID)
    guard let share = shareRecord as? CKShare else {
      Log.error(
        "Expected CKShare but received \(type(of: shareRecord))",
        category: .cloudKit)
      throw CloudKitError.shareNotFound
    }
    share.removeParticipant(participant)
    try await privateDatabase.save(share)
    self.activeZoneShare = share

    let name =
      participant.userIdentity.nameComponents?.formatted()
      ?? participant.userIdentity.lookupInfo?.emailAddress ?? "Unknown"
    Log.info("Removed participant '\(name)' from share", category: .cloudKit)
    // NOTE: Manager handles refreshShareParticipants() after this call
  }

  private func revokeShareAccess(forUserRecordName userRecordName: String?) async {
    guard let userRecordName = userRecordName else {
      Log.debug("No userRecordName to revoke", category: .cloudKit)
      return
    }

    do {
      let rootRecordID = CKRecord.ID(recordName: familyRootRecordName, zoneID: policyZoneID)
      let rootRecord = try await privateDatabase.record(for: rootRecordID)

      guard let shareRef = rootRecord.share else {
        Log.debug("No share exists to revoke from", category: .cloudKit)
        return
      }

      let shareRecord = try await privateDatabase.record(for: shareRef.recordID)
      guard let share = shareRecord as? CKShare else {
        Log.error(
          "Expected CKShare but received \(type(of: shareRecord))",
          category: .cloudKit)
        return
      }

      if let participant = share.participants.first(where: {
        $0.userIdentity.userRecordID?.recordName == userRecordName
      }) {
        share.removeParticipant(participant)
        try await privateDatabase.save(share)
        self.activeZoneShare = share
        Log.info("Revoked share access for \(userRecordName)", category: .cloudKit)
        // NOTE: Manager handles refreshShareParticipants() after this call
      } else {
        Log.debug("Participant not found in share", category: .cloudKit)
      }
    } catch {
      Log.error("Failed to revoke share access: \(error)", category: .cloudKit)
    }
  }

  func fetchFamilyMembers() async throws -> [FamilyMember] {
    try await createPolicyZoneIfNeeded()

    let query = CKQuery(
      recordType: FamilyMember.recordType,
      predicate: NSPredicate(value: true)
    )

    do {
      let (results, _) = try await privateDatabase.records(
        matching: query,
        inZoneWith: policyZoneID
      )

      var members: [FamilyMember] = []
      for (_, result) in results {
        if case .success(let record) = result,
          let member = FamilyMember(from: record)
        {
          members.append(member)
        }
      }

      members.sort { $0.enrolledAt < $1.enrolledAt }
      return members
    } catch let error as CKError {
      if error.code == .zoneNotFound || error.code == .unknownItem {
        return []
      }
      throw CloudKitError.fetchFailed(error)
    }
  }

  // MARK: - Lock Code Management

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
        if case .success(let record) = result,
          let code = FamilyLockCode(from: record)
        {
          codes.append(code)
        }
      }
    } catch {
      Log.error(
        "Failed to fetch lock codes from zone \(zone.zoneID): \(error)", category: .cloudKit)
    }

    return (codes: codes, isConnected: true)
  }

  // MARK: - Family Commands

  func sendCommand(_ command: FamilyCommand) async throws {
    Log.info("Sending command: \(command.commandType.rawValue) to child", category: .cloudKit)

    try await createPolicyZoneIfNeeded()
    try await ensureFamilyRootExists()

    let record = command.toCKRecord(in: policyZoneID)

    do {
      _ = try await privateDatabase.save(record)
      Log.info("Command sent successfully", category: .cloudKit)
    } catch {
      Log.error("Failed to send command: \(error)", category: .cloudKit)
      throw CloudKitError.saveFailed(error)
    }
  }

  func fetchPendingCommands(currentUserRecordID: CKRecord.ID?) async throws -> [FamilyCommand] {
    let zones = try await sharedDatabase.allRecordZones()

    var allCommands: [FamilyCommand] = []

    guard let userRecordID = currentUserRecordID else {
      Log.debug("No user record ID, skipping command fetch", category: .cloudKit)
      return []
    }
    let currentUserRecordName = userRecordID.recordName

    for zone in zones {
      let query = CKQuery(
        recordType: FamilyCommand.recordType,
        predicate: NSPredicate(format: "targetChildId == %@", currentUserRecordName)
      )

      do {
        let (results, _) = try await sharedDatabase.records(
          matching: query,
          inZoneWith: zone.zoneID
        )

        for (_, result) in results {
          if case .success(let record) = result,
            let command = FamilyCommand(from: record)
          {
            allCommands.append(command)
          }
        }
      } catch {
        Log.error(
          "Failed to fetch commands from zone \(zone.zoneID): \(error)", category: .cloudKit)
      }
    }

    return allCommands
  }

  func deleteCommand(_ command: FamilyCommand) async throws {
    let zones = try await sharedDatabase.allRecordZones()

    for zone in zones {
      let recordName = FamilyCommand.recordName(
        commandType: command.commandType, targetChildId: command.targetChildId,
        parentId: command.createdBy)
      let recordID = CKRecord.ID(recordName: recordName, zoneID: zone.zoneID)

      do {
        try await sharedDatabase.deleteRecord(withID: recordID)
        Log.info("Deleted command: \(command.commandType.rawValue)", category: .cloudKit)
        return
      } catch let error as CKError where error.code == .unknownItem {
        continue
      } catch {
        Log.error("Failed to delete command: \(error)", category: .cloudKit)
        throw CloudKitError.deleteFailed(error)
      }
    }
  }

  func cleanupStaleCommands(maxAgeDays: Int = CloudKitNetworkService.staleCommandMaxAgeDays) async {
    let maxAge: TimeInterval = Double(maxAgeDays) * CloudKitNetworkService.secondsPerDay
    let cutoffDate = Date().addingTimeInterval(-maxAge)

    do {
      let zones = try await sharedDatabase.allRecordZones()
      for zone in zones {
        await cleanupStaleCommandsInZone(
          zone.zoneID, database: sharedDatabase, cutoffDate: cutoffDate)
      }
    } catch {
      Log.debug("No shared zones to cleanup: \(error)", category: .cloudKit)
    }

    if policyZoneVerified {
      await cleanupStaleCommandsInZone(
        policyZoneID, database: privateDatabase, cutoffDate: cutoffDate)
    }
  }

  private func cleanupStaleCommandsInZone(
    _ zoneID: CKRecordZone.ID, database: CKDatabase, cutoffDate: Date
  ) async {
    let query = CKQuery(
      recordType: FamilyCommand.recordType,
      predicate: NSPredicate(format: "createdAt < %@", cutoffDate as NSDate)
    )

    do {
      let (results, _) = try await database.records(matching: query, inZoneWith: zoneID)

      for (recordID, result) in results {
        if case .success = result {
          do {
            try await database.deleteRecord(withID: recordID)
            Log.info("Cleaned up stale command: \(recordID.recordName)", category: .cloudKit)
          } catch {
            Log.error("Failed to delete stale command: \(error)", category: .cloudKit)
          }
        }
      }
    } catch {
      Log.debug("No stale commands to cleanup in zone \(zoneID): \(error)", category: .cloudKit)
    }
  }

  // MARK: - Family Sharing

  func getOrCreateFamilyShare() async throws -> CKShare {
    if let existingShare = self.activeZoneShare {
      return existingShare
    }

    try await createPolicyZoneIfNeeded()

    let rootRecordID = CKRecord.ID(recordName: familyRootRecordName, zoneID: policyZoneID)

    do {
      let rootRecord = try await privateDatabase.record(for: rootRecordID)

      if let shareRef = rootRecord.share {
        let shareRecord = try await privateDatabase.record(for: shareRef.recordID)
        guard let share = shareRecord as? CKShare else {
          Log.error(
            "Expected CKShare but received \(type(of: shareRecord))",
            category: .cloudKit)
          throw CloudKitError.shareNotFound
        }
        self.activeZoneShare = share
        Log.debug("Found existing family share", category: .cloudKit)
        return share
      }

      return try await createShareForRoot(rootRecord)
    } catch let error as CKError where error.code == .unknownItem {
      Log.info("Creating new family root record", category: .cloudKit)
      let rootRecord = CKRecord(recordType: "FamilyRoot", recordID: rootRecordID)
      rootRecord["createdAt"] = Date()

      _ = try await privateDatabase.save(rootRecord)
      return try await createShareForRoot(rootRecord)
    }
  }

  private func createShareForRoot(_ rootRecord: CKRecord) async throws -> CKShare {
    let share = CKShare(rootRecord: rootRecord)
    share.publicPermission = .none
    share[CKShare.SystemFieldKey.title] = "Family Foqos Policies" as CKRecordValue

    let modifyOperation = CKModifyRecordsOperation(
      recordsToSave: [rootRecord, share],
      recordIDsToDelete: nil
    )
    modifyOperation.savePolicy = .changedKeys

    // Capture privateDatabase as local before entering the continuation closure
    let database = self.privateDatabase

    let resultShare: CKShare = try await withCheckedThrowingContinuation { continuation in
      modifyOperation.modifyRecordsResultBlock = { result in
        switch result {
        case .success:
          Log.info("Created family share successfully", category: .cloudKit)
          continuation.resume(returning: share)
        case .failure(let error):
          Log.error("Failed to create family share: \(error)", category: .cloudKit)
          continuation.resume(throwing: CloudKitError.shareFailed(error))
        }
      }
      database.add(modifyOperation)
    }

    // Update activeZoneShare after continuation resumes (not inside the callback)
    self.activeZoneShare = resultShare
    return resultShare
  }

  func getCurrentFamilyShare() async -> CKShare? {
    return activeZoneShare
  }

  func refreshShareParticipants() async -> [CKShare.Participant] {
    await cleanupStaleCommands()

    // Clear cached share to force fresh fetch from server
    self.activeZoneShare = nil

    let rootRecordID = CKRecord.ID(recordName: familyRootRecordName, zoneID: policyZoneID)
    do {
      let rootRecord = try await privateDatabase.record(for: rootRecordID)
      guard let shareRef = rootRecord.share else {
        Log.debug("No share exists", category: .cloudKit)
        return []
      }

      let shareRecord = try await privateDatabase.record(for: shareRef.recordID)
      guard let share = shareRecord as? CKShare else {
        Log.error(
          "Expected CKShare but received \(type(of: shareRecord))",
          category: .cloudKit)
        return []
      }
      self.activeZoneShare = share

      let participants = share.participants.filter { $0.role != .owner }
      for participant in participants {
        let name = participant.userIdentity.nameComponents?.formatted() ?? ""
        let email = participant.userIdentity.lookupInfo?.emailAddress ?? ""
        let displayInfo = !name.isEmpty ? name : (!email.isEmpty ? email : "Unknown")
        Log.debug(
          "Participant '\(displayInfo)' status: \(participant.acceptanceStatus.rawValue)",
          category: .cloudKit)
      }

      Log.info("Found \(participants.count) share participants", category: .cloudKit)
      return participants
    } catch {
      Log.error("Failed to fetch share participants: \(error)", category: .cloudKit)
      return []
    }
  }

  // MARK: - Share Acceptance

  func acceptShareDirect(metadata: CKShare.Metadata) async throws {
    do {
      _ = try await container.accept(metadata)
      Log.info("Accepted share successfully", category: .cloudKit)
    } catch {
      throw CloudKitError.shareAcceptFailed(error)
    }
  }

  // MARK: - Self Registration

  func registerSelfAsFamilyMember(role: FamilyRole, userRecordID: CKRecord.ID) async {
    guard let zone = await findSharedZoneByName() else {
      Log.error("No shared zone found for self-registration", category: .cloudKit)
      return
    }

    let userRecordName = userRecordID.recordName

    let query = CKQuery(
      recordType: FamilyMember.recordType,
      predicate: NSPredicate(format: "userRecordName == %@", userRecordName)
    )

    do {
      let (results, _) = try await sharedDatabase.records(
        matching: query,
        inZoneWith: zone.zoneID
      )

      for (_, result) in results {
        if case .success(let existingRecord) = result {
          let existingRole = existingRecord[FamilyMember.RecordKey.role] as? String
          if existingRole != role.rawValue {
            existingRecord[FamilyMember.RecordKey.role] = role.rawValue
            _ = try await sharedDatabase.save(existingRecord)
            Log.info("Updated self FamilyMember role to \(role.rawValue)", category: .cloudKit)
          } else {
            Log.debug("Self FamilyMember already exists with correct role", category: .cloudKit)
          }
          return
        }
      }

      let displayName =
        await fetchCurrentUserDisplayName(userRecordID: userRecordID, in: zone.zoneID)
        ?? "Family Member"
      let member = FamilyMember(
        userRecordName: userRecordName,
        displayName: displayName,
        role: role
      )

      let record = member.toCKRecord(in: zone.zoneID)
      _ = try await sharedDatabase.save(record)
      Log.info("Registered self as \(role.rawValue) FamilyMember", category: .cloudKit)
    } catch {
      Log.error("Failed to register self as FamilyMember: \(error)", category: .cloudKit)
    }
  }

  // MARK: - Verification

  func verifySelfFamilyMember(
    cachedUserRecordID: CKRecord.ID?,
    localMode: AppMode
  ) async -> VerificationResult {
    let start = CFAbsoluteTimeGetCurrent()
    Log.info("verifySelfFamilyMember: starting", category: .cloudKit)

    guard let zone = await findSharedZoneByName() else {
      Log.info(
        "verifySelfFamilyMember: no shared zone (\(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - start))s)",
        category: .cloudKit)
      return VerificationResult(
        isConnected: false, userRecordID: cachedUserRecordID, isSignedIn: nil, enforcedMode: nil)
    }
    Log.info(
      "verifySelfFamilyMember: found zone (\(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - start))s)",
      category: .cloudKit)

    let userRecordID: CKRecord.ID
    if let cached = cachedUserRecordID {
      userRecordID = cached
    } else {
      do {
        userRecordID = try await ensureUserRecordID(cached: cachedUserRecordID)
        Log.info(
          "verifySelfFamilyMember: fetched user record ID (\(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - start))s)",
          category: .cloudKit)
      } catch {
        Log.error(
          "Could not fetch user record ID for verification: \(error)", category: .cloudKit)
        return VerificationResult(
          isConnected: true, userRecordID: nil, isSignedIn: nil, enforcedMode: nil)
      }
    }
    let userRecordName = userRecordID.recordName

    let query = CKQuery(
      recordType: FamilyMember.recordType,
      predicate: NSPredicate(format: "userRecordName == %@", userRecordName)
    )

    do {
      let (results, _) = try await sharedDatabase.records(
        matching: query,
        inZoneWith: zone.zoneID
      )
      Log.info(
        "verifySelfFamilyMember: queried FamilyMember (\(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - start))s)",
        category: .cloudKit)

      for (_, result) in results {
        if case .success(let record) = result {
          guard let recordRoleString = record[FamilyMember.RecordKey.role] as? String,
            let recordRole = FamilyRole(rawValue: recordRoleString)
          else {
            Log.error("FamilyMember record has missing/invalid role", category: .cloudKit)
            return VerificationResult(
              isConnected: true, userRecordID: userRecordID, isSignedIn: true, enforcedMode: nil)
          }

          let cloudKitMode: AppMode = recordRole == .parent ? .parent : .child

          if localMode != cloudKitMode {
            Log.info(
              "Enforced app mode from CloudKit: \(localMode.rawValue) -> \(cloudKitMode.rawValue)",
              category: .cloudKit)
            Log.info(
              "verifySelfFamilyMember: complete (\(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - start))s)",
              category: .cloudKit)
            return VerificationResult(
              isConnected: true, userRecordID: userRecordID, isSignedIn: true,
              enforcedMode: cloudKitMode)
          }

          Log.info(
            "verifySelfFamilyMember: complete (\(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - start))s)",
            category: .cloudKit)
          return VerificationResult(
            isConnected: true, userRecordID: userRecordID, isSignedIn: true, enforcedMode: nil)
        }
      }

      // No FamilyMember record found
      if localMode == .parent || localMode == .child {
        Log.info("No self FamilyMember record found, re-registering", category: .cloudKit)
        let expectedRole: FamilyRole = localMode == .parent ? .parent : .child
        await registerSelfAsFamilyMember(role: expectedRole, userRecordID: userRecordID)
      } else {
        Log.debug(
          "No self FamilyMember record found, staying in individual mode", category: .cloudKit)
      }

      Log.info(
        "verifySelfFamilyMember: complete (\(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - start))s)",
        category: .cloudKit)
      return VerificationResult(
        isConnected: true, userRecordID: userRecordID, isSignedIn: true, enforcedMode: nil)
    } catch {
      Log.error("Failed to verify self FamilyMember record: \(error)", category: .cloudKit)
      Log.info(
        "verifySelfFamilyMember: failed (\(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - start))s)",
        category: .cloudKit)
      return VerificationResult(
        isConnected: true, userRecordID: userRecordID, isSignedIn: true, enforcedMode: nil)
    }
  }

  func fetchCurrentUserDisplayName(
    userRecordID: CKRecord.ID, in zoneID: CKRecordZone.ID
  ) async -> String? {
    do {
      let rootRecordID = CKRecord.ID(recordName: familyRootRecordName, zoneID: zoneID)
      let rootRecord = try await sharedDatabase.record(for: rootRecordID)
      guard let shareRef = rootRecord.share else { return nil }
      let shareRecord = try await sharedDatabase.record(for: shareRef.recordID)
      guard let share = shareRecord as? CKShare else {
        Log.error(
          "Expected CKShare but received \(type(of: shareRecord)) for share reference \(shareRef)",
          category: .cloudKit)
        return nil
      }

      let me = share.participants.first {
        $0.userIdentity.userRecordID?.recordName == userRecordID.recordName
      }
      return me?.userIdentity.nameComponents?.formatted()
    } catch {
      Log.debug("Could not fetch user display name from share: \(error)", category: .cloudKit)
      return nil
    }
  }

  // MARK: - Share Participant Sync

  func syncShareParticipantsToFamilyMembers() async throws -> ParticipantSyncResult {
    // Clear cached share to force fresh fetch
    self.activeZoneShare = nil

    let share: CKShare
    let rootRecordID = CKRecord.ID(recordName: familyRootRecordName, zoneID: policyZoneID)
    do {
      let rootRecord = try await privateDatabase.record(for: rootRecordID)
      guard let shareRef = rootRecord.share else {
        Log.info("No share exists yet", category: .cloudKit)
        return ParticipantSyncResult(pendingParticipants: [], familyMembers: [])
      }
      let shareRecord = try await privateDatabase.record(for: shareRef.recordID)
      guard let fetchedShare = shareRecord as? CKShare else {
        Log.error(
          "Expected CKShare but received \(type(of: shareRecord))",
          category: .cloudKit)
        return ParticipantSyncResult(pendingParticipants: [], familyMembers: [])
      }
      share = fetchedShare
      self.activeZoneShare = share
    } catch {
      Log.error("Could not fetch share: \(error)", category: .cloudKit)
      return ParticipantSyncResult(pendingParticipants: [], familyMembers: [])
    }

    let acceptedParticipants = share.participants.filter {
      $0.acceptanceStatus == .accepted && $0.role != .owner
    }

    let currentParticipantRecordNames = Set(
      acceptedParticipants.compactMap { $0.userIdentity.userRecordID?.recordName }
    )

    Log.info("Found \(acceptedParticipants.count) accepted participants", category: .cloudKit)

    var familyMembers = try await fetchFamilyMembers()

    let matchedRecordNames = Set(familyMembers.map { $0.userRecordName })

    var pending: [CKShare.Participant] = []
    for participant in acceptedParticipants {
      guard let userRecordID = participant.userIdentity.userRecordID else {
        pending.append(participant)
        continue
      }
      if !matchedRecordNames.contains(userRecordID.recordName) {
        pending.append(participant)
      }
    }

    if !pending.isEmpty {
      Log.info(
        "\(pending.count) accepted participants pending self-registration", category: .cloudKit)
    }

    // Remove FamilyMembers who are no longer accepted participants
    for member in familyMembers {
      let userRecordName = member.userRecordName

      if !currentParticipantRecordNames.contains(userRecordName) {
        do {
          let recordID = CKRecord.ID(recordName: member.id.uuidString, zoneID: policyZoneID)
          try await privateDatabase.deleteRecord(withID: recordID)
          familyMembers.removeAll { $0.id == member.id }
          Log.info(
            "Removed FamilyMember who left share: \(member.displayName)", category: .cloudKit)
        } catch {
          Log.error("Failed to remove stale FamilyMember: \(error)", category: .cloudKit)
        }
      }
    }

    return ParticipantSyncResult(
      pendingParticipants: pending, familyMembers: familyMembers)
  }

  // MARK: - Connection Status

  func checkFamilyConnectionStatus() async -> Bool {
    let zone = await findSharedZoneByName()
    return zone != nil
  }

  func fetchShareFromSharedDatabase() async throws -> CKShare {
    guard let zone = await findSharedZoneByName() else {
      throw CloudKitError.notConnectedToFamily
    }

    let rootRecordID = CKRecord.ID(recordName: familyRootRecordName, zoneID: zone.zoneID)
    let rootRecord = try await sharedDatabase.record(for: rootRecordID)

    guard let shareRef = rootRecord.share else {
      throw CloudKitError.shareNotFound
    }

    let shareRecord = try await sharedDatabase.record(for: shareRef.recordID)
    guard let share = shareRecord as? CKShare else {
      Log.error(
        "Expected CKShare but received \(type(of: shareRecord))",
        category: .cloudKit)
      throw CloudKitError.shareNotFound
    }
    return share
  }
}
