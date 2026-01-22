import SwiftUI

/// Main dashboard view for parents to manage lock codes and family members
struct ParentDashboardView: View {
    @ObservedObject private var cloudKitManager = CloudKitManager.shared
    @ObservedObject private var appModeManager = AppModeManager.shared
    @ObservedObject private var lockCodeManager = LockCodeManager.shared

    @State private var showLockCodeSetup = false
    @State private var showAddMember = false
    @State private var showError = false
    @State private var errorMessage = ""

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

                    // Co-parents section
                    coParentsSection

                    // Children section
                    childrenSection

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
            .sheet(isPresented: $showAddMember) {
                AddFamilyMemberView()
            }
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

                Text("Family Dashboard")
                    .font(.title2)
                    .fontWeight(.bold)
            }

            Text("Manage lock codes and family members for parent-controlled profiles")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    private var iCloudWarning: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.icloud.fill")
                .font(.title2)
                .foregroundColor(.orange)

            VStack(alignment: .leading, spacing: 4) {
                Text("iCloud Not Available")
                    .font(.headline)
                Text("Sign in to iCloud to sync with family members.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.orange.opacity(0.1))
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
                Text("Co-Parents")
                    .font(.headline)

                Spacer()

                Button {
                    showAddMember = true
                } label: {
                    Label("Add", systemImage: "plus")
                        .font(.subheadline)
                }
                .disabled(!cloudKitManager.isSignedIn)
            }

            let parents = cloudKitManager.familyMembers.parents

            if parents.isEmpty {
                EmptyMemberCard(
                    icon: "person.fill",
                    title: "No Co-Parents",
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
                    showAddMember = true
                } label: {
                    Label("Add", systemImage: "plus")
                        .font(.subheadline)
                }
                .disabled(!cloudKitManager.isSignedIn)
            }

            let children = cloudKitManager.familyMembers.children

            if children.isEmpty {
                EmptyMemberCard(
                    icon: "face.smiling",
                    title: "No Children",
                    description: "Add a child to share the lock code with their device"
                )
            } else {
                ForEach(children) { member in
                    FamilyMemberCard(member: member, onRemove: {
                        removeMember(member)
                    })
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
                    title: "Add Family Members",
                    description: "Invite co-parents and children to your family"
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

                Text("Set up a lock code to protect profiles on children's devices")
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
            "Remove \(member.role.displayName)",
            isPresented: $showRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                onRemove()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove \(member.displayName) from your family. They will no longer have access to the shared lock code.")
        }
    }
}

// MARK: - Add Family Member View

struct AddFamilyMemberView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var coordinator = ShareCoordinator()

    @State private var selectedRole: FamilyRole = .child

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Role selection
                VStack(alignment: .leading, spacing: 12) {
                    Text("Who are you adding?")
                        .font(.headline)

                    ForEach(FamilyRole.allCases, id: \.self) { role in
                        Button {
                            selectedRole = role
                        } label: {
                            HStack(spacing: 16) {
                                Image(systemName: role.iconName)
                                    .font(.title2)
                                    .foregroundColor(role == .parent ? .blue : .accentColor)
                                    .frame(width: 40)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(role.displayName)
                                        .font(.headline)
                                        .foregroundColor(.primary)

                                    Text(role.description)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .multilineTextAlignment(.leading)
                                }

                                Spacer()

                                if selectedRole == role {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.accentColor)
                                }
                            }
                            .padding()
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(selectedRole == role ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: 2)
                            )
                        }
                    }
                }

                Spacer()

                // Add button
                Button {
                    coordinator.enrollFamilyMember(role: selectedRole)
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
            .navigationTitle("Add Family Member")
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
