import Combine
import Foundation
import SwiftUI

/// Manages lock codes for parent-controlled (managed) profiles.
/// - Parents: Can create, view, and update lock codes
/// - Children: Can only verify codes (cannot see them)
class LockCodeManager: ObservableObject {
    static let shared = LockCodeManager()

    private let cloudKitManager = CloudKitManager.shared
    private let appModeManager = AppModeManager.shared

    /// All lock codes (only populated for parents)
    @Published private(set) var lockCodes: [FamilyLockCode] = []

    /// Whether lock codes are currently being synced
    @Published private(set) var isLoading: Bool = false

    /// Last sync error
    @Published var error: String?

    /// Cached lock codes for verification (used by children)
    private var cachedLockCodes: [FamilyLockCode] = []

    private var cancellables = Set<AnyCancellable>()

    private init() {
        setupBindings()
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
        case .parent:
            // Parents need to fetch their lock codes
            await fetchLockCodes()
        case .child:
            // Children need to fetch shared lock codes for verification
            await fetchSharedLockCodes()
        case .individual:
            // Individual mode doesn't use lock codes
            await MainActor.run {
                lockCodes.removeAll()
                cachedLockCodes.removeAll()
            }
        }
    }

    // MARK: - Parent Operations

    /// Create or update a lock code (parent operation)
    func setLockCode(_ code: String, scope: LockCodeScope = .allChildren) async throws {
        guard appModeManager.currentMode == .parent else {
            throw LockCodeError.notAuthorized
        }

        await MainActor.run { isLoading = true }
        defer { Task { await MainActor.run { self.isLoading = false } } }

        // Check if a code with this scope already exists
        if let existingIndex = lockCodes.firstIndex(where: { $0.scope == scope }) {
            var updatedCode = lockCodes[existingIndex]
            updatedCode.updateCode(code)

            try await cloudKitManager.saveLockCode(updatedCode)

            await MainActor.run {
                lockCodes[existingIndex] = updatedCode
            }
        } else {
            // Create new lock code
            let newLockCode = FamilyLockCode(code: code, scope: scope)
            try await cloudKitManager.saveLockCode(newLockCode)

            await MainActor.run {
                lockCodes.append(newLockCode)
            }
        }
    }

    /// Delete a lock code (parent operation)
    func deleteLockCode(_ lockCode: FamilyLockCode) async throws {
        guard appModeManager.currentMode == .parent else {
            throw LockCodeError.notAuthorized
        }

        await MainActor.run { isLoading = true }
        defer { Task { await MainActor.run { self.isLoading = false } } }

        try await cloudKitManager.deleteLockCode(lockCode)

        await MainActor.run {
            lockCodes.removeAll { $0.id == lockCode.id }
        }
    }

    /// Fetch all lock codes created by this parent
    func fetchLockCodes() async {
        guard appModeManager.currentMode == .parent else { return }

        await MainActor.run { isLoading = true }
        defer { Task { await MainActor.run { self.isLoading = false } } }

        do {
            let codes = try await cloudKitManager.fetchLockCodes()
            await MainActor.run {
                self.lockCodes = codes
                self.error = nil
            }
        } catch {
            await MainActor.run {
                self.error = error.localizedDescription
            }
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
    private func fetchSharedLockCodes() async {
        guard appModeManager.currentMode == .child else { return }

        await MainActor.run { isLoading = true }
        defer { Task { await MainActor.run { self.isLoading = false } } }

        do {
            let codes = try await cloudKitManager.fetchSharedLockCodes()
            await MainActor.run {
                self.cachedLockCodes = codes
                self.error = nil
            }
        } catch {
            await MainActor.run {
                self.error = error.localizedDescription
            }
        }
    }

    /// Verify a code entered by a child
    /// Returns true if the code is valid for the given child
    func verifyCode(_ code: String, forChildId childId: String?) -> Bool {
        // Use cached codes for verification
        let codesToCheck = appModeManager.currentMode == .parent ? lockCodes : cachedLockCodes

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

    // MARK: - Temporary Unlock Session

    /// Temporary unlock state for the current session
    @Published private(set) var temporaryUnlock: TemporaryUnlock?

    struct TemporaryUnlock {
        let profileId: UUID
        let unlockedAt: Date
        let expiresAt: Date

        var isExpired: Bool {
            Date() >= expiresAt
        }

        var remainingTime: TimeInterval {
            max(0, expiresAt.timeIntervalSince(Date()))
        }
    }

    /// Grant temporary edit access to a managed profile (5 minute window)
    func grantTemporaryUnlock(for profileId: UUID, duration: TimeInterval = 300) {
        let now = Date()
        temporaryUnlock = TemporaryUnlock(
            profileId: profileId,
            unlockedAt: now,
            expiresAt: now.addingTimeInterval(duration)
        )

        // Schedule expiration
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            if self?.temporaryUnlock?.profileId == profileId {
                self?.temporaryUnlock = nil
            }
        }
    }

    /// Check if a profile is currently unlocked for editing
    func isUnlocked(_ profileId: UUID) -> Bool {
        guard let unlock = temporaryUnlock else { return false }
        return unlock.profileId == profileId && !unlock.isExpired
    }

    /// Revoke temporary unlock
    func revokeUnlock() {
        temporaryUnlock = nil
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
    /// Parent devices should NOT have managed profiles on them
    var canHaveManagedProfiles: Bool {
        return appModeManager.currentMode == .child
    }

    /// Check if the current device can create managed profiles
    /// Only parent devices can mark profiles as managed
    var canCreateManagedProfiles: Bool {
        return appModeManager.currentMode == .parent
    }
}
