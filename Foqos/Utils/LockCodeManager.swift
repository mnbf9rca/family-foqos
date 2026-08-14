import Combine
import FamilyControls
import Foundation
import SwiftUI

enum ChildSharedDataRefreshResult: Equatable {
  case newData
  case noData
  case failed

  static func combine(
    _ lockCodes: ChildSharedDataRefreshResult,
    _ commands: ChildSharedDataRefreshResult
  ) -> ChildSharedDataRefreshResult {
    if lockCodes == .failed || commands == .failed {
      return .failed
    }
    if lockCodes == .newData || commands == .newData {
      return .newData
    }
    return .noData
  }
}

/// Manages lock codes for parent-controlled (managed) profiles.
/// - Parents: Can create, view, and update lock codes
/// - Children: Can only verify codes (cannot see them)
@MainActor
class LockCodeManager: ObservableObject {
  static let shared = LockCodeManager()

  private let cloudKitManager: CloudKitManager
  private let appModeManager: AppModeManager

  /// All lock codes (only populated for parents)
  @Published private(set) var lockCodes: [FamilyLockCode] = []

  /// Whether lock codes are currently being synced
  @Published private(set) var isLoading: Bool = false

  /// Last sync error
  @Published var error: String?

  /// Cached lock codes for verification (used by children)
  private var cachedLockCodes: [FamilyLockCode] = []

  private var cancellables = Set<AnyCancellable>()

  private static let maxProcessedCommandEntries = 50

  private struct ProcessedCommandEntry: Codable {
    let id: UUID
    let processedAt: Date
  }

  private init(
    cloudKitManager: CloudKitManager = .shared,
    appModeManager: AppModeManager = .shared
  ) {
    self.cloudKitManager = cloudKitManager
    self.appModeManager = appModeManager
    setupBindings()
    loadThrottleState()
    cachedLockCodes = loadPersistedLockCodes()
  }

  // MARK: - Setup

  private func setupBindings() {
    // Listen for app mode changes
    appModeManager.$currentMode
      .receive(on: DispatchQueue.main)
      .sink { [weak self] mode in
        Task {
          await self?.handleModeChange(mode)
        }
      }
      .store(in: &cancellables)
  }

  private func handleModeChange(_ mode: AppMode) async {
    switch mode {
    case .parent, .individual:
      // Parents and individual users can manage lock codes
      await fetchLockCodes()
    case .child:
      // Children need to fetch shared lock codes for verification
      await refreshSharedLockCodesForVerification()
    }
  }

  // MARK: - Parent Operations

  /// Create or update a lock code (parent operation)
  /// Individual mode users can also set lock codes via the Family Controls Dashboard
  func setLockCode(_ code: String, scope: LockCodeScope = .allChildren) async throws {
    guard appModeManager.currentMode != .child else {
      throw LockCodeError.notAuthorized
    }

    isLoading = true
    defer { isLoading = false }

    // Check if a code with this scope already exists
    if let existingIndex = lockCodes.firstIndex(where: { $0.scope == scope }) {
      var updatedCode = lockCodes[existingIndex]
      updatedCode.updateCode(code)

      try await cloudKitManager.saveLockCode(updatedCode)

      lockCodes[existingIndex] = updatedCode
    } else {
      // Create new lock code
      let newLockCode = FamilyLockCode(code: code, scope: scope)
      try await cloudKitManager.saveLockCode(newLockCode)

      lockCodes.append(newLockCode)
    }
  }

  /// Delete a lock code (parent operation)
  /// Individual mode users can also delete lock codes via the Family Controls Dashboard
  func deleteLockCode(_ lockCode: FamilyLockCode) async throws {
    guard appModeManager.currentMode != .child else {
      throw LockCodeError.notAuthorized
    }

    isLoading = true
    defer { isLoading = false }

    try await cloudKitManager.deleteLockCode(lockCode)

    lockCodes.removeAll { $0.id == lockCode.id }
  }

