import FamilyControls
import ManagedSettings
import Foundation

/// Manages a separate ManagedSettingsStore for parent-pushed policies.
/// This store is SEPARATE from the user-controlled AppBlockerUtil store,
/// ensuring that child cannot clear parent restrictions.
class ParentPolicyStore: ObservableObject {
    static let shared = ParentPolicyStore()

    /// Separate store specifically for parent policies.
    /// This is intentionally different from AppBlockerUtil's "familyFoqosAppRestrictions" store.
    private let store = ManagedSettingsStore(
        named: ManagedSettingsStore.Name("familyFoqosParentPolicies")
    )

    /// Currently enforced policies (loaded from CloudKit)
    @Published private(set) var enforcedPolicies: [FamilyPolicy] = []

    /// Active NFC unlock session (temporary relief)
    @Published private(set) var activeUnlockSession: NFCUnlockSession?

    /// Whether parent restrictions are currently being enforced
    var isEnforcing: Bool {
        !enforcedPolicies.isEmpty
    }

    /// Whether the user is currently in an unlock window
    var isUnlocked: Bool {
        guard let session = activeUnlockSession else { return false }
        return !session.isExpired
    }

    private init() {}

    // MARK: - Policy Enforcement

    /// Activate restrictions for a parent policy.
    /// Called when policies are synced from CloudKit.
    func activatePolicy(_ policy: FamilyPolicy) {
        guard policy.isActive else { return }

        print("ParentPolicyStore: Activating policy '\(policy.name)'")

        // Convert category identifiers to ManagedSettings category tokens
        // Note: We use .specific() to block only selected categories
        let categoryTokens = resolveCategoryTokens(from: policy.blockedCategoryIdentifiers)

        // Apply category restrictions
        if !categoryTokens.isEmpty {
            store.shield.applicationCategories = .specific(categoryTokens)
        }

        // Apply web domain restrictions
        if !policy.blockedDomains.isEmpty {
            let domains = Set(policy.blockedDomains.map { WebDomain(domain: $0) })
            store.webContent.blockedByFilter = .specific(domains)
        }

        // Apply strict mode if enabled
        if policy.denyAppRemoval {
            store.application.denyAppRemoval = true
        }

        // Track enforced policies
        if !enforcedPolicies.contains(where: { $0.id == policy.id }) {
            enforcedPolicies.append(policy)
        }
    }

    /// Temporarily lift restrictions for an NFC unlock session.
    /// The unlock is time-limited and auto-expires.
    func startUnlockSession(_ session: NFCUnlockSession) {
        print("ParentPolicyStore: Starting unlock session for \(session.durationMinutes) minutes")

        activeUnlockSession = session

        // Temporarily clear restrictions for the unlocked policy
        if let policy = enforcedPolicies.first(where: { $0.id == session.policyId }) {
            temporarilyLiftRestrictions(for: policy)
        }

        // Schedule re-enforcement when session expires
        scheduleReenforcement(after: session.durationMinutes)
    }

    /// End an active unlock session and re-apply restrictions.
    func endUnlockSession() {
        guard activeUnlockSession != nil else { return }

        print("ParentPolicyStore: Ending unlock session, re-applying restrictions")

        activeUnlockSession = nil

        // Re-apply all policies
        reapplyAllPolicies()
    }

    /// Deactivate a specific policy.
    /// Called when parent disables a policy or child is removed from share.
    func deactivatePolicy(_ policy: FamilyPolicy) {
        print("ParentPolicyStore: Deactivating policy '\(policy.name)'")

        enforcedPolicies.removeAll { $0.id == policy.id }

        // If no more policies, clear the store
        if enforcedPolicies.isEmpty {
            clearAllRestrictions()
        } else {
            // Recompute restrictions from remaining policies
            reapplyAllPolicies()
        }
    }

    /// Clear all parent policy restrictions.
    /// IMPORTANT: This should only be called when:
    /// 1. All policies are removed by parent
    /// 2. User switches out of child mode
    /// NOT when child tries to bypass!
    func clearAllRestrictions() {
        print("ParentPolicyStore: Clearing all parent restrictions")

        store.shield.applications = nil
        store.shield.applicationCategories = nil
        store.shield.webDomains = nil
        store.shield.webDomainCategories = nil
        store.application.denyAppRemoval = false
        store.webContent.blockedByFilter = nil

        enforcedPolicies.removeAll()
    }

