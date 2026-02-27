import CloudKit
import Foundation

/// Thin @MainActor state layer for CloudKit operations.
/// All network I/O is delegated to CloudKitNetworkService (a background actor, not @MainActor),
/// keeping the main thread free from CloudKit IPC.
@MainActor
class CloudKitManager: ObservableObject {
  static let shared = CloudKitManager()

  private let networkService = CloudKitNetworkService()

  // Published state
  @Published var currentUserRecordID: CKRecord.ID?
  @Published var isSignedIn = false
  @Published var familyMembers: [FamilyMember] = []
  @Published var lockCodes: [FamilyLockCode] = []
  @Published var sharedLockCodes: [FamilyLockCode] = []
  @Published var isConnectedToFamily = false
  @Published var shareParticipants: [CKShare.Participant] = []
  @Published var isLoading = false
  @Published var error: CloudKitError?
  @Published var shareAcceptedMessage: String?
  @Published var shareAcceptanceIsError = false
  @Published var pendingParticipants: [CKShare.Participant] = []
  @Published var isShareOwner = false

  // MARK: - Initialization

  private init() {
    // Account status is checked lazily when needed (e.g., first ensureUserRecordID call),
    // not eagerly at init time. This avoids blocking the main actor during app startup.
  }

  // MARK: - Account Status

  func checkAccountStatus() async {
    let result = await networkService.checkAccountStatus()
    self.isSignedIn = result.isSignedIn
    if result.isSignedIn, let recordID = result.userRecordID {
      self.currentUserRecordID = recordID
    } else {
      self.currentUserRecordID = nil
    }
  }

  // MARK: - User Record

  func ensureUserRecordID() async throws -> CKRecord.ID {
    let recordID = try await networkService.ensureUserRecordID(cached: currentUserRecordID)
    self.currentUserRecordID = recordID
    self.isSignedIn = true
    return recordID
  }

  // MARK: - Zone Management

  func createPolicyZoneIfNeeded() async throws {
    try await networkService.createPolicyZoneIfNeeded()
  }

  // MARK: - Family Member Management

  func saveFamilyMember(_ member: FamilyMember) async throws {
    try await networkService.saveFamilyMember(member)
    if let index = self.familyMembers.firstIndex(where: { $0.id == member.id }) {
      self.familyMembers[index] = member
    } else {
      self.familyMembers.append(member)
    }
  }

  func deleteFamilyMember(_ member: FamilyMember) async throws {
    try await networkService.deleteFamilyMember(member)
    self.familyMembers.removeAll { $0.id == member.id }
    await refreshShareParticipants()
  }

  func removeShareParticipant(_ participant: CKShare.Participant) async throws {
    try await networkService.removeShareParticipant(participant)
    await refreshShareParticipants()
  }

  func fetchFamilyMembers() async throws -> [FamilyMember] {
    let members = try await networkService.fetchFamilyMembers()
    self.familyMembers = members
    return members
  }

  // MARK: - Lock Code Management

  func saveLockCode(_ lockCode: FamilyLockCode) async throws {
    try await networkService.saveLockCode(lockCode)
    if let index = self.lockCodes.firstIndex(where: { $0.id == lockCode.id }) {
      self.lockCodes[index] = lockCode
    } else {
      self.lockCodes.append(lockCode)
    }
  }

  func deleteLockCode(_ lockCode: FamilyLockCode) async throws {
    try await networkService.deleteLockCode(lockCode)
    self.lockCodes.removeAll { $0.id == lockCode.id }
  }

  func fetchLockCodes() async throws -> [FamilyLockCode] {
    let codes = try await networkService.fetchLockCodes()
    self.lockCodes = codes
    return codes
  }

  func fetchSharedLockCodes() async throws -> [FamilyLockCode] {
    let result = try await networkService.fetchSharedLockCodes()
    self.isConnectedToFamily = result.isConnected
    self.sharedLockCodes = result.codes
    return result.codes
  }

  // MARK: - Family Commands

  func sendCommand(_ command: FamilyCommand) async throws {
    try await networkService.sendCommand(command)
  }

  func fetchPendingCommands() async throws -> [FamilyCommand] {
    return try await networkService.fetchPendingCommands(currentUserRecordID: currentUserRecordID)
  }

  func deleteCommand(_ command: FamilyCommand) async throws {
    try await networkService.deleteCommand(command)
  }

  func cleanupStaleCommands() async {
    await networkService.cleanupStaleCommands()
  }

  // MARK: - Family Sharing

  func getOrCreateFamilyShare() async throws -> CKShare {
    return try await networkService.getOrCreateFamilyShare()
  }

  func getCurrentFamilyShare() async -> CKShare? {
    return await networkService.getCurrentFamilyShare()
  }

  func refreshShareParticipants() async {
    let participants = await networkService.refreshShareParticipants()
    self.shareParticipants = participants
    self.isShareOwner = await networkService.getIsShareOwner()
  }

  // MARK: - Share Acceptance

  func acceptShareDirect(metadata: CKShare.Metadata) async throws {
    try await networkService.acceptShareDirect(metadata: metadata)
  }

  func registerSelfAsFamilyMember(role: FamilyRole) async {
    guard let userRecordID = currentUserRecordID else {
      Log.error("No user record ID for self-registration", category: .cloudKit)
      return
    }
    await networkService.registerSelfAsFamilyMember(role: role, userRecordID: userRecordID)
  }

  // MARK: - Verification

  func verifySelfFamilyMemberRecord() async {
    let result = await networkService.verifySelfFamilyMember(
      cachedUserRecordID: currentUserRecordID,
      localMode: AppModeManager.shared.currentMode
    )

    self.isConnectedToFamily = result.isConnected
    if let userRecordID = result.userRecordID, self.currentUserRecordID == nil {
      self.currentUserRecordID = userRecordID
    }
    if let isSignedIn = result.isSignedIn {
      self.isSignedIn = isSignedIn
    }
    if let mode = result.enforcedMode {
      AppModeManager.shared.selectMode(mode)
    }
  }

  // MARK: - Share Participant Sync

  func syncShareParticipantsToFamilyMembers() async throws {
    let result = try await networkService.syncShareParticipantsToFamilyMembers()
    self.pendingParticipants = result.pendingParticipants
    self.familyMembers = result.familyMembers
  }

  // MARK: - Connection Status

  func checkFamilyConnectionStatus() async -> Bool {
    let connected = await networkService.checkFamilyConnectionStatus()
    self.isConnectedToFamily = connected
    return connected
  }

  func fetchShareFromSharedDatabase() async throws -> CKShare {
    return try await networkService.fetchShareFromSharedDatabase()
  }

  /// Clear local shared state after child leaves the family share (no network I/O)
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
