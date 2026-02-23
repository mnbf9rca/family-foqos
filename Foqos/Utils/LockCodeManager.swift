import Combine
import FamilyControls
import Foundation
import SwiftUI

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

  private init(
    cloudKitManager: CloudKitManager = .shared,
    appModeManager: AppModeManager = .shared
  ) {
    self.cloudKitManager = cloudKitManager
    self.appModeManager = appModeManager
    setupBindings()
    loadThrottleState()
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
      await fetchSharedLockCodes()
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

  /// Fetch all lock codes created by this user (parent or individual mode)
  func fetchLockCodes() async {
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

  // MARK: - Child Operations

  /// Fetch shared lock codes for verification (child operation)
  /// Verifies child authorization before fetching to ensure security
  private func fetchSharedLockCodes() async {
    guard appModeManager.currentMode == .child else { return }

    isLoading = true
    defer { isLoading = false }

    // Use centralized authorization verification
    let result = await AuthorizationVerifier.shared.verifyChildAuthorization()
    guard result.isAuthorized else {
      // Let the centralized handler deal with authorization loss
      if let message = await AuthorizationVerifier.shared.verifyIfNeeded() {
        self.cachedLockCodes = []
        self.error = message
      }
      return
    }

    do {
      let codes = try await cloudKitManager.fetchSharedLockCodes()
      self.cachedLockCodes = codes
      self.error = nil

      // Also check for pending commands from parent
      await processPendingCommands()
    } catch {
      self.error = error.localizedDescription
    }
  }

  /// Verify a code entered by a child
  /// Returns true if the code is valid for the given child
  /// For child mode, verifies authorization status before checking codes
  func verifyCode(_ code: String, forChildId childId: String?) -> Bool {
    // Use cached codes for verification
    let codesToCheck = appModeManager.currentMode == .parent ? lockCodes : cachedLockCodes

    // For child mode, verify the authorization type is still valid
    if appModeManager.currentMode == .child {
      let authType = AuthorizationVerifier.shared.currentAuthorizationType
      guard authType == .child else {
        Log.info("Authorization type mismatch, clearing cached codes", category: .app)
        return false
      }
    }

    // First try to find a specific code for this child
    if let childId = childId {
      if let specificCode = codesToCheck.first(where: {
        if case .specificChild(let id) = $0.scope {
          return id == childId
        }
        return false
      }) {
        return specificCode.verifyCode(code)
      }
    }

    // Fall back to the "all children" code
    if let generalCode = codesToCheck.first(where: { $0.scope == .allChildren }) {
      return generalCode.verifyCode(code)
    }

    return false
  }

  /// Verify a code for a managed profile
  func verifyCodeForProfile(_ code: String, profile: BlockedProfiles) -> Bool {
    return verifyCode(code, forChildId: profile.managedByChildId)
  }

  /// Simple validation - checks if code matches any available lock code
  func validateCode(_ code: String) -> Bool {
    let codesToCheck = appModeManager.currentMode == .parent ? lockCodes : cachedLockCodes
    return codesToCheck.contains { $0.verifyCode(code) }
  }

  /// Check if there's a lock code available for verification
  var canVerifyCode: Bool {
    let codesToCheck = appModeManager.currentMode == .parent ? lockCodes : cachedLockCodes
    return !codesToCheck.isEmpty
  }

  // MARK: - Command Processing (Child Mode)

  /// Check for and process any pending commands from parent
  /// Called automatically during fetchSharedLockCodes
  private func processPendingCommands() async {
    guard appModeManager.currentMode == .child else {
      return
    }

    // Clean up any stale commands (from any user, not just this child)
    await cloudKitManager.cleanupStaleCommands()

    do {
      let commands = try await cloudKitManager.fetchPendingCommands()

      for command in commands {
        await processCommand(command)
      }
    } catch {
      Log.error("Failed to fetch pending commands: \(error)", category: .cloudKit)
    }
  }

  private func processCommand(_ command: FamilyCommand) async {
    Log.info("Processing command: \(command.commandType.rawValue)", category: .cloudKit)

    switch command.commandType {
    case .resetEmergencyCount:
      EmergencyUnblockManager.shared.resetEmergencyUnblocks()
      Log.info("Emergency count reset by parent", category: .cloudKit)
    case .resetLockCodeThrottle:
      resetThrottle()
      Log.info("Lock code throttle reset by parent", category: .cloudKit)
    }

    // Delete the command after processing
    do {
      try await cloudKitManager.deleteCommand(command)
    } catch {
      Log.error("Failed to delete processed command: \(error)", category: .cloudKit)
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
