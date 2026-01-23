import SwiftUI

/// Main dashboard view for children subject to parent policies.
/// Shows active restrictions and provides NFC unlock functionality.
/// Intentionally limited - no edit, delete, or bypass options.
struct ChildDashboardView: View {
    @ObservedObject private var childPolicyEnforcer = ChildPolicyEnforcer.shared
    @ObservedObject private var appModeManager = AppModeManager.shared
    @ObservedObject private var cloudKitManager = CloudKitManager.shared
    @ObservedObject private var lockCodeManager = LockCodeManager.shared

    @State private var showSettings = false
    @State private var showNFCScanSheet = false
    @State private var showPersonalProfiles = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Header
                    headerSection

                    // Family connection status
                    familyConnectionSection

                    // Active unlock banner
                    if let unlock = childPolicyEnforcer.currentUnlock, !unlock.isExpired {
                        activeUnlockBanner(unlock)
                    }

                    // Restrictions summary
                    restrictionsSummaryCard

                    // Active policies
                    if !childPolicyEnforcer.activePolicies.isEmpty {
                        policiesSection
                    }

                    // NFC unlock section
                    if childPolicyEnforcer.nfcUnlockAvailable {
                        nfcUnlockSection
                    }

                    // Personal profiles section
                    personalProfilesSection

                    // Sync status
                    syncStatusFooter
                }
                .padding()
            }
            .navigationTitle("My Screen Time")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showPersonalProfiles = true
                    } label: {
                        Image(systemName: "person.fill")
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gear")
                    }
                }
            }
            .refreshable {
                await childPolicyEnforcer.syncPolicies()
                _ = try? await cloudKitManager.fetchSharedLockCodes()
            }
            .onAppear {
                childPolicyEnforcer.startEnforcing()
                // Check family connection status
                Task {
                    _ = try? await cloudKitManager.fetchSharedLockCodes()
                }
            }
            .sheet(isPresented: $showSettings) {
                ChildSettingsView()
            }
            .sheet(isPresented: $showNFCScanSheet) {
                NFCUnlockSheet()
            }
            .fullScreenCover(isPresented: $showPersonalProfiles) {
                NavigationStack {
                    HomeView()
                        .toolbar {
                            ToolbarItem(placement: .navigationBarLeading) {
                                Button("Back") {
                                    showPersonalProfiles = false
                                }
                            }
                        }
                }
            }
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "shield.checkered")
                    .font(.title2)
                    .foregroundColor(.accentColor)

                Text("Screen Time")
                    .font(.title2)
                    .fontWeight(.bold)
            }

            Text("Your parent has set these screen time rules for you")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    private var familyConnectionSection: some View {
        let isConnected = cloudKitManager.isConnectedToFamily
        let hasLockCode = !cloudKitManager.sharedLockCodes.isEmpty

        return HStack(spacing: 12) {
            Image(systemName: isConnected ? "link.circle.fill" : "link.circle")
                .font(.title2)
                .foregroundColor(isConnected ? .green : .orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(isConnected ? "Linked to Parent" : "Not Linked")
                    .font(.subheadline)
                    .fontWeight(.medium)

                if isConnected {
                    HStack(spacing: 4) {
                        Image(systemName: hasLockCode ? "lock.fill" : "lock.open")
                            .font(.caption2)
                        Text(hasLockCode ? "Lock code active" : "No lock code set")
                            .font(.caption)
                    }
                    .foregroundColor(.secondary)
                } else {
                    Text("Ask a parent to send you an invitation link")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if isConnected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(isConnected ? .systemGreen : .systemOrange).opacity(0.1))
        )
    }

    private func activeUnlockBanner(_ unlock: NFCUnlockSession) -> some View {
        HStack(spacing: 16) {
            Image(systemName: "lock.open.fill")
                .font(.title2)
                .foregroundColor(.green)

            VStack(alignment: .leading, spacing: 4) {
                Text("Apps Unlocked")
                    .font(.headline)
                    .foregroundColor(.green)

                Text("\(unlock.policyName) - \(unlock.remainingTimeFormatted) remaining")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Progress ring
            ZStack {
                Circle()
                    .stroke(Color.green.opacity(0.2), lineWidth: 4)
                    .frame(width: 40, height: 40)

                Circle()
                    .trim(from: 0, to: CGFloat(unlock.remainingTime / TimeInterval(unlock.durationMinutes * 60)))
                    .stroke(Color.green, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(width: 40, height: 40)
                    .rotationEffect(.degrees(-90))
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.green.opacity(0.1))
        )
    }

    private var restrictionsSummaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: childPolicyEnforcer.activePolicies.isEmpty ? "checkmark.shield.fill" : "shield.fill")
                    .font(.title3)
                    .foregroundColor(childPolicyEnforcer.activePolicies.isEmpty ? .green : .orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text(childPolicyEnforcer.activePolicies.isEmpty ? "No Restrictions" : "Restrictions Active")
                        .font(.headline)

                    Text(childPolicyEnforcer.restrictionsSummary)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private var policiesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Active Rules")
                .font(.headline)

            ForEach(childPolicyEnforcer.activePolicies) { policy in
                ChildPolicyCard(policy: policy)
            }
        }
    }

    private var personalProfilesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("My Profiles")
                .font(.headline)

            Button {
                showPersonalProfiles = true
            } label: {
                HStack(spacing: 16) {
                    Image(systemName: "person.fill")
                        .font(.title2)
                        .foregroundColor(.white)
                        .frame(width: 50, height: 50)
                        .background(Circle().fill(Color.blue))

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Personal Focus Profiles")
                            .font(.headline)
                            .foregroundColor(.primary)

                        Text("Create your own focus profiles for self-control")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var nfcUnlockSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Unlock Apps")
                .font(.headline)

            Button {
                showNFCScanSheet = true
            } label: {
                HStack(spacing: 16) {
                    Image(systemName: "wave.3.right")
                        .font(.title2)
                        .foregroundColor(.white)
                        .frame(width: 50, height: 50)
                        .background(Circle().fill(Color.accentColor))

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Scan NFC Tag")
                            .font(.headline)
                            .foregroundColor(.primary)

                        Text("Temporarily unlock apps set by your parent")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var syncStatusFooter: some View {
        HStack {
            if let lastSync = childPolicyEnforcer.lastSyncTime {
                Image(systemName: "checkmark.icloud")
                    .foregroundColor(.green)
                Text("Last synced \(lastSync, style: .relative) ago")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if let error = childPolicyEnforcer.syncError {
                Image(systemName: "exclamationmark.icloud")
                    .foregroundColor(.red)
                Text("Sync error: \(error)")
                    .font(.caption)
                    .foregroundColor(.red)
            } else {
                Image(systemName: "icloud")
                    .foregroundColor(.secondary)
                Text("Syncing...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top)
    }
}

// MARK: - Child Policy Card

struct ChildPolicyCard: View {
    let policy: FamilyPolicy

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(policy.name)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Spacer()

                if policy.nfcUnlockEnabled {
                    Image(systemName: "wave.3.right")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                }
            }

            // Show blocked categories
            if !policy.blockedCategories.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(policy.blockedCategories.prefix(3)) { category in
                            Label(category.displayName, systemImage: category.iconName)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule()
                                        .fill(Color.red.opacity(0.1))
                                )
                                .foregroundColor(.red)
                        }

                        if policy.blockedCategories.count > 3 {
                            Text("+\(policy.blockedCategories.count - 3)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            // Show unlock duration if available
            if policy.nfcUnlockEnabled {
                Text("Tap NFC tag to unlock for \(policy.unlockDurationMinutes) min")
                    .font(.caption)
                    .foregroundColor(.accentColor)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.tertiarySystemBackground))
        )
    }
}

// MARK: - NFC Unlock Sheet

struct NFCUnlockSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var childPolicyEnforcer = ChildPolicyEnforcer.shared

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                // NFC animation/icon
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.1))
                        .frame(width: 150, height: 150)

                    Circle()
                        .fill(Color.accentColor.opacity(0.2))
                        .frame(width: 100, height: 100)

                    Image(systemName: childPolicyEnforcer.isScanning ? "wave.3.right" : "wave.3.right.circle.fill")
                        .font(.system(size: 50))
                        .foregroundColor(.accentColor)
                        .symbolEffect(.pulse, isActive: childPolicyEnforcer.isScanning)
                }

                VStack(spacing: 8) {
                    if childPolicyEnforcer.isScanning {
                        Text("Hold your iPhone near the NFC tag")
                            .font(.headline)
                        Text("Make sure the tag is the one your parent set up")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    } else if let error = childPolicyEnforcer.scanError {
                        Text("Scan Failed")
                            .font(.headline)
                            .foregroundColor(.red)
                        Text(error)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    } else {
                        Text("Ready to Scan")
                            .font(.headline)
                        Text("Tap the button below to start scanning")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                .multilineTextAlignment(.center)

                Spacer()

                // Action buttons
                VStack(spacing: 12) {
                    if !childPolicyEnforcer.isScanning {
                        Button {
                            childPolicyEnforcer.initiateNFCUnlock()
                        } label: {
                            Text("Start Scanning")
                                .fontWeight(.semibold)
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                                .background(Color.accentColor)
                                .foregroundColor(.white)
                                .cornerRadius(12)
                        }
                    }

                    Button {
                        if childPolicyEnforcer.isScanning {
                            childPolicyEnforcer.cancelNFCScan()
                        }
                        dismiss()
                    } label: {
                        Text(childPolicyEnforcer.isScanning ? "Cancel" : "Close")
                            .fontWeight(.medium)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(Color(.secondarySystemBackground))
                            .foregroundColor(.primary)
                            .cornerRadius(12)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 32)
            }
            .navigationTitle("NFC Unlock")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: childPolicyEnforcer.currentUnlock) { _, newValue in
                // Dismiss when unlock starts
                if newValue != nil {
                    dismiss()
                }
            }
        }
    }
}

