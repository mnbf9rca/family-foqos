import Combine
import FamilyControls
import SwiftData
import SwiftUI

/// Main dashboard view for children subject to parent lock codes.
/// Shows locked profiles and provides access to personal profiles.
struct ChildDashboardView: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(\.dismiss) private var dismiss
  @SafeQuery(sort: \BlockedProfiles.order) private var allProfiles: [BlockedProfiles]

  @ObservedObject private var appModeManager = AppModeManager.shared
  @ObservedObject private var cloudKitManager = CloudKitManager.shared
  @ObservedObject private var lockCodeManager = LockCodeManager.shared

  @State private var showSettings = false
  @State private var showPersonalProfiles = false
  @State private var showEditLockedProfiles = false
  @State private var showCodeEntry = false
  @State private var enteredCode = ""
  @State private var codeError: String?
  @State private var isFetchingLockCodes = false
  @State private var showAuthorizationLostAlert = false
  @State private var isVerifyingAuthorization = false

  /// Profiles that are locked (require code to edit)
  private var lockedProfiles: [BlockedProfiles] {
    allProfiles.filter { $0.isManaged }
  }

  /// Profiles that are not locked (child can freely edit)
  private var unlockedProfiles: [BlockedProfiles] {
    allProfiles.filter { !$0.isManaged }
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          // Header
          headerSection

          // Parent link status
          parentLinkSection

          // Locked profiles section
          lockedProfilesSection

          // Personal profiles section
          personalProfilesSection
        }
        .padding()
      }
      .navigationTitle("My Screen Time")
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button(action: { dismiss() }) {
            Image(systemName: "xmark")
          }
          .accessibilityLabel("Cancel")
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
        await fetchLockCodesIfNeeded()
      }
      .onAppear {
        Task {
          await fetchLockCodesIfNeeded()
        }
      }
      .sheet(isPresented: $showSettings) {
        ChildSettingsView()
      }
      .sheet(isPresented: $showCodeEntry) {
        LockCodeEntrySheet(
          onSuccess: {
            showCodeEntry = false
            showEditLockedProfiles = true
          },
          onCancel: {
            showCodeEntry = false
          }
        )
      }
      .sheet(isPresented: $showEditLockedProfiles) {
        EditLockedProfilesSheet(profiles: allProfiles)
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
      .onChange(of: appModeManager.currentMode) { _, newMode in
        // Auto-dismiss when switching away from child mode
        if newMode != .child {
          dismiss()
        }
      }
      .task {
        // Verify child authorization when view appears
        await verifyChildAuthorization()
      }
      .alert("Authorization Lost", isPresented: $showAuthorizationLostAlert) {
        Button("Switch to Individual Mode", role: .destructive) {
          handleAuthorizationLost()
        }
        Button("Try Again", role: .cancel) {
          Task {
            await verifyChildAuthorization()
          }
        }
      } message: {
        Text(
          "This device is no longer authorized as a child in Apple Family Sharing. Ask a parent to check Settings > Family > Screen Time, or switch to individual mode to manage your own screen time."
        )
      }
    }
  }

  // MARK: - Authorization Verification

  /// Verify that this device still has valid child authorization
  @MainActor
  private func verifyChildAuthorization() async {
    guard !isVerifyingAuthorization else { return }
    isVerifyingAuthorization = true
    defer { isVerifyingAuthorization = false }

    let result = await AuthorizationVerifier.shared.verifyChildAuthorization()

    if !result.isAuthorized {
      showAuthorizationLostAlert = true
    }
  }

  /// Handle when authorization is lost
  @MainActor
  private func handleAuthorizationLost() {
    Task {
      _ = await AuthorizationVerifier.shared.handleAuthorizationLoss()
      dismiss()
    }
  }

  // MARK: - Data Fetching

  /// Fetch lock codes if not already fetching (prevents duplicate concurrent requests)
  private func fetchLockCodesIfNeeded() async {
    guard !isFetchingLockCodes else { return }
    isFetchingLockCodes = true
    defer { isFetchingLockCodes = false }
    await lockCodeManager.refreshSharedLockCodesForVerification()
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

      Text("Manage your focus profiles and screen time")
        .font(.subheadline)
        .foregroundColor(.secondary)
    }
  }

  private var parentLinkSection: some View {
    let isConnected = cloudKitManager.isConnectedToFamily
    let hasLockCode = lockCodeManager.canVerifyCode

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

  private var lockedProfilesSection: some View {
    let hasLockCodes = lockCodeManager.canVerifyCode

    return VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(hasLockCodes ? "Locked Profiles" : "Parent-Managed Profiles")
          .font(.headline)

        Spacer()

        // Edit button - requires lock code
        if hasLockCodes {
          Button {
            showCodeEntry = true
          } label: {
            Label("Edit", systemImage: "lock.fill")
              .font(.subheadline)
          }
        }
      }

      if lockedProfiles.isEmpty {
        // No locked profiles
        HStack(spacing: 12) {
          Image(systemName: "lock.open.fill")
            .font(.title2)
            .foregroundColor(.green)

          VStack(alignment: .leading, spacing: 2) {
            Text("No Locked Profiles")
              .font(.subheadline)
              .fontWeight(.medium)

            Text("All your profiles can be freely edited")
              .font(.caption)
              .foregroundColor(.secondary)
          }

          Spacer()
        }
        .padding()
        .background(
          RoundedRectangle(cornerRadius: 12)
            .fill(Color(.secondarySystemBackground))
        )
      } else {
        // Show locked profiles
        VStack(spacing: 8) {
          ForEach(lockedProfiles) { profile in
            SafeModelView(profile) { p in
              // #298: snapshot inside the validity gate; do NOT hoist - see tripwire.
              LockedProfileCard(data: p.lockedProfileCardData)
            }
          }
        }

        if hasLockCodes {
          Text("These profiles require a lock code to edit or delete")
            .font(.caption)
            .foregroundColor(.secondary)
        } else {
          Text(
            "These profiles are managed by a parent but can be freely edited while no lock code is set"
          )
          .font(.caption)
          .foregroundColor(.secondary)
        }
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
            Text("All Focus Profiles")
              .font(.headline)
              .foregroundColor(.primary)

            Text(
              unlockedProfiles.isEmpty
                ? "Create focus profiles to block distracting apps"
                : "\(unlockedProfiles.count) profile\(unlockedProfiles.count == 1 ? "" : "s") you can edit"
            )
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
}

// MARK: - Locked Profile Card

struct LockedProfileCard: View {
  let data: LockedProfileCardData

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "lock.fill")
        .font(.title3)
        .foregroundColor(.orange)

      VStack(alignment: .leading, spacing: 2) {
        Text(data.name)
          .font(.subheadline)
          .fontWeight(.medium)

        Text("\(data.appsBlockedCount) apps blocked")
          .font(.caption)
          .foregroundColor(.secondary)
      }

      Spacer()

      Image(systemName: "shield.fill")
        .foregroundColor(.orange)
    }
    .padding()
    .background(
      RoundedRectangle(cornerRadius: 12)
        .fill(Color.orange.opacity(0.1))
    )
  }
}

