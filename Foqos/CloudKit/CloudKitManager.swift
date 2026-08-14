import CloudKit
import Foundation

enum AccountAvailability: Equatable {
  case available(CKRecord.ID?)
  case noAccount
  case ambiguous

  init(from status: CKAccountStatus, recordID: CKRecord.ID?, error: Error?) {
    if error != nil {
      self = .ambiguous
      return
    }

    switch status {
    case .available:
      self = .available(recordID)
    case .noAccount:
      self = .noAccount
    default:
      self = .ambiguous
    }
  }
}

struct FamilyRevocationNoticeStore {
  private static let pendingKey = "family_foqos_pending_family_revocation_notice"

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  var isPending: Bool {
    defaults.bool(forKey: Self.pendingKey)
  }

  func markPending() {
    defaults.set(true, forKey: Self.pendingKey)
  }

  func clearPending() {
    defaults.removeObject(forKey: Self.pendingKey)
  }
}

/// Thin @MainActor state layer for CloudKit operations.
/// All network I/O is delegated to CloudKitNetworkService (a background actor, not @MainActor),
/// keeping the main thread free from CloudKit IPC.
@MainActor
class CloudKitManager: ObservableObject {
  static let shared = CloudKitManager()
  static let familyRevocationAlertTitle = "Family Connection Removed"
  static let familyRevocationAlertMessage =
    "This device is no longer connected to its Family Foqos family in iCloud, so it switched to Individual mode. To reconnect, ask a parent to send a new invitation."

  private let networkService = CloudKitNetworkService()
  private let familyRevocationNoticeStore: FamilyRevocationNoticeStore

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
  @Published var familyRevocationMessage: String?
  @Published var pendingParticipants: [CKShare.Participant] = []
  @Published var isShareOwner = false

  // MARK: - Initialization

  private init(
    familyRevocationNoticeStore: FamilyRevocationNoticeStore = FamilyRevocationNoticeStore()
  ) {
    self.familyRevocationNoticeStore = familyRevocationNoticeStore
    self.familyRevocationMessage = Self.initialFamilyRevocationMessage(
      pendingNoticeStore: familyRevocationNoticeStore)
    // Account status is checked lazily when needed (e.g., first ensureUserRecordID call),
    // not eagerly at init time. This avoids blocking the main actor during app startup.
  }

  static func initialFamilyRevocationMessage(
    pendingNoticeStore: FamilyRevocationNoticeStore
  ) -> String? {
    pendingNoticeStore.isPending ? familyRevocationAlertMessage : nil
  }

  #if DEBUG
    static func makeForTesting(
      pendingNoticeStore: FamilyRevocationNoticeStore
    ) -> CloudKitManager {
      CloudKitManager(familyRevocationNoticeStore: pendingNoticeStore)
    }
  #endif

  // MARK: - Account Status

  func checkAccountStatus() async {
    guard !ScreenshotDemoMode.isActive else { return }
    let result = await networkService.checkAccountStatus()
    self.isSignedIn = result.isSignedIn
    if result.isSignedIn, let recordID = result.userRecordID {
      self.currentUserRecordID = recordID
    } else {
      self.currentUserRecordID = nil
    }
  }

