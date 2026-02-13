import CloudKit
import Foundation

/// Manages CloudKit operations for Family Policy sync between parent and child devices
@MainActor
class CloudKitManager: ObservableObject {
  static let shared = CloudKitManager()

  // CloudKit container identifier (must match entitlements)
  private let containerIdentifier = "iCloud.com.cynexia.family-foqos"

  // Custom zone for family policies (enables sharing)
  private let policyZoneName = "FamilyPolicies"

  // CloudKit container and databases
  private lazy var container: CKContainer = {
    CKContainer(identifier: containerIdentifier)
  }()

  private var privateDatabase: CKDatabase {
    container.privateCloudDatabase
  }

  private var sharedDatabase: CKDatabase {
    container.sharedCloudDatabase
  }

  // Published state
  @Published var currentUserRecordID: CKRecord.ID?
  @Published var isSignedIn = false
  @Published var familyMembers: [FamilyMember] = []  // Family members (parents and children)
  @Published var lockCodes: [FamilyLockCode] = []  // Lock codes created by this parent
  @Published var sharedLockCodes: [FamilyLockCode] = []  // Lock codes shared with this user (child)
  @Published var isConnectedToFamily = false  // For children: whether connected to parent's share
  @Published var shareParticipants: [CKShare.Participant] = []  // For parents: pending/accepted invitations
  @Published var isLoading = false
  @Published var error: CloudKitError?
  @Published var shareAcceptedMessage: String?  // Set when a share is successfully accepted
  @Published var shareAcceptanceIsError = false  // True when shareAcceptedMessage is an error (vs success)
  @Published var pendingParticipants: [CKShare.Participant] = []  // Accepted participants without FamilyMember records

  // Active zone share (for enrolling children)
  private var activeZoneShare: CKShare?

  // Track if zone has been verified this session
  private var policyZoneVerified = false

  // Zone ID for policy storage
  private var policyZoneID: CKRecordZone.ID {
    CKRecordZone.ID(zoneName: policyZoneName, ownerName: CKCurrentUserDefaultName)
  }

  // MARK: - Initialization

  private init() {
    Task {
      await checkAccountStatus()
    }
  }

  // MARK: - Account Status

  /// Check if user is signed into iCloud
  func checkAccountStatus() async {
    do {
      let status = try await container.accountStatus()
      self.isSignedIn = (status == .available)

      if status == .available {
        await fetchCurrentUserRecordID()
      }
    } catch {
      Log.error("Account status error: \(error)", category: .cloudKit)
      self.isSignedIn = false
    }
  }

  /// Fetch the current user's record ID
  private func fetchCurrentUserRecordID() async {
    do {
      let recordID = try await container.userRecordID()
      self.currentUserRecordID = recordID
    } catch {
      Log.error("Failed to fetch user record ID: \(error)", category: .cloudKit)
    }
  }

  // MARK: - Zone Management

  /// Create the custom zone for storing policies (enables sharing)
  func createPolicyZoneIfNeeded() async throws {
    // Skip if already verified this session
    if policyZoneVerified { return }

    let zone = CKRecordZone(zoneID: policyZoneID)

    do {
      _ = try await privateDatabase.save(zone)
      policyZoneVerified = true
      Log.info("Created policy zone: \(policyZoneName)", category: .cloudKit)
    } catch _ as CKError {
      // Zone already exists - that's fine, mark as verified
      // CKError codes that indicate zone exists: save succeeds silently for existing zones,
      // but if we get any error, check if zone exists before failing
      do {
        _ = try await privateDatabase.recordZone(for: policyZoneID)
        policyZoneVerified = true
        Log.debug("Policy zone already exists: \(policyZoneName)", category: .cloudKit)
        return
      } catch {
        // Zone truly doesn't exist and creation failed
        throw CloudKitError.zoneCreationFailed(error)
      }
    }
  }

