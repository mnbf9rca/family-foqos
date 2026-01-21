import SwiftUI

/// Main dashboard view for parents to manage lock codes and enrolled children
struct ParentDashboardView: View {
    @ObservedObject private var cloudKitManager = CloudKitManager.shared
    @ObservedObject private var appModeManager = AppModeManager.shared
    @ObservedObject private var lockCodeManager = LockCodeManager.shared

    @State private var showSettings = false
    @State private var showPersonalProfiles = false
    @State private var showLockCodeSetup = false
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

                    // Enrolled children section
                    enrolledChildrenSection

                    // How to use section
                    howToUseSection
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
            }
            .refreshable {
                await refreshData()
            }
            .task {
                await refreshData()
            }
            .sheet(isPresented: $showSettings) {
                ParentSettingsView()
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

            Text("Set up lock codes to protect profiles on your children's devices")
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
                Text("Sign in to iCloud to sync lock codes with your children's devices.")
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
                // Show lock code status
                LockCodeStatusCard(
                    onEdit: {
                        showLockCodeSetup = true
                    }
                )
            } else {
                // No lock code set - show setup prompt
                NoLockCodeCard(onSetup: {
                    showLockCodeSetup = true
                })
            }
        }
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
                        Text("Tap 'Add Child' to invite your child's device and share the lock code with them.")
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

    private var howToUseSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How It Works")
                .font(.headline)

            VStack(alignment: .leading, spacing: 16) {
                HowToUseStep(
                    number: 1,
                    title: "Set a Lock Code",
                    description: "Create a 4-digit code that you'll remember"
                )

                HowToUseStep(
                    number: 2,
                    title: "Add Your Children",
                    description: "Invite your child's device using the Add Child button"
                )

                HowToUseStep(
                    number: 3,
                    title: "Create Managed Profiles",
                    description: "On your child's device, create profiles and enable 'Parent-Controlled'"
                )

                HowToUseStep(
                    number: 4,
                    title: "Child Needs Code to Edit",
                    description: "Your child will need your lock code to modify or delete managed profiles"
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
            _ = try await cloudKitManager.fetchEnrolledChildren()
            await lockCodeManager.fetchLockCodes()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
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

                Text("Your lock code is active and will be required to edit managed profiles")
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

                Text("Set up a lock code to protect profiles on your children's devices")
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
            Text("This will stop sharing your lock code with \(child.displayName). They will no longer be able to use managed profiles.")
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
                    Text("Switch back to controlling your own screen time instead of managing children's profiles.")
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
