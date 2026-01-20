import SwiftUI

/// Main dashboard view for parents to manage family policies
struct ParentDashboardView: View {
    @ObservedObject private var cloudKitManager = CloudKitManager.shared
    @ObservedObject private var appModeManager = AppModeManager.shared

    @State private var showNewPolicySheet = false
    @State private var policyToEdit: FamilyPolicy?
    @State private var showSettings = false
    @State private var showPersonalProfiles = false
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

                    // Enrolled children section
                    enrolledChildrenSection

                    // Policies section
                    if cloudKitManager.policies.isEmpty && !cloudKitManager.isLoading {
                        emptyStateView
                    } else {
                        policiesSection
                    }
                }
                .padding()
            }
            .navigationTitle("Family Controls")
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

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showNewPolicySheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(!cloudKitManager.isSignedIn)
                }
            }
            .refreshable {
                await refreshPolicies()
            }
            .task {
                await refreshPolicies()
            }
            .sheet(isPresented: $showNewPolicySheet) {
                ParentPolicyEditorView(policy: nil) { savedPolicy in
                    Task {
                        do {
                            try await cloudKitManager.savePolicy(savedPolicy)
                            print("Policy saved successfully: \(savedPolicy.name)")
                        } catch {
                            print("Failed to save policy: \(error)")
                            await MainActor.run {
                                errorMessage = error.localizedDescription
                                showError = true
                            }
                        }
                    }
                }
            }
            .sheet(item: $policyToEdit) { policy in
                ParentPolicyEditorView(policy: policy) { savedPolicy in
                    Task {
                        do {
                            try await cloudKitManager.savePolicy(savedPolicy)
                            print("Policy updated successfully: \(savedPolicy.name)")
                        } catch {
                            print("Failed to update policy: \(error)")
                            await MainActor.run {
                                errorMessage = error.localizedDescription
                                showError = true
                            }
                        }
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                ParentSettingsView()
            }
            .fullScreenCover(isPresented: $showPersonalProfiles) {
                NavigationStack {
                    HomeView()
                        .toolbar {
                            ToolbarItem(placement: .navigationBarLeading) {
                                Button("Back to Family") {
                                    showPersonalProfiles = false
                                }
                            }
                        }
                }
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

                Text("Parent Dashboard")
                    .font(.title2)
                    .fontWeight(.bold)
            }

            Text("Create and manage screen time policies for your children")
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
                Text("Sign in to iCloud to create and share policies with your children.")
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

    private var enrolledChildrenSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Children")
                    .font(.headline)

                Spacer()

                EnrollChildButton()
                    .disabled(!cloudKitManager.isSignedIn)
            }

            if cloudKitManager.enrolledChildren.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "person.badge.plus")
                        .font(.title2)
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("No Children Enrolled")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text("Tap 'Add Child' to invite your child's device and share policies with them.")
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
            } else {
                ForEach(cloudKitManager.enrolledChildren) { child in
                    EnrolledChildCard(child: child, onRemove: {
                        removeChild(child)
                    })
                }
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.badge.plus")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("No Policies Yet")
                .font(.headline)

            Text("Create a policy to control which apps and websites your child can access.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button {
                showNewPolicySheet = true
            } label: {
                Label("Create First Policy", systemImage: "plus")
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!cloudKitManager.isSignedIn)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var policiesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Policies")
                    .font(.headline)

                Spacer()

                if cloudKitManager.isLoading {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }

            ForEach(cloudKitManager.policies) { policy in
                PolicyCard(
                    policy: policy,
                    enrolledChildren: cloudKitManager.enrolledChildren,
                    onEdit: {
                        policyToEdit = policy
                    },
                    onDelete: {
                        deletePolicy(policy)
                    }
                )
            }
        }
    }

    // MARK: - Actions

    private func refreshPolicies() async {
        do {
            _ = try await cloudKitManager.fetchMyPolicies()
            _ = try await cloudKitManager.fetchEnrolledChildren()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func deletePolicy(_ policy: FamilyPolicy) {
        Task {
            do {
                try await cloudKitManager.deletePolicy(policy)
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }
        }
    }

    private func removeChild(_ child: EnrolledChild) {
        Task {
            do {
                try await cloudKitManager.deleteEnrolledChild(child)
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }
        }
    }
}

// MARK: - Enrolled Child Card

struct EnrolledChildCard: View {
    let child: EnrolledChild
    let onRemove: () -> Void

    @State private var showRemoveConfirmation = false

    var body: some View {
        HStack(spacing: 12) {
            // Child avatar
            Image(systemName: "person.circle.fill")
                .font(.title)
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(child.displayName)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text("Enrolled \(child.enrolledAt, style: .date)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Status
            Circle()
                .fill(child.isActive ? Color.green : Color.gray)
                .frame(width: 8, height: 8)

            // Remove button
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
            "Remove Child",
            isPresented: $showRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                onRemove()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will stop sharing policies with \(child.displayName). They will need to be re-invited to receive policies again.")
        }
    }
}

// MARK: - Policy Card

struct PolicyCard: View {
    let policy: FamilyPolicy
    let enrolledChildren: [EnrolledChild]
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var showDeleteConfirmation = false

    /// Get the names of children this policy applies to
    private var appliedChildrenText: String {
        if policy.appliesToAllChildren {
            return "All children"
        }

        let childNames = enrolledChildren
            .filter { policy.assignedChildIds.contains($0.userRecordName) }
            .map { $0.displayName }

        if childNames.isEmpty {
            return "No children assigned"
        }
        return childNames.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(policy.name)
                        .font(.headline)

                    Text(policy.summaryText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Status indicator
                Circle()
                    .fill(policy.isActive ? Color.green : Color.gray)
                    .frame(width: 10, height: 10)
            }

            // Applied to children
            HStack(spacing: 6) {
                Image(systemName: "person.2.fill")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(appliedChildrenText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            // Categories
            if !policy.blockedCategories.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(policy.blockedCategories.prefix(4)) { category in
                            Label(category.displayName, systemImage: category.iconName)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule()
                                        .fill(Color.accentColor.opacity(0.1))
                                )
                        }

                        if policy.blockedCategories.count > 4 {
                            Text("+\(policy.blockedCategories.count - 4)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            // Actions
            HStack(spacing: 12) {
                Button {
                    onEdit()
                } label: {
                    Label("Edit", systemImage: "pencil")
                        .font(.subheadline)
                }

                Spacer()

                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                        .font(.subheadline)
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .confirmationDialog(
            "Delete Policy",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                onDelete()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove the policy from all assigned children's devices.")
        }
    }
}

// MARK: - Parent Settings View

struct ParentSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var appModeManager = AppModeManager.shared

    var body: some View {
        NavigationStack {
            List {
                Section("Account") {
                    HStack {
                        Label("Mode", systemImage: "person.fill")
                        Spacer()
                        Text("Parent")
                            .foregroundColor(.secondary)
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
                        appModeManager.selectMode(.individual)
                    }
                } footer: {
                    Text("Switch back to controlling your own screen time instead of managing children's policies.")
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
    ParentDashboardView()
}