  /// Find the shared zone matching our policy zone name
  /// Returns the first zone whose name matches `policyZoneName`, or nil if none found
  private func findSharedZoneByName() async -> CKRecordZone? {
    do {
      let zones = try await sharedDatabase.allRecordZones()
      return zones.first { $0.zoneID.zoneName == policyZoneName }
    } catch {
      Log.error("Failed to fetch shared zones: \(error)", category: .cloudKit)
      return nil
    }
  }

  // MARK: - User Record

  /// Ensure user record ID is available, fetching if needed
  func ensureUserRecordID() async throws -> CKRecord.ID {
    if let recordID = currentUserRecordID {
      return recordID
    }

    // Try to fetch it
    await checkAccountStatus()

    guard isSignedIn else {
      throw CloudKitError.notSignedIn
    }

    guard let recordID = currentUserRecordID else {
      throw CloudKitError.notSignedIn
    }

    return recordID
  }

  /// Ensure the FamilyRoot record exists (needed for share hierarchy)
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

  /// Save a family member to CloudKit
  func saveFamilyMember(_ member: FamilyMember) async throws {
    Log.info("Saving family member '\(member.displayName)' as \(member.role.displayName)", category: .cloudKit)

    try await createPolicyZoneIfNeeded()
    try await ensureFamilyRootExists()

    let record = member.toCKRecord(in: policyZoneID)

    do {
      _ = try await privateDatabase.save(record)
      if let index = self.familyMembers.firstIndex(where: { $0.id == member.id }) {
        self.familyMembers[index] = member
      } else {
        self.familyMembers.append(member)
      }
      Log.info("Saved family member: \(member.displayName)", category: .cloudKit)
    } catch {
      Log.error("Failed to save family member: \(error)", category: .cloudKit)
      throw CloudKitError.saveFailed(error)
    }
  }

  /// Delete a family member from CloudKit and revoke their share access
  func deleteFamilyMember(_ member: FamilyMember) async throws {
    // First, try to remove them from the share
    await revokeShareAccess(forUserRecordName: member.userRecordName)

    // Then delete the FamilyMember record
    let recordID = CKRecord.ID(recordName: member.id.uuidString, zoneID: policyZoneID)

    do {
      try await privateDatabase.deleteRecord(withID: recordID)
      self.familyMembers.removeAll { $0.id == member.id }
      Log.info("Deleted family member: \(member.displayName)", category: .cloudKit)
    } catch {
      throw CloudKitError.deleteFailed(error)
    }
  }

  /// Remove a share participant directly (revokes their access so they can't rejoin)
  func removeShareParticipant(_ participant: CKShare.Participant) async throws {
    let rootRecordID = CKRecord.ID(recordName: familyRootRecordName, zoneID: policyZoneID)
    let rootRecord = try await privateDatabase.record(for: rootRecordID)

    guard let shareRef = rootRecord.share else {
      throw CloudKitError.shareNotFound
    }

    let share = try await privateDatabase.record(for: shareRef.recordID) as! CKShare
    share.removeParticipant(participant)
    try await privateDatabase.save(share)
    self.activeZoneShare = share

    let name =
      participant.userIdentity.nameComponents?.formatted()
      ?? participant.userIdentity.lookupInfo?.emailAddress ?? "Unknown"
    Log.info("Removed participant '\(name)' from share", category: .cloudKit)

    await refreshShareParticipants()
  }