// MARK: - Lock Code Entry Sheet

struct LockCodeEntrySheet: View {
  @ObservedObject private var lockCodeManager = LockCodeManager.shared
  @State private var enteredCode = ""
  @State private var errorMessage: String?
  @State private var lockoutSecondsRemaining: Int = 0

  private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

  private var isLockedOut: Bool {
    lockoutSecondsRemaining > 0
  }

  private var lockoutTimeString: String {
    let minutes = lockoutSecondsRemaining / 60
    let seconds = lockoutSecondsRemaining % 60
    return minutes > 0
      ? String(format: "%d:%02d", minutes, seconds)
      : "\(seconds)s"
  }

  let onSuccess: () -> Void
  let onCancel: () -> Void

  var body: some View {
    NavigationStack {
      VStack(spacing: 32) {
        Spacer()

        Image(systemName: "lock.shield.fill")
          .font(.system(size: 60))
          .foregroundColor(.accentColor)

        VStack(spacing: 8) {
          Text("Enter Lock Code")
            .font(.title2)
            .fontWeight(.bold)

          Text("Enter the 4-digit code set by your parent")
            .font(.subheadline)
            .foregroundColor(.secondary)
        }

        // Code entry field
        SecureField("Code", text: $enteredCode)
          .keyboardType(.numberPad)
          .textContentType(.oneTimeCode)
          .multilineTextAlignment(.center)
          .font(.title)
          .frame(width: 120)
          .padding()
          .background(
            RoundedRectangle(cornerRadius: 12)
              .fill(Color(.secondarySystemBackground))
          )
          .disabled(isLockedOut)
          .opacity(isLockedOut ? 0.5 : 1.0)
          .onChange(of: enteredCode) { _, newValue in
            // Limit to 4 digits
            if newValue.count > 4 {
              enteredCode = String(newValue.prefix(4))
            }
            // Auto-submit when 4 digits entered
            if enteredCode.count == 4 {
              validateCode()
            }
          }

        if isLockedOut {
          VStack(spacing: 4) {
            Text("Too many attempts")
              .font(.caption)
              .foregroundColor(.red)
              .fontWeight(.semibold)
            Text("Try again in \(lockoutTimeString)")
              .font(.caption2)
              .foregroundColor(.secondary)
          }
        } else if let error = errorMessage {
          Text(error)
            .font(.caption)
            .foregroundColor(.red)
        }

        Spacer()

        Button {
          validateCode()
        } label: {
          Text("Unlock")
            .fontWeight(.semibold)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(enteredCode.count == 4 ? Color.accentColor : Color.gray)
            .foregroundColor(.white)
            .cornerRadius(12)
        }
        .disabled(enteredCode.count != 4 || isLockedOut)
        .padding(.horizontal)
        .padding(.bottom, 32)
      }
      .navigationTitle("Lock Code")
      .navigationBarTitleDisplayMode(.inline)
      .onAppear {
        updateLockoutRemaining()
      }
      .onReceive(timer) { _ in
        updateLockoutRemaining()
      }
      .toolbar {
        ToolbarItem(placement: .navigationBarLeading) {
          Button("Cancel") {
            onCancel()
          }
        }
      }
    }
  }

