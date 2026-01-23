import CloudKit
import Foundation

/// Manages CloudKit operations for Family Policy sync between parent and child devices
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
    @Published var policies: [FamilyPolicy] = []
    @Published var familyMembers: [FamilyMember] = []  // Family members (parents and children)
    @Published var sharedPolicies: [FamilyPolicy] = []  // Policies shared with this user (child)
    @Published var lockCodes: [FamilyLockCode] = []  // Lock codes created by this parent
    @Published var sharedLockCodes: [FamilyLockCode] = []  // Lock codes shared with this user (child)
    @Published var isConnectedToFamily = false  // For children: whether connected to parent's share
    @Published var shareParticipants: [CKShare.Participant] = []  // For parents: pending/accepted invitations
    @Published var isLoading = false
    @Published var error: CloudKitError?

    // Active zone share (for enrolling children)
    private var activeZoneShare: CKShare?

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
            await MainActor.run {
                self.isSignedIn = (status == .available)
            }

            if status == .available {
                await fetchCurrentUserRecordID()
            }
        } catch {
            print("CloudKit account status error: \(error)")
            await MainActor.run {
                self.isSignedIn = false
            }
        }
    }

    /// Fetch the current user's record ID
    private func fetchCurrentUserRecordID() async {
        do {
            let recordID = try await container.userRecordID()
            await MainActor.run {
                self.currentUserRecordID = recordID
            }
        } catch {
            print("Failed to fetch user record ID: \(error)")
        }
    }

    // MARK: - Zone Management

    /// Create the custom zone for storing policies (enables sharing)
    func createPolicyZoneIfNeeded() async throws {
        let zone = CKRecordZone(zoneID: policyZoneID)

        do {
            _ = try await privateDatabase.save(zone)
            print("Created policy zone: \(policyZoneName)")
        } catch let error as CKError {
            // These errors mean zone already exists - that's fine
            if error.code == .serverRecordChanged {
                print("Policy zone already exists (serverRecordChanged)")
                return
            }
            // partialFailure can also indicate zone exists
            if error.code == .partialFailure {
                print("Policy zone already exists (partialFailure)")
                return
            }
            throw CloudKitError.zoneCreationFailed(error)
        }
    }

    // MARK: - Parent Operations (Create/Manage Policies)

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
            print("CloudKitManager: FamilyRoot exists")
        } catch let error as CKError where error.code == .unknownItem {
            print("CloudKitManager: Creating FamilyRoot record")
            let rootRecord = CKRecord(recordType: "FamilyRoot", recordID: rootRecordID)
            rootRecord["createdAt"] = Date()
            _ = try await privateDatabase.save(rootRecord)
            print("CloudKitManager: FamilyRoot created")
        }
    }

    /// Save a new policy to CloudKit (parent operation)
    func savePolicy(_ policy: FamilyPolicy) async throws {
        print("CloudKitManager: Starting to save policy '\(policy.name)'")

        await MainActor.run { self.isLoading = true }
        defer { Task { await MainActor.run { self.isLoading = false } } }

        // Ensure zone and FamilyRoot exist
        print("CloudKitManager: Ensuring zone exists...")
        try await createPolicyZoneIfNeeded()
        try await ensureFamilyRootExists()

        let record = policy.toCKRecord(in: policyZoneID)
        print("CloudKitManager: Created CKRecord with ID: \(record.recordID)")

        do {
            print("CloudKitManager: Saving to CloudKit...")
            let savedRecord = try await privateDatabase.save(record)
            print("CloudKitManager: Successfully saved record: \(savedRecord.recordID)")

            await MainActor.run {
                if let index = self.policies.firstIndex(where: { $0.id == policy.id }) {
                    self.policies[index] = policy
                    print("CloudKitManager: Updated existing policy in local array")
                } else {
                    self.policies.append(policy)
                    print("CloudKitManager: Added new policy to local array. Total policies: \(self.policies.count)")
                }
            }
            print("Saved policy: \(policy.name)")
        } catch {
            print("CloudKitManager: FAILED to save - \(error)")
            throw CloudKitError.saveFailed(error)
        }
    }

    /// Delete a policy from CloudKit (parent operation)
    func deletePolicy(_ policy: FamilyPolicy) async throws {
        await MainActor.run { self.isLoading = true }
        defer { Task { await MainActor.run { self.isLoading = false } } }

        let recordID = CKRecord.ID(recordName: policy.id.uuidString, zoneID: policyZoneID)

        do {
            try await privateDatabase.deleteRecord(withID: recordID)
            await MainActor.run {
                self.policies.removeAll { $0.id == policy.id }
            }
            print("Deleted policy: \(policy.name)")
        } catch {
            throw CloudKitError.deleteFailed(error)
        }
    }

    /// Fetch all policies created by this user (parent operation)
    func fetchMyPolicies() async throws -> [FamilyPolicy] {
        await MainActor.run { self.isLoading = true }
        defer { Task { await MainActor.run { self.isLoading = false } } }

        // Ensure zone exists before fetching
        do {
            try await createPolicyZoneIfNeeded()
        } catch {
            // Zone creation failed, but might already exist - continue to try fetch
            print("Zone creation note: \(error)")
        }

        let query = CKQuery(
            recordType: FamilyPolicy.recordType,
            predicate: NSPredicate(value: true)
        )
        // Note: Don't use sortDescriptors - can cause issues with CloudKit schema
        // Sort in-memory instead

        do {
            let (results, _) = try await privateDatabase.records(
                matching: query,
                inZoneWith: policyZoneID
            )

            var fetchedPolicies: [FamilyPolicy] = []
            for (_, result) in results {
                if case .success(let record) = result,
                   let policy = FamilyPolicy(from: record) {
                    fetchedPolicies.append(policy)
                }
            }

            // Sort by createdAt descending in-memory
            fetchedPolicies.sort { $0.createdAt > $1.createdAt }

            await MainActor.run {
                self.policies = fetchedPolicies
            }

            return fetchedPolicies
        } catch let error as CKError {
            // If zone doesn't exist or is empty, return empty array (not an error)
            if error.code == .zoneNotFound || error.code == .unknownItem {
                await MainActor.run {
                    self.policies = []
                }
                return []
            }
            throw CloudKitError.fetchFailed(error)
        } catch {
            throw CloudKitError.fetchFailed(error)
        }
    }

    // MARK: - Family Member Management

    /// Save a family member to CloudKit
    func saveFamilyMember(_ member: FamilyMember) async throws {
        print("CloudKitManager: Saving family member '\(member.displayName)' as \(member.role.displayName)")

        try await createPolicyZoneIfNeeded()
        try await ensureFamilyRootExists()

        let record = member.toCKRecord(in: policyZoneID)

        do {
            _ = try await privateDatabase.save(record)
            await MainActor.run {
                if let index = self.familyMembers.firstIndex(where: { $0.id == member.id }) {
                    self.familyMembers[index] = member
                } else {
                    self.familyMembers.append(member)
                }
            }
            print("CloudKitManager: Saved family member: \(member.displayName)")
        } catch {
            print("CloudKitManager: Failed to save family member - \(error)")
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
            await MainActor.run {
                self.familyMembers.removeAll { $0.id == member.id }
            }
            print("CloudKitManager: Deleted family member: \(member.displayName)")
        } catch {
            throw CloudKitError.deleteFailed(error)
        }
    }

    /// Revoke a user's access to the family share
    private func revokeShareAccess(forUserRecordName userRecordName: String?) async {
        guard let userRecordName = userRecordName else {
            print("CloudKitManager: No userRecordName to revoke")
            return
        }

        do {
            // Get the current share
            let rootRecordID = CKRecord.ID(recordName: familyRootRecordName, zoneID: policyZoneID)
            let rootRecord = try await privateDatabase.record(for: rootRecordID)

            guard let shareRef = rootRecord.share else {
                print("CloudKitManager: No share exists to revoke from")
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
                activeZoneShare = share

                print("CloudKitManager: Revoked share access for \(userRecordName)")

                // Refresh participants list
                await refreshShareParticipants()
            } else {
                print("CloudKitManager: Participant not found in share")
            }
        } catch {
            print("CloudKitManager: Failed to revoke share access - \(error)")
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
                   let member = FamilyMember(from: record) {
                    members.append(member)
                }
            }

            // Sort by enrolledAt ascending
            members.sort { $0.enrolledAt < $1.enrolledAt }

            await MainActor.run {
                self.familyMembers = members
            }

            return members
        } catch let error as CKError {
            if error.code == .zoneNotFound || error.code == .unknownItem {
                await MainActor.run {
                    self.familyMembers = []
                }
                return []
            }
            throw CloudKitError.fetchFailed(error)
        }
    }

    // MARK: - Lock Code Management

    /// Save a lock code to CloudKit (parent operation)
    func saveLockCode(_ lockCode: FamilyLockCode) async throws {
        print("CloudKitManager: Saving lock code")

        try await createPolicyZoneIfNeeded()
        try await ensureFamilyRootExists()

        let record = lockCode.toCKRecord(in: policyZoneID)

        do {
            _ = try await privateDatabase.save(record)
            await MainActor.run {
                if let index = self.lockCodes.firstIndex(where: { $0.id == lockCode.id }) {
                    self.lockCodes[index] = lockCode
                } else {
                    self.lockCodes.append(lockCode)
                }
            }
            print("CloudKitManager: Saved lock code successfully")
        } catch {
            print("CloudKitManager: Failed to save lock code - \(error)")
            throw CloudKitError.saveFailed(error)
        }
    }

    /// Delete a lock code from CloudKit (parent operation)
    func deleteLockCode(_ lockCode: FamilyLockCode) async throws {
        let recordID = CKRecord.ID(recordName: lockCode.id.uuidString, zoneID: policyZoneID)

        do {
            try await privateDatabase.deleteRecord(withID: recordID)
            await MainActor.run {
                self.lockCodes.removeAll { $0.id == lockCode.id }
            }
            print("CloudKitManager: Deleted lock code successfully")
        } catch {
            throw CloudKitError.deleteFailed(error)
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
                   let code = FamilyLockCode(from: record) {
                    codes.append(code)
                }
            }

            // Sort by createdAt ascending
            codes.sort { $0.createdAt < $1.createdAt }

            await MainActor.run {
                self.lockCodes = codes
            }

            return codes
        } catch let error as CKError {
            if error.code == .zoneNotFound || error.code == .unknownItem {
                await MainActor.run {
                    self.lockCodes = []
                }
                return []
            }
            throw CloudKitError.fetchFailed(error)
        }
    }

    /// Fetch shared lock codes for verification (child operation)
    func fetchSharedLockCodes() async throws -> [FamilyLockCode] {
        // Fetch from shared database (codes shared via CKShare)
        let zones = try await sharedDatabase.allRecordZones()

        // Update connection status based on whether we have shared zones
        await MainActor.run {
            self.isConnectedToFamily = !zones.isEmpty
        }

        var allCodes: [FamilyLockCode] = []

        for zone in zones {
            let query = CKQuery(
                recordType: FamilyLockCode.recordType,
                predicate: NSPredicate(value: true)
            )

            do {
                let (results, _) = try await sharedDatabase.records(
                    matching: query,
                    inZoneWith: zone.zoneID
                )

                for (_, result) in results {
                    if case .success(let record) = result,
                       let code = FamilyLockCode(from: record) {
                        allCodes.append(code)
                    }
                }
            } catch {
                print("Failed to fetch lock codes from zone \(zone.zoneID): \(error)")
            }
        }

        await MainActor.run {
            self.sharedLockCodes = allCodes
        }

        return allCodes
    }

    // MARK: - Family Sharing (Enroll Child)

    private let familyRootRecordName = "FamilyRoot"

    /// Create or get the family share for enrolling children
    /// Uses a root record approach since zone-wide sharing has limitations
    func getOrCreateFamilyShare() async throws -> CKShare {
        // Check if we already have a share
        if let existingShare = activeZoneShare {
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
                activeZoneShare = share
                print("CloudKitManager: Found existing family share")
                return share
            }

            // Root exists but no share - create share for it
            return try await createShareForRoot(rootRecord)
        } catch let error as CKError where error.code == .unknownItem {
            // Root record doesn't exist - create it and share
            print("CloudKitManager: Creating new family root record")
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
            modifyOperation.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    self.activeZoneShare = share
                    print("CloudKitManager: Created family share successfully")
                    continuation.resume(returning: share)
                case .failure(let error):
                    print("CloudKitManager: Failed to create family share - \(error)")
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
        // Try to get the share
        let rootRecordID = CKRecord.ID(recordName: familyRootRecordName, zoneID: policyZoneID)
        do {
            let rootRecord = try await privateDatabase.record(for: rootRecordID)
            guard let shareRef = rootRecord.share else {
                print("CloudKitManager: No share exists")
                await MainActor.run { self.shareParticipants = [] }
                return
            }

            let share = try await privateDatabase.record(for: shareRef.recordID) as! CKShare
            activeZoneShare = share

            // Get all participants except owner
            let participants = share.participants.filter { $0.role != .owner }
            await MainActor.run {
                self.shareParticipants = participants
            }
            print("CloudKitManager: Found \(participants.count) share participants")
        } catch {
            print("CloudKitManager: Failed to fetch share participants - \(error)")
            await MainActor.run { self.shareParticipants = [] }
        }
    }

    // MARK: - Sharing (Parent creates share for child) - DEPRECATED
    // Use getOrCreateZoneShare() instead for zone-level sharing

    /// Create a CKShare for a policy to share with a child
    @available(*, deprecated, message: "Use getOrCreateZoneShare() for zone-level sharing instead")
    func createShare(for policy: FamilyPolicy) async throws -> CKShare {
        // Fetch the record first
        let recordID = CKRecord.ID(recordName: policy.id.uuidString, zoneID: policyZoneID)
        let record = try await privateDatabase.record(for: recordID)

        // Create share
        let share = CKShare(rootRecord: record)
        share.publicPermission = .none  // Only invited participants
        share[CKShare.SystemFieldKey.title] = "Family Foqos Policy: \(policy.name)" as CKRecordValue

        // Save both the record and share
        let modifyOperation = CKModifyRecordsOperation(
            recordsToSave: [record, share],
            recordIDsToDelete: nil
        )
        modifyOperation.savePolicy = .changedKeys

        return try await withCheckedThrowingContinuation { continuation in
            modifyOperation.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume(returning: share)
                case .failure(let error):
                    continuation.resume(throwing: CloudKitError.shareFailed(error))
                }
            }
            privateDatabase.add(modifyOperation)
        }
    }

    // MARK: - Child Operations (Receive shared policies)

    /// Fetch all policies shared with this user (child operation)
    func fetchSharedPolicies() async throws -> [FamilyPolicy] {
        await MainActor.run { self.isLoading = true }
        defer { Task { await MainActor.run { self.isLoading = false } } }

        // Fetch all shared record zones
        let zones = try await sharedDatabase.allRecordZones()

        var allPolicies: [FamilyPolicy] = []

        for zone in zones {
            let query = CKQuery(
                recordType: FamilyPolicy.recordType,
                predicate: NSPredicate(value: true)
            )

            do {
                let (results, _) = try await sharedDatabase.records(
                    matching: query,
                    inZoneWith: zone.zoneID
                )

                for (_, result) in results {
                    if case .success(let record) = result,
                       let policy = FamilyPolicy(from: record) {
                        allPolicies.append(policy)
                    }
                }
            } catch {
                print("Failed to fetch policies from zone \(zone.zoneID): \(error)")
            }
        }

        await MainActor.run {
            self.sharedPolicies = allPolicies
        }

        return allPolicies
    }

    /// Accept a CloudKit share invitation (child operation)
    func acceptShare(metadata: CKShare.Metadata) async throws {
        do {
            _ = try await container.accept(metadata)
            // Refresh shared policies after accepting
            _ = try await fetchSharedPolicies()
            // Also fetch shared lock codes
            _ = try? await fetchSharedLockCodes()
            print("Accepted share successfully")
        } catch {
            throw CloudKitError.shareAcceptFailed(error)
        }
    }

    // MARK: - Share Participant Sync (Parent Operation)

    /// Sync share participants to FamilyMember records
    /// Call this from parent dashboard to see children who accepted the share
    func syncShareParticipantsToFamilyMembers() async throws {
        // First ensure we have the share
        let share: CKShare
        if let existingShare = activeZoneShare {
            share = existingShare
        } else {
            // Try to fetch the existing share
            let rootRecordID = CKRecord.ID(recordName: familyRootRecordName, zoneID: policyZoneID)
            do {
                let rootRecord = try await privateDatabase.record(for: rootRecordID)
                guard let shareRef = rootRecord.share else {
                    print("CloudKitManager: No share exists yet")
                    return
                }
                share = try await privateDatabase.record(for: shareRef.recordID) as! CKShare
                activeZoneShare = share
            } catch {
                print("CloudKitManager: Could not fetch share - \(error)")
                return
            }
        }

        // Get participants who have accepted (excluding owner)
        let acceptedParticipants = share.participants.filter {
            $0.acceptanceStatus == .accepted && $0.role != .owner
        }

        print("CloudKitManager: Found \(acceptedParticipants.count) accepted participants")

        // Fetch current family members to avoid duplicates
        _ = try await fetchFamilyMembers()

        for participant in acceptedParticipants {
            guard let userRecordID = participant.userIdentity.userRecordID else {
                continue
            }

            // Check if this participant already has a FamilyMember record
            let existingMember = familyMembers.first {
                $0.userRecordName == userRecordID.recordName
            }

            if existingMember == nil {
                // Create FamilyMember for this participant
                let displayName = participant.userIdentity.nameComponents?.formatted() ??
                    participant.userIdentity.lookupInfo?.emailAddress ??
                    "Family Member"

                let newMember = FamilyMember(
                    userRecordName: userRecordID.recordName,
                    displayName: displayName,
                    role: .child  // Participants who accept are children
                )

                do {
                    try await saveFamilyMember(newMember)
                    print("CloudKitManager: Created FamilyMember for participant: \(displayName)")
                } catch {
                    print("CloudKitManager: Failed to create FamilyMember - \(error)")
                }
            }
        }
    }

    // MARK: - Child Family Connection Status

    /// Check if this device (as child) is connected to a family share
    func checkFamilyConnectionStatus() async -> Bool {
        do {
            let zones = try await sharedDatabase.allRecordZones()
            return !zones.isEmpty
        } catch {
            print("CloudKitManager: Failed to check family connection - \(error)")
            return false
        }
    }

    // MARK: - Subscriptions (Real-time updates)

    /// Subscribe to policy changes (for children to receive real-time updates)
    func subscribeToSharedPolicyChanges() async throws {
        let subscription = CKDatabaseSubscription(subscriptionID: "shared-policy-changes")

        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true  // Silent push

        subscription.notificationInfo = notificationInfo

        do {
            _ = try await sharedDatabase.save(subscription)
            print("Subscribed to shared policy changes")
        } catch let error as CKError {
            // Subscription already exists is OK
            if error.code != .serverRejectedRequest {
                throw CloudKitError.subscriptionFailed(error)
            }
        }
    }

    /// Handle incoming push notification for policy changes
    func handlePushNotification(_ userInfo: [AnyHashable: Any]) async {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) else {
            return
        }

        if notification.subscriptionID == "shared-policy-changes" {
            // Refresh shared policies
            do {
                _ = try await fetchSharedPolicies()
            } catch {
                print("Failed to refresh policies after push: \(error)")
            }
        }
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
    case subscriptionFailed(Error)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Please sign in to iCloud to sync parental controls."
        case .zoneCreationFailed(let error):
            return "Failed to set up cloud storage: \(error.localizedDescription)"
        case .saveFailed(let error):
            return "Failed to save policy: \(error.localizedDescription)"
        case .deleteFailed(let error):
            return "Failed to delete policy: \(error.localizedDescription)"
        case .fetchFailed(let error):
            return "Failed to fetch policies: \(error.localizedDescription)"
        case .shareFailed(let error):
            return "Failed to share policy: \(error.localizedDescription)"
        case .shareAcceptFailed(let error):
            return "Failed to accept shared policy: \(error.localizedDescription)"
        case .subscriptionFailed(let error):
            return "Failed to subscribe to updates: \(error.localizedDescription)"
        }
    }
}
