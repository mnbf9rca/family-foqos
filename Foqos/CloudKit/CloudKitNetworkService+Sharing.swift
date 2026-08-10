import CloudKit
import Foundation

extension CloudKitNetworkService {

  // MARK: - Family Sharing

  /// Decide which existing FamilyMembers to remove after a share-participant sync.
  ///
  /// FAIL-SAFE (#241): when any accepted participant has an unresolved userRecordID,
  /// `acceptedParticipantRecordNames` is incomplete, so a still-enrolled member could look
  /// departed. In that case remove nothing and let a later fully resolved sync clean up.
  nonisolated static func familyMembersToRemove(
    from existing: [FamilyMember],
    acceptedParticipantRecordNames: Set<String>,
    hasUnresolvedAcceptedParticipant: Bool
  ) -> [FamilyMember] {
    guard !hasUnresolvedAcceptedParticipant else { return [] }
    return existing.filter { !acceptedParticipantRecordNames.contains($0.userRecordName) }
  }

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
        Log.debug(
          ShareParticipantLog.statusMessage(
            userRecordName: participant.userIdentity.userRecordID?.recordName,
            acceptanceStatus: participant.acceptanceStatus.rawValue
          ),
          category: .cloudKit)
      }

      Log.info("Found \(participants.count) share participants", category: .cloudKit)
      return participants
    } catch {
      Log.error("Failed to fetch share participants: \(error)", category: .cloudKit)
      return []
    }
  }

  // MARK: - Share Permission Upgrade

  /// Upgrade share participant permissions from readOnly to readWrite.
  /// Required for child devices to write heartbeat records.
  func upgradeSharePermissionsIfNeeded() async {
    guard let share = activeZoneShare else {
      Log.debug("No active share to upgrade permissions", category: .cloudKit)
      return
    }

    let participants = share.participants.filter { $0.role != .owner }
    var needsSave = false

    for participant in participants {
      if participant.permission == .readOnly {
        participant.permission = .readWrite
        needsSave = true
        Log.info(
          "Upgrading participant permission to readWrite",
          category: .cloudKit)
      }
    }

    guard needsSave else { return }

    do {
      _ = try await privateDatabase.save(share)
      self.activeZoneShare = share
      Log.info("Share permissions upgraded to readWrite", category: .cloudKit)
    } catch {
      Log.error("Failed to upgrade share permissions: \(error)", category: .cloudKit)
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

    // Remove FamilyMembers who are no longer accepted participants.
    // FAIL-SAFE (#241): skip removals when any accepted participant is unresolved, so a
    // transient nil userRecordID cannot delete a still-enrolled child.
    let hasUnresolvedAcceptedParticipant = acceptedParticipants.contains {
      $0.userIdentity.userRecordID == nil
    }
    if hasUnresolvedAcceptedParticipant {
      Log.info(
        "Skipping FamilyMember cleanup: an accepted participant has an unresolved identity",
        category: .cloudKit)
    }
    let membersToRemove = Self.familyMembersToRemove(
      from: familyMembers,
      acceptedParticipantRecordNames: currentParticipantRecordNames,
      hasUnresolvedAcceptedParticipant: hasUnresolvedAcceptedParticipant
    )
    for member in membersToRemove {
      do {
        let recordID = CKRecord.ID(recordName: member.id.uuidString, zoneID: policyZoneID)
        try await privateDatabase.deleteRecord(withID: recordID)
        familyMembers.removeAll { $0.id == member.id }
        Log.info(
          "Removed FamilyMember who left share: \(member.redactedLogLabel)", category: .cloudKit)
      } catch {
        Log.error("Failed to remove stale FamilyMember: \(error)", category: .cloudKit)
      }
    }

    return ParticipantSyncResult(
      pendingParticipants: pending, familyMembers: familyMembers)
  }

  // MARK: - Share Ownership

  func getIsShareOwner() -> Bool {
    return activeZoneShare != nil
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

enum ShareParticipantLog {
  static func statusMessage(userRecordName: String?, acceptanceStatus: Int) -> String {
    "Participant \(userRecordName ?? "unknown") status: \(acceptanceStatus)"
  }
}
