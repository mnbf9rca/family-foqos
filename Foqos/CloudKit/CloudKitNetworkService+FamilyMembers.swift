import CloudKit
import Foundation

extension CloudKitNetworkService {

  // MARK: - Family Member Management

  func saveFamilyMember(_ member: FamilyMember) async throws {
    // PII-SAFE LOG (#252): log the UUID + role, never the real person name.
    Log.info(
      "Saving family member \(member.redactedLogLabel) as \(member.role.displayName)",
      category: .cloudKit)

    try await createPolicyZoneIfNeeded()
    try await ensureFamilyRootExists()

    let record = member.toCKRecord(in: policyZoneID)

    do {
      _ = try await privateDatabase.save(record)
      Log.info("Saved family member: \(member.redactedLogLabel)", category: .cloudKit)
    } catch {
      Log.error("Failed to save family member: \(redactedErrorForLog(error))", category: .cloudKit)
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
      Log.info("Deleted family member: \(member.redactedLogLabel)", category: .cloudKit)
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

    let participantId = ShareParticipantLog.label(
      userRecordName: participant.userIdentity.userRecordID?.recordName)
    // PII-SAFE LOG (#252): log only the opaque CK record name, never nameComponents/email.
    Log.info("Removed participant \(participantId) from share", category: .cloudKit)
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
        let participantId = ShareParticipantLog.label(userRecordName: userRecordName)
        Log.info("Revoked share access for \(participantId)", category: .cloudKit)
        // NOTE: Manager handles refreshShareParticipants() after this call
      } else {
        Log.debug("Participant not found in share", category: .cloudKit)
      }
    } catch {
      Log.error("Failed to revoke share access: \(redactedErrorForLog(error))", category: .cloudKit)
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
}