  /// Delete all lock codes (parent operation for "Clear PIN")
  func deleteAllLockCodes() async throws {
    guard appModeManager.currentMode != .child else {
      throw LockCodeError.notAuthorized
    }

    isLoading = true
    defer { isLoading = false }

    let codesToDelete = lockCodes
    for lockCode in codesToDelete {
      try await cloudKitManager.deleteLockCode(lockCode)
      lockCodes.removeAll { $0.id == lockCode.id }
    }
  }

  /// Fetch all lock codes created by this user (parent or individual mode)
  func fetchLockCodes() async {
    guard !ScreenshotDemoMode.isActive else { return }
    guard appModeManager.currentMode != .child else { return }

    isLoading = true
    defer { isLoading = false }

    do {
      let codes = try await cloudKitManager.fetchLockCodes()
      self.lockCodes = codes
      self.error = nil
    } catch {
      self.error = error.localizedDescription
    }
  }

  /// Get the lock code for a specific scope
  func getLockCode(for scope: LockCodeScope) -> FamilyLockCode? {
    return lockCodes.first { $0.scope == scope }
  }

  /// Get the lock code for a specific child
  func getLockCode(forChildId childId: String?) -> FamilyLockCode? {
    // First try to find a specific code for this child
    if let childId = childId {
      if let specificCode = lockCodes.first(where: {
        if case .specificChild(let id) = $0.scope {
          return id == childId
        }
        return false
      }) {
        return specificCode
      }
    }

    // Fall back to the "all children" code
    return lockCodes.first { $0.scope == .allChildren }
  }

  /// Check if a lock code exists for the given scope
  func hasLockCode(for scope: LockCodeScope) -> Bool {
    return lockCodes.contains { $0.scope == scope }
  }

  /// Check if any lock code exists
  var hasAnyLockCode: Bool {
    !lockCodes.isEmpty
  }

  #if DEBUG
    /// Screenshot/demo + test seeding only — `lockCodes` is private(set).
    func seedForScreenshots(_ codes: [FamilyLockCode]) {
      lockCodes = codes
    }
  #endif

  // MARK: - Child Operations

  /// Fetch shared lock codes for verification (child operation).
  /// Reuses persisted child authorization, verifying once only when bootstrap state is absent.
  @discardableResult
  func refreshSharedLockCodesForVerification() async -> ChildSharedDataRefreshResult {
    guard !ScreenshotDemoMode.isActive else { return .noData }
    guard appModeManager.currentMode == .child else { return .noData }

    isLoading = true
    defer { isLoading = false }

    let authorizationResult = await Self.sharedRefreshAuthorizationResult(
      persisted: AuthorizationVerifier.shared.currentAuthorizationType
    ) {
      await AuthorizationVerifier.shared.verifyChildAuthorization()
    }
    switch AuthorizationVerifier.verificationDisposition(for: authorizationResult) {
    case .authorized:
      break
    case .indeterminate:
      self.error =
        authorizationResult.errorMessage
        ?? "Unable to verify Screen Time authorization. Please try again."
      return .failed
    }

    let lockCodeResult = await refreshSharedLockCodes()
    let commandResult = await processPendingCommands()
    return ChildSharedDataRefreshResult.combine(lockCodeResult, commandResult)
  }

  static func sharedRefreshAuthorizationResult(
    persisted authorizationType: AuthorizationVerifier.AuthorizationType,
    verify: () async -> AuthorizationVerifier.VerificationResult
  ) async -> AuthorizationVerifier.VerificationResult {
    guard authorizationType != .child else { return .authorized }
    return await verify()
  }