// MARK: - Child Settings View

struct ChildSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var appModeManager = AppModeManager.shared
    @ObservedObject private var cloudKitManager = CloudKitManager.shared

    var body: some View {
        NavigationStack {
            List {
                Section("Account") {
                    HStack {
                        Label("Mode", systemImage: "person.fill")
                        Spacer()
                        Text("Child")
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Label("iCloud", systemImage: "icloud")
                        Spacer()
                        Text(cloudKitManager.isSignedIn ? "Connected" : "Not Connected")
                            .foregroundColor(cloudKitManager.isSignedIn ? .green : .red)
                    }
                }

                Section("About") {
                    HStack {
                        Label("Version", systemImage: "info.circle")
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                            .foregroundColor(.secondary)
                    }
                }

                Section {
                    Button("Switch to Individual Mode") {
                        // Note: This should ideally require parent approval
                        // For now, allow switching but the user will need to re-authorize
                        appModeManager.selectMode(.individual)
                    }
                } footer: {
                    Text("Switching to Individual Mode removes parent-managed restrictions. This may require parent approval.")
                }

                Section {
                    Text("You can create your own focus profiles in addition to parent-managed restrictions. Your personal profiles use separate settings that you control.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } header: {
                    Text("About Personal Profiles")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    ChildDashboardView()
}