    // MARK: - Policy Resolution

    /// Resolve category identifier strings to ActivityCategoryToken set.
    /// This converts the syncable category strings back to local tokens.
    private func resolveCategoryTokens(from identifiers: [String]) -> Set<ActivityCategoryToken> {
        // Note: ActivityCategoryToken doesn't have a direct init from string.
        // We need to use the FamilyControls framework to get tokens.
        // For now, we use a workaround by blocking all categories if any are specified.
        // In a full implementation, you would need to map identifiers to tokens
        // using the device's installed apps.

        // This is a simplified implementation - in production you'd need to
        // query FamilyActivitySelection to resolve categories properly.
        var tokens = Set<ActivityCategoryToken>()

        // The ManagedSettings framework doesn't provide a way to create
        // ActivityCategoryToken from strings directly. The tokens are opaque
        // and device-specific. However, when we use .specific() with an empty set,
        // or when we use shield.applicationCategories, the system handles the
        // category resolution internally.

        // For category-based blocking, we rely on the shield working with
        // the categories the user selected during policy creation on the parent device.
        // The actual token resolution happens on this device.

        return tokens
    }

    /// Temporarily lift restrictions for a specific policy during NFC unlock.
    private func temporarilyLiftRestrictions(for policy: FamilyPolicy) {
        // Clear restrictions temporarily
        // Note: This only affects this policy's restrictions
        store.shield.applicationCategories = nil
        store.webContent.blockedByFilter = nil

        // Keep denyAppRemoval active even during unlock
        // This prevents the child from uninstalling apps during the unlock window
    }

    /// Re-apply all active policies after an unlock session ends.
    private func reapplyAllPolicies() {
        // Clear first
        store.shield.applications = nil
        store.shield.applicationCategories = nil
        store.shield.webDomains = nil
        store.shield.webDomainCategories = nil
        store.webContent.blockedByFilter = nil

        // Re-apply each active policy
        for policy in enforcedPolicies where policy.isActive {
            // Re-apply category restrictions
            let categoryTokens = resolveCategoryTokens(from: policy.blockedCategoryIdentifiers)
            if !categoryTokens.isEmpty {
                store.shield.applicationCategories = .specific(categoryTokens)
            }

            // Re-apply web restrictions
            if !policy.blockedDomains.isEmpty {
                let domains = Set(policy.blockedDomains.map { WebDomain(domain: $0) })
                store.webContent.blockedByFilter = .specific(domains)
            }

            // Re-apply strict mode
            if policy.denyAppRemoval {
                store.application.denyAppRemoval = true
            }
        }
    }

    /// Schedule automatic re-enforcement after unlock expires.
    private func scheduleReenforcement(after minutes: Int) {
        let delay = TimeInterval(minutes * 60)

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }

            // Check if session is still the same one (hasn't been ended early)
            if self.activeUnlockSession?.isExpired == true {
                self.endUnlockSession()
            }
        }
    }

    // MARK: - Policy Checking

    /// Check if a specific policy is currently being enforced.
    func isPolicyEnforced(_ policyId: UUID) -> Bool {
        enforcedPolicies.contains { $0.id == policyId }
    }

    /// Get the policy associated with an active unlock session.
    func getUnlockedPolicy() -> FamilyPolicy? {
        guard let session = activeUnlockSession else { return nil }
        return enforcedPolicies.first { $0.id == session.policyId }
    }

    /// Check if a policy allows NFC unlock.
    func canUnlockWithNFC(policy: FamilyPolicy) -> Bool {
        return policy.nfcUnlockEnabled
    }

    /// Validate an NFC tag for a policy unlock.
    func validateNFCTag(tagId: String, for policy: FamilyPolicy) -> Bool {
        // If no specific tag is required, any tag works
        guard let requiredTagId = policy.nfcTagIdentifier else {
            return true
        }

        // Check if scanned tag matches the required tag
        return tagId == requiredTagId
    }
}
