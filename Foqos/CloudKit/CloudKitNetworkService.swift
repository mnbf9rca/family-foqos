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

  lazy var container: CKContainer = {
    CKContainer(identifier: CloudKitConstants.containerIdentifier)
  }()

  var privateDatabase: CKDatabase {
    container.privateCloudDatabase
  }

  var sharedDatabase: CKDatabase {
    container.sharedCloudDatabase
  }

  var policyZoneID: CKRecordZone.ID {
    CKRecordZone.ID(
      zoneName: CloudKitConstants.policyZoneName,
      ownerName: CKCurrentUserDefaultName)
  }

  var policyZoneVerified = false
  var activeZoneShare: CKShare?
  let familyRootRecordName = "FamilyRoot"

  static let staleCommandMaxAgeDays = 7
  static let secondsPerDay: TimeInterval = 86400

  // MARK: - Shared Infrastructure

  func findSharedZoneByName() async -> CKRecordZone? {
    do {
      let zones = try await sharedDatabase.allRecordZones()
      return zones.first { $0.zoneID.zoneName == CloudKitConstants.policyZoneName }
    } catch {
      Log.error("Failed to fetch shared zones: \(redactedErrorForLog(error))", category: .cloudKit)
      return nil
    }
  }

  func ensureFamilyRootExists() async throws {
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
}