  func accountAvailability() async -> AccountAvailability {
    let raw = await networkService.accountStatusDetailed()
    let availability = AccountAvailability(
      from: raw.status, recordID: raw.userRecordID, error: raw.error)

    switch availability {
    case .available(let id):
      isSignedIn = true
      if let id { currentUserRecordID = id }
    case .noAccount:
      isSignedIn = false
      currentUserRecordID = nil
    case .ambiguous:
      break
    }

    return availability
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

  func ensureSharedDatabaseSubscription() async throws {
    try await networkService.ensureSharedDatabaseSubscription()
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
    guard !ScreenshotDemoMode.isActive else { return familyMembers }
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

  func fetchSharedLockCodes() async throws -> (codes: [FamilyLockCode], isConnected: Bool) {
    let result = try await networkService.fetchSharedLockCodes()
    self.isConnectedToFamily = result.isConnected
    self.sharedLockCodes = result.codes
    return result
  }

  // MARK: - Family Commands

  func sendCommand(_ command: FamilyCommand) async throws {
    try await networkService.sendCommand(command)
  }

  func commandIsPending(_ command: FamilyCommand) async throws -> Bool {
    try await networkService.commandIsPending(command)
  }

  func fetchPendingCommands() async throws -> (
    commands: [FamilyCommand], isConnected: Bool
  ) {
    let userRecordID = try await Self.resolvePendingCommandUserRecordID(
      cached: currentUserRecordID
    ) {
      try await self.ensureUserRecordID()
    }
    return try await networkService.fetchPendingCommands(currentUserRecordID: userRecordID)
  }

  static func resolvePendingCommandUserRecordID(
    cached: CKRecord.ID?,
    fetch: () async throws -> CKRecord.ID
  ) async rethrows -> CKRecord.ID {
    if let cached { return cached }
    return try await fetch()
  }

  func deleteCommand(_ command: FamilyCommand) async throws {
    try await networkService.deleteCommand(command)
  }

  func cleanupStaleCommands() async {
    await networkService.cleanupStaleCommands()
  }

  func resetFamilySharing(clearEverything: Bool) async throws {
    try await networkService.resetFamilySharing(clearEverything: clearEverything)
    if clearEverything {
      clearSharedState()
      familyMembers = []
      lockCodes = []
      pendingParticipants = []
      shareParticipants = []
    } else {
      lockCodes = []
      sharedLockCodes = []
    }
  }

  // MARK: - Family Sharing

  func getOrCreateFamilyShare() async throws -> CKShare {
    return try await networkService.getOrCreateFamilyShare()
  }

  func getCurrentFamilyShare() async -> CKShare? {
    return await networkService.getCurrentFamilyShare()
  }

  func refreshShareParticipants() async {
    guard !ScreenshotDemoMode.isActive else { return }
    let participants = await networkService.refreshShareParticipants()
    self.shareParticipants = participants
    self.isShareOwner = await networkService.getIsShareOwner()

    // Upgrade child permissions to readWrite for heartbeat writes (#190)
    if isShareOwner {
      await networkService.upgradeSharePermissionsIfNeeded()
    }
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

  nonisolated static func isConfirmedRevocation(
    isConnected: Bool,
    isSignedIn: Bool,
    enforcedMode: AppMode?,
    currentMode: AppMode
  ) -> Bool {
    !isConnected
      && isSignedIn
      && enforcedMode == .individual
      && currentMode == .child
  }

  func handleConfirmedFamilyRevocation(
    cleanup: () -> Void = {
      AuthorizationVerifier.shared.handleConfirmedCloudKitRevocation()
    },
    markNoticePending: (() -> Void)? = nil
  ) {
    cleanup()
    if let markNoticePending {
      markNoticePending()
    } else {
      familyRevocationNoticeStore.markPending()
    }
    familyRevocationMessage = Self.familyRevocationAlertMessage
  }

  func dismissFamilyRevocationMessage(
    clearPending: (() -> Void)? = nil
  ) {
    if let clearPending {
      clearPending()
    } else {
      familyRevocationNoticeStore.clearPending()
    }
    familyRevocationMessage = nil
  }

  /// Returns true only when this verification handled a confirmed Child-family revocation.
  @discardableResult
  func verifySelfFamilyMemberRecord() async -> Bool {
    guard !ScreenshotDemoMode.isActive else { return false }
    let localMode = AppModeManager.shared.currentMode
    let accountIsSignedIn = self.isSignedIn
    let result = await networkService.verifySelfFamilyMember(
      cachedUserRecordID: currentUserRecordID,
      localMode: localMode,
      accountIsSignedIn: accountIsSignedIn
    )

    self.isConnectedToFamily = result.isConnected
    if let userRecordID = result.userRecordID, self.currentUserRecordID == nil {
      self.currentUserRecordID = userRecordID
    }
    if let isSignedIn = result.isSignedIn {
      self.isSignedIn = isSignedIn
    }
    // In a disconnected result, enforced .individual is the confirmed-revocation signal. Only
    // CloudKitNetworkService+Verification may produce this overload, and only for Child mode.
    if !result.isConnected, result.enforcedMode == .individual {
      if Self.isConfirmedRevocation(
        isConnected: result.isConnected,
        isSignedIn: self.isSignedIn,
        enforcedMode: result.enforcedMode,
        currentMode: AppModeManager.shared.currentMode
      ) {
        handleConfirmedFamilyRevocation()
        return true
      }
      return false
    }
    if let mode = result.enforcedMode {
      AppModeManager.shared.selectMode(mode)
    }
    return false
  }

  // MARK: - Share Participant Sync

  func syncShareParticipantsToFamilyMembers() async throws {
    guard !ScreenshotDemoMode.isActive else { return }
    let result = try await networkService.syncShareParticipantsToFamilyMembers()
    self.pendingParticipants = result.pendingParticipants
    self.familyMembers = result.familyMembers
  }

  // MARK: - Heartbeat

  func writeHeartbeat(_ heartbeat: DeviceHeartbeat) async throws {
    try await networkService.writeHeartbeat(heartbeat)
  }

  func fetchHeartbeats() async -> [DeviceHeartbeat] {
    return await networkService.fetchHeartbeats()
  }

  func deleteHeartbeat(childUserRecordName: String, deviceIdentifier: String) async throws {
    try await networkService.deleteHeartbeat(
      childUserRecordName: childUserRecordName, deviceIdentifier: deviceIdentifier)
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
    self.isShareOwner = false
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