  private func refreshSharedLockCodes() async -> ChildSharedDataRefreshResult {
    do {
      let result = try await cloudKitManager.fetchSharedLockCodes()
      // Fail-closed-with-cache (#197): trust a CONNECTED result (even empty = parent cleared)
      // and persist it; on a disconnected/failed fetch keep the last-synced cached codes so
      // verification still works offline and the lock never fails open.
      let resolved = Self.resolveLockCodes(
        fetched: result.codes,
        isConnected: result.isConnected,
        persisted: loadPersistedLockCodes()
      )
      let refreshResult = Self.lockCodeRefreshResult(
        previous: cachedLockCodes,
        refreshed: resolved.cache,
        isConnected: result.isConnected)
      self.cachedLockCodes = resolved.cache
      persistLockCodes(resolved.persist)
      self.error = nil
      return refreshResult
    } catch {
      // Defensive: the network layer returns empty without throwing for offline/CKError, but
      // if it ever does throw, keep the last-synced codes rather than falling back to empty.
      self.cachedLockCodes = loadPersistedLockCodes()
      self.error = error.localizedDescription
      return .failed
    }
  }

  nonisolated static func lockCodeRefreshResult(
    previous: [FamilyLockCode],
    refreshed: [FamilyLockCode],
    isConnected: Bool
  ) -> ChildSharedDataRefreshResult {
    guard isConnected else { return .failed }
    let previousByID = previous.sorted { $0.id.uuidString < $1.id.uuidString }
    let refreshedByID = refreshed.sorted { $0.id.uuidString < $1.id.uuidString }
    return previousByID == refreshedByID ? .noData : .newData
  }

  nonisolated static func commandRefreshResult(
    didApplyCommand: Bool,
    isConnected: Bool,
    hasProcessingFailures: Bool = false
  ) -> ChildSharedDataRefreshResult {
    guard isConnected, !hasProcessingFailures else { return .failed }
    return didApplyCommand ? .newData : .noData
  }

  /// Resolve the verification cache and the persisted store after a fetch (#197).
  /// A CONNECTED result is trusted and replaces both — even when empty, which is how a
  /// parent clearing the PIN propagates to the child. A DISCONNECTED result (offline /
  /// CloudKit error, which the network layer returns as an empty, non-throwing tuple) is
  /// ignored in favour of the last-synced persisted codes, so the child can still verify
  /// the cached code offline. The lock only "fails open" when no code was ever synced.
  static func resolveLockCodes(
    fetched: [FamilyLockCode],
    isConnected: Bool,
    persisted: [FamilyLockCode]
  ) -> (cache: [FamilyLockCode], persist: [FamilyLockCode]) {
    isConnected ? (cache: fetched, persist: fetched) : (cache: persisted, persist: persisted)
  }

  func handleConfirmedCloudKitRevocation() {
    cachedLockCodes = []
    throttleDefaults.removeObject(forKey: CacheKey.childLockCodes)
  }

  /// Pure verification logic - all inputs explicit, no instance state.
  /// Used directly by tests; the instance method below is a thin wrapper.
  static func verifyCode(
    _ code: String,
    forChildId childId: String?,
    mode: AppMode,
    authorizationType: AuthorizationVerifier.AuthorizationType,
    codes: [FamilyLockCode]
  ) -> Bool {
    // For child mode, verify the authorization type is still valid
    if mode == .child {
      guard authorizationType == .child else {
        Log.info("Authorization type mismatch, rejecting code verification", category: .app)
        return false
      }
    }

    // First try to find a specific code for this child
    if let childId = childId {
      if let specificCode = codes.first(where: {
        if case .specificChild(let id) = $0.scope {
          return id == childId
        }
        return false
      }) {
        return specificCode.verifyCode(code)
      }
    }

    // Fall back to the "all children" code
    if let generalCode = codes.first(where: { $0.scope == .allChildren }) {
      return generalCode.verifyCode(code)
    }

    return false
  }

