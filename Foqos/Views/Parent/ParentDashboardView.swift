import CloudKit
import SwiftUI

/// Main dashboard view for parents to manage lock codes and family members
struct ParentDashboardView: View {
    @ObservedObject private var cloudKitManager = CloudKitManager.shared
    @ObservedObject private var appModeManager = AppModeManager.shared
    @ObservedObject private var lockCodeManager = LockCodeManager.shared

    @State private var showLockCodeSetup = false
    @State private var showError = false
    @State private var errorMessage = ""

    // Share coordinator for direct sharing
    @StateObject private var shareCoordinator = ShareCoordinator()

    /// Whether the page is functional (iCloud signed in and available)
    private var isPageFunctional: Bool {
        cloudKitManager.isSignedIn
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Header
                    headerSection

                    // iCloud status
                    if !cloudKitManager.isSignedIn {
                        iCloudWarning
                    }

                    // Lock code management section
                    lockCodeSection
                        .disabled(!isPageFunctional)
                        .opacity(isPageFunctional ? 1.0 : 0.5)

                    // Co-parents section
                    coParentsSection
                        .disabled(!isPageFunctional)
                        .opacity(isPageFunctional ? 1.0 : 0.5)

                    // Children section
                    childrenSection
                        .disabled(!isPageFunctional)
                        .opacity(isPageFunctional ? 1.0 : 0.5)

                    // How to use section
                    howToUseSection
                }
                .padding()
            }
            .navigationTitle("Family Controls")
            .refreshable {
                await refreshData()
            }
            .task {
                await refreshData()
            }
            .sheet(isPresented: $showLockCodeSetup) {
                LockCodeSetupView(
                    title: "Set Lock Code",
                    onSave: { code in
                        Task {
                            do {
                                try await lockCodeManager.setLockCode(code, scope: .allChildren)
                            } catch {
                                await MainActor.run {
                                    errorMessage = error.localizedDescription
                                    showError = true
                                }
                            }
                        }
                    }
                )
            }
            .enrollFamilyMemberSheet(coordinator: shareCoordinator)
            .alert("Error", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "person.2.fill")
                    .font(.title2)
                    .foregroundColor(.accentColor)

                Text("Parental Controls")
                    .font(.title2)
                    .fontWeight(.bold)
            }

            Text("Manage lock codes and linked devices for parent-controlled profiles")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    private var iCloudWarning: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.icloud.fill")
                    .font(.title2)
                    .foregroundColor(.orange)

                VStack(alignment: .leading, spacing: 4) {
                    Text("iCloud Not Available")
                        .font(.headline)
                    Text("Sign in to iCloud to enable family controls. All features below are disabled until iCloud is available.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }

            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                HStack {
                    Image(systemName: "gear")
                    Text("Open Settings")
                }
                .font(.subheadline)
                .fontWeight(.medium)
            }
            .buttonStyle(.bordered)
            .tint(.orange)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.orange.opacity(0.15))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                )
        )
    }

    private var lockCodeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Lock Code")
                    .font(.headline)

                Spacer()

                if lockCodeManager.isLoading {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }

            if lockCodeManager.hasAnyLockCode {
                LockCodeStatusCard(
                    onEdit: {
                        showLockCodeSetup = true
                    }
                )
            } else {
                NoLockCodeCard(onSetup: {
                    showLockCodeSetup = true
                })
            }
        }
    }

    private var coParentsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Parents")
                    .font(.headline)

                Spacer()

                Button {
                    shareCoordinator.enrollFamilyMember(role: .parent)
                } label: {
                    Label("Add", systemImage: "plus")
                        .font(.subheadline)
                }
            }

            let parents = cloudKitManager.familyMembers.parents

            if parents.isEmpty {
                EmptyMemberCard(
                    icon: "person.fill",
                    title: "No other Parents",
                    description: "Add another parent to share lock code management"
                )
            } else {
                ForEach(parents) { member in
                    FamilyMemberCard(member: member, onRemove: {
                        removeMember(member)
                    })
                }
            }
        }
    }

    private var childrenSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Children")
                    .font(.headline)

                Spacer()

                Button {
                    shareCoordinator.enrollFamilyMember(role: .child)
                } label: {
                    Label("Add", systemImage: "plus")
                        .font(.subheadline)
                }
            }

            let children = cloudKitManager.familyMembers.children

            if children.isEmpty {
                EmptyMemberCard(
                    icon: "face.smiling",
                    title: "No Children",
                    description: "Add a child to set the lock code on their device"
                )
            } else {
                ForEach(children) { member in
                    FamilyMemberCard(member: member, onRemove: {
                        removeMember(member)
                    })
                }
            }

            // Show pending/non-accepted invitations (includes people who left)
            let nonAcceptedParticipants = cloudKitManager.shareParticipants.filter {
                $0.acceptanceStatus != .accepted
            }
            if !nonAcceptedParticipants.isEmpty {
                Text("Pending Invitations")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.top, 8)

                ForEach(nonAcceptedParticipants, id: \.userIdentity.userRecordID) { participant in
                    PendingInvitationCard(
                        participant: participant,
                        onRemove: {
                            removeParticipant(participant)
                        }
                    )
                }
            }
        }
    }

    private var howToUseSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How It Works")
                .font(.headline)

            VStack(alignment: .leading, spacing: 16) {
                HowToUseStep(
                    number: 1,
                    title: "Set a Lock Code",
                    description: "Create a 4-digit code that all parents will share"
                )

                HowToUseStep(
                    number: 2,
                    title: "Link Devices",
                    description: "Invite other parents and children to share lock codes"
                )

                HowToUseStep(
                    number: 3,
                    title: "Create Managed Profiles",
                    description: "On a child's device, create profiles with 'Parent-Controlled' enabled"
                )

                HowToUseStep(
                    number: 4,
                    title: "Children Need Code",
                    description: "Children need the lock code to edit or delete managed profiles"
                )
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.tertiarySystemBackground))
            )
        }
    }

    // MARK: - Actions

    private func refreshData() async {
        do {
            // Refresh share participants to show pending invitations
            await cloudKitManager.refreshShareParticipants()

            // Sync share participants - creates FamilyMember records for accepted ones
            do {
                try await cloudKitManager.syncShareParticipantsToFamilyMembers()
            } catch {
                Log.error("Failed to sync share participants: \(error)", category: .cloudKit)
            }

            _ = try await cloudKitManager.fetchFamilyMembers()
            await lockCodeManager.fetchLockCodes()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func removeMember(_ member: FamilyMember) {
        Task {
            do {
                try await cloudKitManager.deleteFamilyMember(member)
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }
        }
    }

    private func removeParticipant(_ participant: CKShare.Participant) {
        Task {
            do {
                try await cloudKitManager.removeShareParticipant(participant)
                await refreshData()
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }
        }
    }
}

// MARK: - Lock Code Status Card

struct LockCodeStatusCard: View {
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "lock.shield.fill")
                .font(.largeTitle)
                .foregroundColor(.green)

            VStack(alignment: .leading, spacing: 4) {
                Text("Lock Code Set")
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text("Your lock code is active and shared with all parents")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button("Change") {
                onEdit()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.green.opacity(0.1))
        )
    }
}

