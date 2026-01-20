import Combine
import Foundation
import SwiftUI

/// Enforces parent-pushed policies on the child's device.
/// This class coordinates between CloudKit (policy source), ParentPolicyStore (enforcement),
/// and NFC scanning (unlock mechanism).
class ChildPolicyEnforcer: ObservableObject {
    static let shared = ChildPolicyEnforcer()

    private let cloudKitManager = CloudKitManager.shared
    private let parentPolicyStore = ParentPolicyStore.shared
    private let nfcScanner = NFCScannerUtil()

    private var cancellables = Set<AnyCancellable>()
    private var unlockTimer: Timer?

    // Published state for UI
    @Published var activePolicies: [FamilyPolicy] = []
    @Published var currentUnlock: NFCUnlockSession?
    @Published var isEnforcing = false
    @Published var lastSyncTime: Date?
    @Published var syncError: String?

    // NFC scanning state
    @Published var isScanning = false
    @Published var scanError: String?

    private init() {
        setupBindings()
    }

    // MARK: - Setup

    private func setupBindings() {
        // Observe CloudKit shared policies changes
        cloudKitManager.$sharedPolicies
            .receive(on: DispatchQueue.main)
            .sink { [weak self] policies in
                self?.handlePoliciesUpdate(policies)
            }
            .store(in: &cancellables)

        // Observe ParentPolicyStore unlock session
        parentPolicyStore.$activeUnlockSession
            .receive(on: DispatchQueue.main)
            .sink { [weak self] session in
                self?.currentUnlock = session
                self?.startUnlockTimer(for: session)
            }
            .store(in: &cancellables)
    }

    // MARK: - Enforcement

    /// Start enforcing parent policies. Called when child mode is activated.
    func startEnforcing() {
        print("ChildPolicyEnforcer: Starting enforcement")
        isEnforcing = true

        // Initial sync
        Task {
            await syncPolicies()
        }

        // Subscribe to real-time updates
        Task {
            try? await cloudKitManager.subscribeToSharedPolicyChanges()
        }
    }

    /// Stop enforcing parent policies. Called when switching out of child mode.
    func stopEnforcing() {
        print("ChildPolicyEnforcer: Stopping enforcement")
        isEnforcing = false

        // Clear all restrictions
        parentPolicyStore.clearAllRestrictions()
        activePolicies.removeAll()

        // Cancel timers
        unlockTimer?.invalidate()
        unlockTimer = nil
    }

    /// Sync policies from CloudKit
    func syncPolicies() async {
        do {
            let policies = try await cloudKitManager.fetchSharedPolicies()

            await MainActor.run {
                self.lastSyncTime = Date()
                self.syncError = nil
                self.handlePoliciesUpdate(policies)
            }
        } catch {
            await MainActor.run {
                self.syncError = error.localizedDescription
            }
        }
    }

    /// Handle policies update from CloudKit
    private func handlePoliciesUpdate(_ policies: [FamilyPolicy]) {
        // Get current user's record name to filter policies
        let myUserRecordName = cloudKitManager.currentUserRecordID?.recordName

        // Filter to only policies that apply to this child
        let applicablePolicies = policies.filter { policy in
            // If no user record name, can't determine - show all for safety
            guard let myRecordName = myUserRecordName else { return true }

            // Check if policy applies to this child
            return policy.appliesTo(childId: myRecordName)
        }

        activePolicies = applicablePolicies

        // Deactivate policies that were removed or no longer apply
        let newPolicyIds = Set(applicablePolicies.map { $0.id })
        for enforcedPolicy in parentPolicyStore.enforcedPolicies {
            if !newPolicyIds.contains(enforcedPolicy.id) {
                parentPolicyStore.deactivatePolicy(enforcedPolicy)
            }
        }

        // Activate applicable policies
        for policy in applicablePolicies {
            parentPolicyStore.activatePolicy(policy)
        }

        print("ChildPolicyEnforcer: \(applicablePolicies.count) of \(policies.count) policies apply to this child")
    }

    // MARK: - NFC Unlock

    /// Available when there's at least one policy that allows NFC unlock
    var nfcUnlockAvailable: Bool {
        activePolicies.contains { $0.nfcUnlockEnabled }
    }