  /// Verify a code entered by a child
  /// Returns true if the code is valid for the given child
  /// For child mode, verifies authorization status before checking codes
  func verifyCode(_ code: String, forChildId childId: String?) -> Bool {
    let codesToCheck = appModeManager.currentMode != .child ? lockCodes : cachedLockCodes
    return Self.verifyCode(
      code,
      forChildId: childId,
      mode: appModeManager.currentMode,
      authorizationType: AuthorizationVerifier.shared.currentAuthorizationType,
      codes: codesToCheck
    )
  }

  /// Verify a code for a managed profile
  func verifyCodeForProfile(_ code: String, profile: BlockedProfiles) -> Bool {
    return verifyCode(code, forChildId: profile.managedByChildId)
  }

  /// Simple validation - checks if code matches any available lock code
  func validateCode(_ code: String) -> Bool {
    let codesToCheck = appModeManager.currentMode != .child ? lockCodes : cachedLockCodes
    return codesToCheck.contains { $0.verifyCode(code) }
  }

  /// Check if there's a lock code available for verification
  var canVerifyCode: Bool {
    let codesToCheck = appModeManager.currentMode != .child ? lockCodes : cachedLockCodes
    return !codesToCheck.isEmpty
  }

  // MARK: - Command Processing (Child Mode)

  /// Check for and process any pending commands from parent.
  /// Called from child lock-code refresh, the PIN-dialog poll, and child foreground.
  @discardableResult
  func processPendingCommands(
    cleanupStale: Bool = true
  ) async -> ChildSharedDataRefreshResult {
    guard !ScreenshotDemoMode.isActive else { return .noData }
    guard appModeManager.currentMode == .child else {
      return .noData
    }

    if cleanupStale {
      // Clean up any stale commands (from any user, not just this child)
      await cloudKitManager.cleanupStaleCommands()
    }

    do {
      let result = try await cloudKitManager.fetchPendingCommands()
      var didApplyCommand = false
      var hasProcessingFailures = false

      for command in result.commands {
        let outcome = await processCommand(command)
        didApplyCommand = outcome.didApply || didApplyCommand
        hasProcessingFailures = outcome.didFail || hasProcessingFailures
      }
      return Self.commandRefreshResult(
        didApplyCommand: didApplyCommand,
        isConnected: result.isConnected,
        hasProcessingFailures: hasProcessingFailures)
    } catch {
      Log.error("Failed to fetch pending commands: \(redactedErrorForLog(error))", category: .cloudKit)
      return .failed
    }
  }

  /// Apply a parent command's local side effect.
  /// Replication of a parent-authorized operation (#230); not re-gated on the child.
  func applyCommand(_ command: FamilyCommand) {
    Log.info("Applying command: \(command.commandType.rawValue)", category: .cloudKit)
    switch command.commandType {
    case .resetEmergencyCount:
      EmergencyUnblockManager.shared.resetEmergencyUnblocks()
      Log.info("Emergency count reset by parent", category: .cloudKit)
    case .resetLockCodeThrottle:
      resetThrottle()
      Log.info("Lock code throttle reset by parent", category: .cloudKit)
    }
  }

  /// Apply a parent command once per persisted command ID.
  /// Commands that remain in CloudKit after a delete failure may be fetched again after relaunch;
  /// the persisted ledger prevents replaying non-idempotent local side effects.
  func applyCommandIfNeeded(_ command: FamilyCommand, now: Date = Date()) -> Bool {
    let entries = loadProcessedCommandEntries()
    if entries.contains(where: { $0.id == command.id }) {
      persistProcessedCommandEntries(entries)
      return false
    }

    applyCommand(command)

    let updatedEntries =
      [ProcessedCommandEntry(id: command.id, processedAt: now)] + entries
    persistProcessedCommandEntries(updatedEntries)
    return true
  }

  private func processCommand(_ command: FamilyCommand) async -> (
    didApply: Bool, didFail: Bool
  ) {
    let didApply = applyCommandIfNeeded(command)
    if !didApply {
      Log.info("Skipping already processed command: \(command.commandType.rawValue)", category: .cloudKit)
    }

    // Delete the command after processing
    do {
      try await cloudKitManager.deleteCommand(command)
      return (didApply: didApply, didFail: false)
    } catch {
      Log.error("Failed to delete processed command: \(redactedErrorForLog(error))", category: .cloudKit)
      return (didApply: didApply, didFail: true)
    }
  }