  /// Revoke a user's access to the family share
  private func revokeShareAccess(forUserRecordName userRecordName: String?) async {
    guard let userRecordName = userRecordName else {
      Log.debug("No userRecordName to revoke", category: .cloudKit)
      return
    }

    do {
      // Get the current share
      let rootRecordID = CKRecord.ID(recordName: familyRootRecordName, zoneID: policyZoneID)
      let rootRecord = try await privateDatabase.record(for: rootRecordID)

      guard let shareRef = rootRecord.share else {
        Log.debug("No share exists to revoke from", category: .cloudKit)
        return
      }

      let share = try await privateDatabase.record(for: shareRef.recordID) as! CKShare

      // Find the participant to remove
      if let participant = share.participants.first(where: {
        $0.userIdentity.userRecordID?.recordName == userRecordName
      }) {
        share.removeParticipant(participant)

        // Save the updated share
        try await privateDatabase.save(share)
        self.activeZoneShare = share

        Log.info("Revoked share access for \(userRecordName)", category: .cloudKit)

        // Refresh participants list
        await refreshShareParticipants()
      } else {
        Log.debug("Participant not found in share", category: .cloudKit)
      }
    } catch {
      Log.error("Failed to revoke share access: \(error)", category: .cloudKit)
    }
  }

  /// Fetch all family members
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

      // Sort by enrolledAt ascending
      members.sort { $0.enrolledAt < $1.enrolledAt }

      self.familyMembers = members