  private func validateCode() {
    guard !lockCodeManager.isLockedOut else { return }

    if lockCodeManager.validateCode(enteredCode) {
      lockCodeManager.resetThrottle()
      onSuccess()
    } else {
      lockCodeManager.recordFailedAttempt()
      updateLockoutRemaining()
      errorMessage = lockCodeManager.isLockedOut ? nil : "Incorrect code. Try again."
      enteredCode = ""
    }
  }

  private func updateLockoutRemaining() {
    let remaining = lockCodeManager.lockoutRemaining()
    lockoutSecondsRemaining = remaining > 0 ? Int(ceil(remaining)) : 0
  }
}

// MARK: - Edit Locked Profiles Sheet

struct EditLockedProfilesSheet: View {
  static let lockedProfilesFooter = "Locked profiles require the lock code to edit or delete."

  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext

  let profiles: [BlockedProfiles]

  var body: some View {
    NavigationStack {
      List {
        Section {
          ForEach(profiles.valid) { profile in
            Toggle(
              isOn: Binding(
                get: { profile.isManaged },
                set: { newValue in
                  profile.isManaged = newValue
                  do {
                    try modelContext.save()
                  } catch {
                    Log.error(
                      "Failed to save managed toggle: \(error.localizedDescription)",
                      category: .ui)
                  }
                }
              )
            ) {
              HStack(spacing: 12) {
                Image(systemName: profile.isManaged ? "lock.fill" : "lock.open")
                  .foregroundColor(profile.isManaged ? .orange : .secondary)

                VStack(alignment: .leading, spacing: 2) {
                  Text(profile.name)
                    .font(.subheadline)
                    .fontWeight(.medium)

                  Text("\(FamilyActivityUtil.countSelectedActivities(profile.selectedActivity)) apps")
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
              }
            }
          }
        } header: {
          Text("Select Profiles to Lock")
        } footer: {
          Text(EditLockedProfilesSheet.lockedProfilesFooter)
        }
      }
      .navigationTitle("Edit Locked Profiles")
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

// MARK: - Child Settings View

struct EmergencySettingsLockChangeGate {
  private var pendingValue: Bool?

  mutating func request(_ newValue: Bool) {
    pendingValue = newValue
  }

  mutating func resolve(verificationSucceeded: Bool) -> Bool? {
    defer { pendingValue = nil }
    return verificationSucceeded ? pendingValue : nil
  }
}

struct ChildSettingsView: View {
  @Environment(\.dismiss) private var dismiss
  @ObservedObject private var appModeManager = AppModeManager.shared
  @ObservedObject private var cloudKitManager = CloudKitManager.shared
  @ObservedObject private var emergencyManager = EmergencyUnblockManager.shared
  @ObservedObject private var lockCodeManager = LockCodeManager.shared

  @StateObject private var shareCoordinator = ShareCoordinator()
  @State private var showCodeEntry = false
  @State private var showEmergencyLockCodeEntry = false
  @State private var emergencySettingsLockChangeGate = EmergencySettingsLockChangeGate()

  private var hasLockCode: Bool {
    lockCodeManager.canVerifyCode
  }

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

        if hasLockCode {
          Section("Emergency Access") {
            Toggle(
              isOn: Binding(
                get: { emergencyManager.isEmergencySettingsLocked() },
                set: { newValue in
                  emergencySettingsLockChangeGate.request(newValue)
                  showEmergencyLockCodeEntry = true
                }
              )
            ) {
              VStack(alignment: .leading, spacing: 4) {
                Text("Lock Emergency Reset-Period Changes")
                Text("Requires the parent lock code to change this setting on this device")
                  .font(.caption)
                  .foregroundColor(.secondary)
              }
            }
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
          Button("Remove Parental lock and switch to Individual Mode") {
            if hasLockCode {
              showCodeEntry = true
            } else {
              // No lock code set, show leave share UI directly
              showLeaveShareUI()
            }
          }
        } footer: {
          Text("This will remove you from the code sharing group and disable parental locks. \(hasLockCode ? "Requires lock code." : "")")
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
      .sheet(isPresented: $showCodeEntry) {
        LockCodeEntrySheet(
          onSuccess: {
            showCodeEntry = false
            showLeaveShareUI()
          },
          onCancel: {
            showCodeEntry = false
          }
        )
      }
      .sheet(
        isPresented: $showEmergencyLockCodeEntry,
        onDismiss: {
          _ = emergencySettingsLockChangeGate.resolve(verificationSucceeded: false)
        }
      ) {
        LockCodeEntrySheet(
          onSuccess: {
            showEmergencyLockCodeEntry = false
            if let newValue = emergencySettingsLockChangeGate.resolve(
              verificationSucceeded: true
            ) {
              emergencyManager.setEmergencySettingsLocked(newValue)
            }
          },
          onCancel: {
            showEmergencyLockCodeEntry = false
            _ = emergencySettingsLockChangeGate.resolve(verificationSucceeded: false)
          }
        )
      }
      .leaveShareSheet(coordinator: shareCoordinator)
      .onChange(of: shareCoordinator.didLeaveShare) { _, didLeave in
        if didLeave {
          // Successfully left the share via UICloudSharingController
          appModeManager.selectMode(.individual)
          dismiss()
        }
      }
    }
  }

  private func showLeaveShareUI() {
    shareCoordinator.prepareToLeaveShare()
  }
}

#Preview {
  ChildDashboardView()
    .modelContainer(for: BlockedProfiles.self, inMemory: true)
}