  // MARK: - Temporary Unlock Session

  /// Temporary unlock state for the current session
  /// Unlocked until the profile view is dismissed (which calls revokeUnlock)
  @Published private(set) var unlockedProfileId: UUID?

  /// Grant edit access to a managed profile until the view is dismissed
  func grantTemporaryUnlock(for profileId: UUID) {
    unlockedProfileId = profileId
  }

  /// Check if a profile is currently unlocked for editing
  func isUnlocked(_ profileId: UUID) -> Bool {
    return unlockedProfileId == profileId
  }

  /// Pure gate for user-initiated edit/delete of a profile. Uses `== .child` so Individual
  /// mode is not gated (AGENTS.md). Sync-applied deletes must not consult this gate.
  nonisolated static func isEditLocked(
    isManaged: Bool,
    mode: AppMode,
    isUnlocked: Bool
  ) -> Bool {
    isManaged && mode == .child && !isUnlocked
  }

  /// Gate `profile` against this device's current mode and temporary unlock state.
  func isEditLocked(_ profile: BlockedProfiles) -> Bool {
    LockCodeManager.isEditLocked(
      isManaged: profile.isManaged,
      mode: appModeManager.currentMode,
      isUnlocked: isUnlocked(profile.id))
  }

  /// Revoke temporary unlock (called when profile view is dismissed)
  func revokeUnlock() {
    unlockedProfileId = nil
  }

  // MARK: - PIN Throttling

  /// UserDefaults keys for throttle persistence
  private enum ThrottleKey {
    static let failedAttempts = "family_foqos_lock_code_failed_attempts"
    static let lockoutExpiresAt = "family_foqos_lock_code_lockout_expires_at"
  }

  private enum CacheKey {
    static let childLockCodes = "family_foqos_child_lock_codes"
  }

  private enum CommandLedgerKey {
    static let processedCommands = "family_foqos_processed_family_commands"
  }

  /// Throttle schedule: failed attempts -> lockout duration in seconds
  private static let throttleSchedule: [(threshold: Int, duration: TimeInterval)] = [
    (3, 30),  // 30 seconds after 3 failures
    (5, 120),  // 2 minutes after 5 failures
    (7, 300),  // 5 minutes after 7 failures
    (10, 900),  // 15 minutes after 10+ failures
  ]

  private var throttleDefaults: UserDefaults = .standard

  /// Number of consecutive failed PIN attempts
  @Published private(set) var failedAttempts: Int = 0

  /// When the current lockout expires (nil = not locked out)
  @Published private(set) var lockoutExpiresAt: Date?

  /// Whether the PIN pad is currently locked out (convenience for current time)
  var isLockedOut: Bool {
    isLockedOut(now: Date())
  }

  /// Whether the PIN pad is currently locked out at the given time
  func isLockedOut(now: Date) -> Bool {
    guard let expiresAt = lockoutExpiresAt else { return false }
    return now < expiresAt
  }

  /// Seconds remaining in the current lockout (0 if not locked out)
  func lockoutRemaining(now: Date = Date()) -> TimeInterval {
    guard let expiresAt = lockoutExpiresAt else { return 0 }
    return max(0, expiresAt.timeIntervalSince(now))
  }

  /// Record a failed PIN attempt and apply lockout if threshold reached
  func recordFailedAttempt(now: Date = Date()) {
    failedAttempts += 1
    persistThrottleState(now: now)
  }

  /// Clear failed attempts and lockout (called on success or remote reset)
  func resetThrottle() {
    failedAttempts = 0
    lockoutExpiresAt = nil
    throttleDefaults.removeObject(forKey: ThrottleKey.failedAttempts)
    throttleDefaults.removeObject(forKey: ThrottleKey.lockoutExpiresAt)
  }