      return members
    } catch let error as CKError {
      if error.code == .zoneNotFound || error.code == .unknownItem {
        self.familyMembers = []
        return []
      }
      throw CloudKitError.fetchFailed(error)
    }
  }

  // MARK: - Lock Code Management

  /// Save a lock code to CloudKit (parent operation)
  func saveLockCode(_ lockCode: FamilyLockCode) async throws {
    Log.info("Saving lock code", category: .cloudKit)

    try await createPolicyZoneIfNeeded()
    try await ensureFamilyRootExists()

    let recordID = CKRecord.ID(recordName: lockCode.id.uuidString, zoneID: policyZoneID)

    // Try to fetch existing record first, or create new one
    let record: CKRecord
    do {
      record = try await privateDatabase.record(for: recordID)
      Log.debug("Updating existing lock code record", category: .cloudKit)
    } catch let error as CKError where error.code == .unknownItem {
      // Record doesn't exist, create new one
      record = CKRecord(recordType: FamilyLockCode.recordType, recordID: recordID)
      Log.debug("Creating new lock code record", category: .cloudKit)
    }

    // Update record fields
    record["id"] = lockCode.id.uuidString
    record["codeHash"] = lockCode.codeHash
    record["codeSalt"] = lockCode.codeSalt
    record["createdAt"] = lockCode.createdAt
    record["updatedAt"] = lockCode.updatedAt

    // Set parent reference to FamilyRoot for share hierarchy
    let familyRootID = CKRecord.ID(recordName: "FamilyRoot", zoneID: policyZoneID)
    record.parent = CKRecord.Reference(recordID: familyRootID, action: .none)

    // Set scope
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
      if let index = self.lockCodes.firstIndex(where: { $0.id == lockCode.id }) {
        self.lockCodes[index] = lockCode
      } else {
        self.lockCodes.append(lockCode)
      }
      Log.info("Saved lock code successfully", category: .cloudKit)
    } catch {
      Log.error("Failed to save lock code: \(error)", category: .cloudKit)
      throw CloudKitError.saveFailed(error)
    }
  }

  /// Delete a lock code from CloudKit (parent operation)
  func deleteLockCode(_ lockCode: FamilyLockCode) async throws {
    let recordID = CKRecord.ID(recordName: lockCode.id.uuidString, zoneID: policyZoneID)

    do {
      try await privateDatabase.deleteRecord(withID: recordID)
      self.lockCodes.removeAll { $0.id == lockCode.id }
      Log.info("Deleted lock code successfully", category: .cloudKit)
    } catch {
      throw CloudKitError.deleteFailed(error)
    }
  }

  // MARK: - Family Commands (Parent to Child)

  /// Send a command to a child device (parent operation)
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

  /// Fetch pending commands for this child device (child operation)
  func fetchPendingCommands() async throws -> [FamilyCommand] {
    // Fetch from shared database (commands shared via CKShare)
    let zones = try await sharedDatabase.allRecordZones()

    var allCommands: [FamilyCommand] = []

    // Get this device's user record name to filter commands for us
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
        Log.error("Failed to fetch commands from zone \(zone.zoneID): \(error)", category: .cloudKit)
      }
    }

    return allCommands
  }

  /// Delete a command after processing (child operation)
  func deleteCommand(_ command: FamilyCommand) async throws {
    let zones = try await sharedDatabase.allRecordZones()

    for zone in zones {
      let recordName = FamilyCommand.recordName(
        commandType: command.commandType, targetChildId: command.targetChildId, parentId: command.createdBy)
      let recordID = CKRecord.ID(recordName: recordName, zoneID: zone.zoneID)

      do {
        try await sharedDatabase.deleteRecord(withID: recordID)
        Log.info("Deleted command: \(command.commandType.rawValue)", category: .cloudKit)
        return
      } catch let error as CKError where error.code == .unknownItem {
        // Record not in this zone, try next
        continue
      } catch {
        Log.error("Failed to delete command: \(error)", category: .cloudKit)
        throw CloudKitError.deleteFailed(error)
      }
    }
  }

  private static let staleCommandMaxAgeDays = 7
  private static let secondsPerDay: TimeInterval = 86400

  /// Clean up stale commands older than maxAge (any client can call this)
  /// This ensures commands are cleaned up even if the target child leaves the family
  func cleanupStaleCommands(maxAgeDays: Int = CloudKitManager.staleCommandMaxAgeDays) async {
    let maxAge: TimeInterval = Double(maxAgeDays) * CloudKitManager.secondsPerDay
    let cutoffDate = Date().addingTimeInterval(-maxAge)

    // Clean up from shared database (for children)
    do {
      let zones = try await sharedDatabase.allRecordZones()
      for zone in zones {
        await cleanupStaleCommandsInZone(zone.zoneID, database: sharedDatabase, cutoffDate: cutoffDate)
      }
    } catch {
      Log.debug("No shared zones to cleanup: \(error)", category: .cloudKit)
    }

    // Clean up from private database (for parents)
    if policyZoneVerified {
      await cleanupStaleCommandsInZone(policyZoneID, database: privateDatabase, cutoffDate: cutoffDate)
    }
  }

  private func cleanupStaleCommandsInZone(_ zoneID: CKRecordZone.ID, database: CKDatabase, cutoffDate: Date) async {
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

  /// Fetch all lock codes created by this parent
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

      // Sort by createdAt ascending
      codes.sort { $0.createdAt < $1.createdAt }

      self.lockCodes = codes

      return codes
    } catch let error as CKError {
      if error.code == .zoneNotFound || error.code == .unknownItem {
        self.lockCodes = []
        return []
      }
      throw CloudKitError.fetchFailed(error)
    }
  }

  /// Fetch shared lock codes for verification (child operation)
  func fetchSharedLockCodes() async throws -> [FamilyLockCode] {
    guard let zone = await findSharedZoneByName() else {
      self.isConnectedToFamily = false
      self.sharedLockCodes = []
      return []
    }

    self.isConnectedToFamily = true

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
      Log.error("Failed to fetch lock codes from zone \(zone.zoneID): \(error)", category: .cloudKit)
    }

    self.sharedLockCodes = codes
    return codes
  }

  // MARK: - Family Sharing (Enroll Child)

  private let familyRootRecordName = "FamilyRoot"

  /// Create or get the family share for enrolling children
  /// Uses a root record approach since zone-wide sharing has limitations
  func getOrCreateFamilyShare() async throws -> CKShare {
    // Check if we already have a share
    if let existingShare = self.activeZoneShare {
      return existingShare
    }

    try await createPolicyZoneIfNeeded()

    // Check if the family root record and share already exist
    let rootRecordID = CKRecord.ID(recordName: familyRootRecordName, zoneID: policyZoneID)

    do {
      let rootRecord = try await privateDatabase.record(for: rootRecordID)

      // Check if it has a share
      if let shareRef = rootRecord.share {
        let share = try await privateDatabase.record(for: shareRef.recordID) as! CKShare
        self.activeZoneShare = share
        Log.debug("Found existing family share", category: .cloudKit)
        return share
      }

      // Root exists but no share - create share for it
      return try await createShareForRoot(rootRecord)
    } catch let error as CKError where error.code == .unknownItem {
      // Root record doesn't exist - create it and share
      Log.info("Creating new family root record", category: .cloudKit)
      let rootRecord = CKRecord(recordType: "FamilyRoot", recordID: rootRecordID)
      rootRecord["createdAt"] = Date()

      _ = try await privateDatabase.save(rootRecord)
      return try await createShareForRoot(rootRecord)
    }
  }

  private func createShareForRoot(_ rootRecord: CKRecord) async throws -> CKShare {
    let share = CKShare(rootRecord: rootRecord)
    share.publicPermission = .none  // Only invited participants
    share[CKShare.SystemFieldKey.title] = "Family Foqos Policies" as CKRecordValue

    // Save both the root record and share together
    let modifyOperation = CKModifyRecordsOperation(
      recordsToSave: [rootRecord, share],
      recordIDsToDelete: nil
    )
    modifyOperation.savePolicy = .changedKeys

    return try await withCheckedThrowingContinuation { continuation in
      modifyOperation.modifyRecordsResultBlock = { [weak self] result in
        switch result {
        case .success:
          Task { @MainActor in self?.activeZoneShare = share }
          Log.info("Created family share successfully", category: .cloudKit)
          continuation.resume(returning: share)
        case .failure(let error):
          Log.error("Failed to create family share: \(error)", category: .cloudKit)
          continuation.resume(throwing: CloudKitError.shareFailed(error))
        }
      }
      self.privateDatabase.add(modifyOperation)
    }
  }

  /// Get the current family share for use in UICloudSharingController
  func getCurrentFamilyShare() -> CKShare? {
    return activeZoneShare
  }

  /// Fetch and refresh share participants (for parent dashboard)
  func refreshShareParticipants() async {
    // Clean up any stale commands while we're syncing
    await cleanupStaleCommands()

    // Clear cached share to force fresh fetch from server
    self.activeZoneShare = nil

    let rootRecordID = CKRecord.ID(recordName: familyRootRecordName, zoneID: policyZoneID)
    do {
      // Fetch root record fresh from server
      let rootRecord = try await privateDatabase.record(for: rootRecordID)
      guard let shareRef = rootRecord.share else {
        Log.debug("No share exists", category: .cloudKit)
        self.shareParticipants = []
        return
      }

      // Fetch share record fresh from server
      let share = try await privateDatabase.record(for: shareRef.recordID) as! CKShare
      self.activeZoneShare = share

      // Get all participants except owner, log their statuses for debugging
      let participants = share.participants.filter { $0.role != .owner }
      for participant in participants {
        let name = participant.userIdentity.nameComponents?.formatted() ?? ""
        let email = participant.userIdentity.lookupInfo?.emailAddress ?? ""
        let displayInfo = !name.isEmpty ? name : (!email.isEmpty ? email : "Unknown")
        Log.debug("Participant '\(displayInfo)' status: \(participant.acceptanceStatus.rawValue)", category: .cloudKit)
      }

      self.shareParticipants = participants
      Log.info("Found \(participants.count) share participants", category: .cloudKit)
    } catch {
      Log.error("Failed to fetch share participants: \(error)", category: .cloudKit)
      self.shareParticipants = []
    }
  }

  // MARK: - Child Operations (Receive shared data)

  /// Accept a CloudKit share invitation (used for both parent and child)
  /// Role detection happens before this call — no auth gate here.
  func acceptShareDirect(metadata: CKShare.Metadata) async throws {
    do {
      _ = try await container.accept(metadata)
      Log.info("Accepted share successfully", category: .cloudKit)
    } catch {
      throw CloudKitError.shareAcceptFailed(error)
    }
  }

  /// Register this device as a FamilyMember in the shared zone
  /// Called after share acceptance — the accepting device writes its own record.
  func registerSelfAsFamilyMember(role: FamilyRole) async {
    guard let userRecordID = currentUserRecordID else {
      Log.error("No user record ID for self-registration", category: .cloudKit)
      return
    }

    guard let zone = await findSharedZoneByName() else {
      Log.error("No shared zone found for self-registration", category: .cloudKit)
      return
    }

    let userRecordName = userRecordID.recordName

    // Check if a FamilyMember record already exists for this user
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
          // Record exists — update role if different
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

      // No existing record — create one
      let displayName = await fetchCurrentUserDisplayName(in: zone.zoneID) ?? "Family Member"
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

  /// Self-healing: verify own FamilyMember record matches local app mode
  /// Called on app activation to correct role mismatches.
  func verifySelfFamilyMemberRecord() async {
    guard let zone = await findSharedZoneByName() else {
      self.isConnectedToFamily = false
      return
    }

    self.isConnectedToFamily = true

    guard let userRecordID = currentUserRecordID else { return }
    let userRecordName = userRecordID.recordName
    let localMode = AppModeManager.shared.currentMode

    // Only self-heal if in parent or child mode
    guard localMode == .parent || localMode == .child else { return }

    let expectedRole: FamilyRole = localMode == .parent ? .parent : .child

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
        if case .success(let record) = result {
          let recordRole = record[FamilyMember.RecordKey.role] as? String
          if recordRole != expectedRole.rawValue {
            record[FamilyMember.RecordKey.role] = expectedRole.rawValue
            _ = try await sharedDatabase.save(record)
            Log.info("Self-healed FamilyMember role to \(expectedRole.rawValue)", category: .cloudKit)
          }
          return
        }
      }

      // No record found — re-register
      Log.info("No self FamilyMember record found, re-registering", category: .cloudKit)
      await registerSelfAsFamilyMember(role: expectedRole)
    } catch {
      Log.error("Failed to verify self FamilyMember record: \(error)", category: .cloudKit)
    }
  }

  /// Fetch current user's display name from the share's participant list
  private func fetchCurrentUserDisplayName(in zoneID: CKRecordZone.ID) async -> String? {
    guard let userRecordID = currentUserRecordID else { return nil }
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

  // MARK: - Share Participant Sync (Parent Operation)

  /// Sync share participants to FamilyMember records (V2 behavior)
  /// - Does NOT create FamilyMember records for unmatched participants (they self-register)
  /// - Publishes unmatched accepted participants as `pendingParticipants`
  /// - Still removes stale FamilyMember records when a participant leaves the share
  func syncShareParticipantsToFamilyMembers() async throws {
    // Always fetch fresh share data - clear cache first
    self.activeZoneShare = nil

    let share: CKShare
    let rootRecordID = CKRecord.ID(recordName: familyRootRecordName, zoneID: policyZoneID)
    do {
      let rootRecord = try await privateDatabase.record(for: rootRecordID)
      guard let shareRef = rootRecord.share else {
        Log.info("CloudKitManager: No share exists yet", category: .cloudKit)
        self.pendingParticipants = []
        return
      }
      share = try await privateDatabase.record(for: shareRef.recordID) as! CKShare
      self.activeZoneShare = share
    } catch {
      Log.error("Could not fetch share: \(error)", category: .cloudKit)
      self.pendingParticipants = []
      return
    }

    // Get participants who have accepted (excluding owner)
    let acceptedParticipants = share.participants.filter {
      $0.acceptanceStatus == .accepted && $0.role != .owner
    }

    // Get the userRecordNames of all current accepted participants
    let currentParticipantRecordNames = Set(
      acceptedParticipants.compactMap { $0.userIdentity.userRecordID?.recordName }
    )

    Log.info("Found \(acceptedParticipants.count) accepted participants", category: .cloudKit)

    // Fetch current family members
    _ = try await fetchFamilyMembers()

    // Build set of matched userRecordNames (participants with FamilyMember records)
    let matchedRecordNames = Set(familyMembers.map { $0.userRecordName })

    // V2: Do NOT create FamilyMember records for unmatched participants.
    // Instead, publish them as pending — they will self-register when they open the app.
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
    self.pendingParticipants = pending

    if !pending.isEmpty {
      Log.info("\(pending.count) accepted participants pending self-registration", category: .cloudKit)
    }

    // Remove FamilyMembers who are no longer accepted participants (they left the share)
    for member in familyMembers {
      let userRecordName = member.userRecordName

      if !currentParticipantRecordNames.contains(userRecordName) {
        do {
          let recordID = CKRecord.ID(recordName: member.id.uuidString, zoneID: policyZoneID)
          try await privateDatabase.deleteRecord(withID: recordID)
          self.familyMembers.removeAll { $0.id == member.id }
          Log.info("Removed FamilyMember who left share: \(member.displayName)", category: .cloudKit)
        } catch {
          Log.error("Failed to remove stale FamilyMember: \(error)", category: .cloudKit)
        }
      }
    }
  }

  // MARK: - Child Family Connection Status

  /// Check if this device is connected to a family share
  /// Refreshes `isConnectedToFamily` via live CloudKit zone query
  func checkFamilyConnectionStatus() async -> Bool {
    let zone = await findSharedZoneByName()
    let connected = zone != nil
    self.isConnectedToFamily = connected
    return connected
  }

  /// Fetch the CKShare from the shared database (for child to present leave UI)
  func fetchShareFromSharedDatabase() async throws -> CKShare {
    guard let zone = await findSharedZoneByName() else {
      throw CloudKitError.notConnectedToFamily
    }

    // Find the FamilyRoot record which has the share attached
    let rootRecordID = CKRecord.ID(recordName: familyRootRecordName, zoneID: zone.zoneID)
    let rootRecord = try await sharedDatabase.record(for: rootRecordID)

    guard let shareRef = rootRecord.share else {
      throw CloudKitError.shareNotFound
    }

    let share = try await sharedDatabase.record(for: shareRef.recordID) as! CKShare
    return share
  }

  /// Clear local shared state after child leaves the family share
  func clearSharedState() {
    self.isConnectedToFamily = false
    self.sharedLockCodes = []
    Log.info("Cleared shared state after leaving family", category: .cloudKit)
  }

}

// MARK: - Error Types

enum CloudKitError: LocalizedError {
  case notSignedIn
  case zoneCreationFailed(Error)
  case saveFailed(Error)
  case deleteFailed(Error)
  case fetchFailed(Error)
  case shareFailed(Error)
  case shareAcceptFailed(Error)
  case notConnectedToFamily
  case shareNotFound

  var errorDescription: String? {
    switch self {
    case .notSignedIn:
      return "Please sign in to iCloud to sync parental controls."
    case .zoneCreationFailed(let error):
      return "Failed to set up cloud storage: \(error.localizedDescription)"
    case .saveFailed(let error):
      return "Failed to save: \(error.localizedDescription)"
    case .deleteFailed(let error):
      return "Failed to delete: \(error.localizedDescription)"
    case .fetchFailed(let error):
      return "Failed to fetch: \(error.localizedDescription)"
    case .shareFailed(let error):
      return "Failed to share: \(error.localizedDescription)"
    case .notConnectedToFamily:
      return "You are not connected to a family share."
    case .shareNotFound:
      return "Could not find the family share."
    case .shareAcceptFailed(let error):
      return "Failed to accept share: \(error.localizedDescription)"
    }
  }
}