// MARK: - No Lock Code Card

struct NoLockCodeCard: View {
    let onSetup: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.open.fill")
                .font(.system(size: 40))
                .foregroundColor(.orange)

            VStack(spacing: 4) {
                Text("No Lock Code Set")
                    .font(.headline)

                Text("Setting a lock code makes this a parent device. You can then link children's devices to share the code.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                onSetup()
            } label: {
                Label("Set Lock Code", systemImage: "lock.fill")
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.tertiarySystemBackground))
        )
    }
}

// MARK: - Empty Member Card

struct EmptyMemberCard: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.tertiarySystemBackground))
        )
    }
}

// MARK: - How To Use Step

struct HowToUseStep: View {
    let number: Int
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.accentColor))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Family Member Card

struct FamilyMemberCard: View {
    let member: FamilyMember
    let onRemove: () -> Void

    @State private var showRemoveConfirmation = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: member.role.iconName)
                .font(.title)
                .foregroundColor(member.role == .parent ? .blue : .accentColor)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(member.displayName)
                        .font(.subheadline)
                        .fontWeight(.medium)

                    Text(member.role.displayName)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(member.role == .parent ? Color.blue.opacity(0.2) : Color.accentColor.opacity(0.2))
                        )
                }

                Text("Added \(member.enrolledAt, style: .date)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Circle()
                .fill(member.isActive ? Color.green : Color.gray)
                .frame(width: 8, height: 8)

            Button(role: .destructive) {
                showRemoveConfirmation = true
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.tertiarySystemBackground))
        )
        .confirmationDialog(
            "Remove \(member.displayName)",
            isPresented: $showRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                onRemove()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will unlink \(member.displayName) from locked Foqos controls. They will no longer receive your lock code.")
        }
    }
}