    /// Initiate NFC unlock by scanning a tag
    func initiateNFCUnlock() {
        guard !isScanning else { return }
        guard let policy = activePolicies.first(where: { $0.nfcUnlockEnabled }) else {
            scanError = "No policies allow NFC unlock"
            return
        }

        isScanning = true
        scanError = nil

        nfcScanner.onTagScanned = { [weak self] result in
            self?.handleNFCScan(result: result, for: policy)
        }

        nfcScanner.scan(profileName: "Parent Policy Unlock")
    }

    /// Handle NFC scan result
    private func handleNFCScan(result: NFCResult, for policy: FamilyPolicy) {
        isScanning = false

        let tagId = result.id

        // Validate tag if policy requires specific tag
        if !parentPolicyStore.validateNFCTag(tagId: tagId, for: policy) {
            scanError = "This tag is not authorized for this policy"
            return
        }

        // Create unlock session
        let session = NFCUnlockSession(
            policyId: policy.id,
            policyName: policy.name,
            durationMinutes: policy.unlockDurationMinutes,
            tagIdentifier: tagId
        )

        // Start the unlock
        parentPolicyStore.startUnlockSession(session)

        print("ChildPolicyEnforcer: Started unlock session for \(policy.unlockDurationMinutes) minutes")
    }

    /// Cancel ongoing NFC scan
    func cancelNFCScan() {
        isScanning = false
        // Note: NFCScannerUtil handles session invalidation internally
    }

    // MARK: - Unlock Timer

    private func startUnlockTimer(for session: NFCUnlockSession?) {
        // Cancel existing timer
        unlockTimer?.invalidate()
        unlockTimer = nil

        guard let session = session, !session.isExpired else { return }

        // Update UI every second to show remaining time
        unlockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else { return }

            if self.currentUnlock?.isExpired == true {
                self.parentPolicyStore.endUnlockSession()
                self.unlockTimer?.invalidate()
                self.unlockTimer = nil
            } else {
                // Trigger UI update for remaining time
                self.objectWillChange.send()
            }
        }
    }

    /// End unlock session early
    func endUnlockEarly() {
        parentPolicyStore.endUnlockSession()
    }

    // MARK: - Bypass Prevention

    /// Check if emergency unblock should be blocked.
    /// Returns true if there are active parent policies that don't allow child emergency unblock.
    var shouldBlockEmergencyUnblock: Bool {
        // If no policies are being enforced, don't block
        guard parentPolicyStore.isEnforcing else { return false }

        // Block only if at least one policy disallows child emergency unblock
        return activePolicies.contains { !$0.allowChildEmergencyUnblock }
    }

    /// Check if any policy allows emergency unblock
    var anyPolicyAllowsEmergencyUnblock: Bool {
        activePolicies.contains { $0.allowChildEmergencyUnblock }
    }

    /// Check if manual session stop should be blocked.
    /// Returns true if there are active parent policies.
    var shouldBlockManualStop: Bool {
        parentPolicyStore.isEnforcing
    }

    /// Get reason why an action is blocked
    func getBlockedActionReason() -> String {
        "This action is blocked by parent-controlled restrictions. Only your parent can modify these settings."
    }
}

// MARK: - Session Info

extension ChildPolicyEnforcer {
    /// Get remaining unlock time formatted as string
    var remainingUnlockTimeFormatted: String? {
        currentUnlock?.remainingTimeFormatted
    }

    /// Get total active restrictions count
    var totalRestrictionsCount: Int {
        activePolicies.reduce(0) { count, policy in
            count + policy.blockedCategoryIdentifiers.count + policy.blockedDomains.count
        }
    }

    /// Get summary of active restrictions
    var restrictionsSummary: String {
        guard !activePolicies.isEmpty else {
            return "No restrictions active"
        }

        let categoryCount = activePolicies.reduce(0) { $0 + $1.blockedCategoryIdentifiers.count }
        let domainCount = activePolicies.reduce(0) { $0 + $1.blockedDomains.count }

        var parts: [String] = []
        if categoryCount > 0 {
            parts.append("\(categoryCount) app categor\(categoryCount == 1 ? "y" : "ies")")
        }
        if domainCount > 0 {
            parts.append("\(domainCount) website\(domainCount == 1 ? "" : "s")")
        }

        return parts.joined(separator: " and ") + " blocked"
    }
}