  /// Override UserDefaults instance (for testing)
  func overrideDefaults(_ defaults: UserDefaults?) {
    throttleDefaults = defaults ?? .standard
    loadThrottleState()
    cachedLockCodes = loadPersistedLockCodes()
    persistProcessedCommandEntries(loadProcessedCommandEntries())
  }

  /// Load throttle state from UserDefaults
  func loadThrottleState() {
    failedAttempts = throttleDefaults.integer(forKey: ThrottleKey.failedAttempts)
    let timestamp = throttleDefaults.double(forKey: ThrottleKey.lockoutExpiresAt)
    lockoutExpiresAt = timestamp > 0 ? Date(timeIntervalSinceReferenceDate: timestamp) : nil
  }

  /// Persist throttle state and compute lockout from schedule
  private func persistThrottleState(now: Date) {
    throttleDefaults.set(failedAttempts, forKey: ThrottleKey.failedAttempts)

    // Find the highest matching threshold
    let matchingDuration = Self.throttleSchedule
      .last { failedAttempts >= $0.threshold }?
      .duration

    if let duration = matchingDuration {
      lockoutExpiresAt = now.addingTimeInterval(duration)
      throttleDefaults.set(
        lockoutExpiresAt!.timeIntervalSinceReferenceDate,
        forKey: ThrottleKey.lockoutExpiresAt
      )
    }
  }

  private func loadPersistedLockCodes() -> [FamilyLockCode] {
    guard let data = throttleDefaults.data(forKey: CacheKey.childLockCodes),
      let codes = try? JSONDecoder().decode([FamilyLockCode].self, from: data)
    else {
      return []
    }
    return codes
  }

  private func persistLockCodes(_ codes: [FamilyLockCode]) {
    if let data = try? JSONEncoder().encode(codes) {
      throttleDefaults.set(data, forKey: CacheKey.childLockCodes)
    }
  }

  private func loadProcessedCommandEntries() -> [ProcessedCommandEntry] {
    guard let data = throttleDefaults.data(forKey: CommandLedgerKey.processedCommands),
      let entries = try? JSONDecoder().decode([ProcessedCommandEntry].self, from: data)
    else {
      return []
    }

    return Self.prunedProcessedCommandEntries(entries)
  }

  private func persistProcessedCommandEntries(_ entries: [ProcessedCommandEntry]) {
    let prunedEntries = Self.prunedProcessedCommandEntries(entries)
    if let data = try? JSONEncoder().encode(prunedEntries) {
      throttleDefaults.set(data, forKey: CommandLedgerKey.processedCommands)
    }
  }

  private static func prunedProcessedCommandEntries(
    _ entries: [ProcessedCommandEntry]
  ) -> [ProcessedCommandEntry] {
    Array(
      entries
        .sorted { $0.processedAt > $1.processedAt }
        .prefix(maxProcessedCommandEntries)
    )
  }
}

// MARK: - Error Types

enum LockCodeError: LocalizedError {
  case notAuthorized
  case codeNotFound
  case verificationFailed

  var errorDescription: String? {
    switch self {
    case .notAuthorized:
      return "You are not authorized to perform this action."
    case .codeNotFound:
      return "No lock code found."
    case .verificationFailed:
      return "The code you entered is incorrect."
    }
  }
}

// MARK: - Safety Check Extension

extension LockCodeManager {
  /// Check if the current device can have managed profiles
  /// Parent/individual devices should NOT have managed profiles on them
  var canHaveManagedProfiles: Bool {
    return appModeManager.currentMode == .child
  }

  /// Check if the current device can create managed profiles
  /// Parent and individual mode users can mark profiles as managed (for children's devices)
  var canCreateManagedProfiles: Bool {
    return appModeManager.currentMode != .child
  }
}