// MARK: - Pending Invitation Card

struct PendingInvitationCard: View {
    let participant: CKShare.Participant
    let onRemove: () -> Void

    @State private var showRemoveConfirmation = false

    var displayName: String {
        // Try name first (only available after acceptance)
        if let name = participant.userIdentity.nameComponents?.formatted(), !name.isEmpty {
            return name
        }
        // Try email used to invite
        if let email = participant.userIdentity.lookupInfo?.emailAddress, !email.isEmpty {
            return email
        }
        // Try phone used to invite
        if let phone = participant.userIdentity.lookupInfo?.phoneNumber, !phone.isEmpty {
            return phone
        }
        // Fallback based on status
        switch participant.acceptanceStatus {
        case .pending:
            return "Pending Invitation"
        case .removed:
            return "Unlinked Device"
        default:
            return "Unknown"
        }
    }

    var statusText: String {
        switch participant.acceptanceStatus {
        case .pending:
            return "Invitation sent"
        case .accepted:
            return "Accepted"
        case .removed:
            return "Left - tap to revoke"
        case .unknown:
            return "Unknown"
        @unknown default:
            return "Unknown"
        }
    }

    var statusColor: Color {
        switch participant.acceptanceStatus {
        case .pending:
            return .orange
        case .removed:
            return .red
        default:
            return .orange
        }
    }

    var body: some View {
        Button {
            showRemoveConfirmation = true
        } label: {
            HStack(spacing: 12) {
                Image(
                    systemName: participant.acceptanceStatus == .removed
                        ? "person.crop.circle.badge.xmark" : "person.crop.circle.badge.clock"
                )
                .font(.title2)
                .foregroundColor(statusColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)

                    Text(statusText)
                        .font(.caption)
                        .foregroundColor(statusColor)
                }

                Spacer()

                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(statusColor.opacity(0.1))
            )
        }
        .buttonStyle(.plain)
        .confirmationDialog(
            "Remove \(displayName)?",
            isPresented: $showRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                onRemove()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They will need a new invitation to link again.")
        }
    }
}

// MARK: - Add Family Member View

struct AddFamilyMemberView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var coordinator = ShareCoordinator()

    let role: FamilyRole

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Role info
                VStack(spacing: 16) {
                    Image(systemName: role.iconName)
                        .font(.system(size: 48))
                        .foregroundColor(role == .parent ? .blue : .accentColor)

                    Text("Add \(role.displayName)")
                        .font(.title2)
                        .fontWeight(.bold)

                    Text(role.description)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 24)

                Spacer()

                // Instructions
                VStack(alignment: .leading, spacing: 12) {
                    Text("How it works")
                        .font(.headline)

                    HStack(alignment: .top, spacing: 12) {
                        Text("1")
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Color.accentColor))

                        Text("Tap 'Send Invitation' to share a link")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }

                    HStack(alignment: .top, spacing: 12) {
                        Text("2")
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Color.accentColor))

                        Text("The \(role.displayName.lowercased()) opens the link on their device")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }

                    HStack(alignment: .top, spacing: 12) {
                        Text("3")
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Color.accentColor))

                        Text("Their device will be linked to yours")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(.tertiarySystemBackground))
                )

                Spacer()

                // Add button
                Button {
                    coordinator.enrollFamilyMember(role: role)
                } label: {
                    if coordinator.isPreparingShare {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    } else {
                        Label("Send Invitation", systemImage: "square.and.arrow.up")
                            .fontWeight(.semibold)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(coordinator.isPreparingShare)
            }
            .padding()
            .navigationTitle("Add \(role.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .enrollFamilyMemberSheet(coordinator: coordinator)
            .alert("Error", isPresented: .constant(coordinator.shareError != nil)) {
                Button("OK") {
                    coordinator.shareError = nil
                }
            } message: {
                Text(coordinator.shareError ?? "")
            }
        }
    }
}

#Preview {
    ParentDashboardView()
}
