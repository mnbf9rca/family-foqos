import SwiftData
import SwiftUI

/// Main dashboard view for children subject to parent lock codes.
/// Shows locked profiles and provides access to personal profiles.
struct ChildDashboardView: View {
  @Environment(\.modelContext) private var modelContext
  @Query(sort: \BlockedProfiles.order) private var allProfiles: [BlockedProfiles]

  @ObservedObject private var appModeManager = AppModeManager.shared
  @ObservedObject private var cloudKitManager = CloudKitManager.shared
  @ObservedObject private var lockCodeManager = LockCodeManager.shared

  @State private var showSettings = false
  @State private var showPersonalProfiles = false
  @State private var showEditLockedProfiles = false
  @State private var showCodeEntry = false
  @State private var enteredCode = ""
  @State private var codeError: String?

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
        _ = try? await cloudKitManager.fetchSharedLockCodes()
      }
      .onAppear {
        Task {
          _ = try? await cloudKitManager.fetchSharedLockCodes()
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

      Text("Manage your focus profiles and screen time")
        .font(.subheadline)
        .foregroundColor(.secondary)
    }
  }

  private var parentLinkSection: some View {
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

  private var lockedProfilesSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Locked Profiles")
          .font(.headline)

        Spacer()

        // Edit button - requires lock code
        if !cloudKitManager.sharedLockCodes.isEmpty {
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
            LockedProfileCard(profile: profile)
          }
        }

        Text("These profiles require a lock code to edit or delete")
          .font(.caption)
          .foregroundColor(.secondary)
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

            Text(unlockedProfiles.isEmpty
              ? "Create focus profiles to block distracting apps"
              : "\(unlockedProfiles.count) profile\(unlockedProfiles.count == 1 ? "" : "s") you can edit")
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
  let profile: BlockedProfiles

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "lock.fill")
        .font(.title3)
        .foregroundColor(.orange)

      VStack(alignment: .leading, spacing: 2) {
        Text(profile.name)
          .font(.subheadline)
          .fontWeight(.medium)

        Text("\(FamilyActivityUtil.countSelectedActivities(profile.selectedActivity)) apps blocked")
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

        if let error = errorMessage {
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
        .disabled(enteredCode.count != 4)
        .padding(.horizontal)
        .padding(.bottom, 32)
      }
      .navigationTitle("Lock Code")
      .navigationBarTitleDisplayMode(.inline)
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
    if lockCodeManager.validateCode(enteredCode) {
      onSuccess()
    } else {
      errorMessage = "Incorrect code. Try again."
      enteredCode = ""
    }
  }
}

// MARK: - Edit Locked Profiles Sheet

struct EditLockedProfilesSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext

  let profiles: [BlockedProfiles]

  var body: some View {
    NavigationStack {
      List {
        Section {
          ForEach(profiles) { profile in
            Toggle(isOn: Binding(
              get: { profile.isManaged },
              set: { newValue in
                profile.isManaged = newValue
                try? modelContext.save()
              }
            )) {
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
          Text("Locked profiles require the lock code to edit, delete, or stop.")
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

struct ChildSettingsView: View {
  @Environment(\.dismiss) private var dismiss
  @ObservedObject private var appModeManager = AppModeManager.shared
  @ObservedObject private var cloudKitManager = CloudKitManager.shared
  @ObservedObject private var lockCodeManager = LockCodeManager.shared

  @State private var showCodeEntry = false
  @State private var showSwitchConfirmation = false

  private var hasLockCode: Bool {
    !cloudKitManager.sharedLockCodes.isEmpty
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
            if hasLockCode {
              showCodeEntry = true
            } else {
              // No lock code set, show confirmation directly
              showSwitchConfirmation = true
            }
          }
        } footer: {
          Text("Switching to Individual Mode removes parental controls. \(hasLockCode ? "Requires lock code." : "")")
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
            showSwitchConfirmation = true
          },
          onCancel: {
            showCodeEntry = false
          }
        )
      }
      .alert("Switch to Individual Mode?", isPresented: $showSwitchConfirmation) {
        Button("Cancel", role: .cancel) { }
        Button("Switch", role: .destructive) {
          appModeManager.selectMode(.individual)
          dismiss()
        }
      } message: {
        Text("This will remove parental controls from this device.")
      }
    }
  }
}

#Preview {
  ChildDashboardView()
}
