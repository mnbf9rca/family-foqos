import CloudKit
import SwiftUI

/// Main dashboard view for parents to manage lock codes and family members
///
/// ## Child Mode Access Model (ADR 2026-02-22)
///
/// When a child opens this dashboard, controls follow a three-tier model:
///
/// | Tier | Interactivity | Computed property | Examples |
/// |------|---------------|-------------------|----------|
/// | 1. Read-only | Never interactive | N/A (always visible) | Info cards, member lists |
/// | 2. Device-local | Enabled after PIN | `deviceSettingsEnabled` | Emergency settings toggle |
/// | 3. CloudKit ops | Never interactive | `parentOperationsEnabled` | Set lock code, add/remove members |
///
/// The child sees the full dashboard — nothing is hidden. Only interactivity differs.
/// Principle: device-local settings (tier 2) can be changed with PIN; CloudKit parent
/// operations (tier 3) require parent authorization and cannot be performed by a child.
struct ParentDashboardView: View {
  @ObservedObject private var cloudKitManager = CloudKitManager.shared
  @ObservedObject private var appModeManager = AppModeManager.shared
  @ObservedObject private var lockCodeManager = LockCodeManager.shared
  @ObservedObject private var strategyManager = StrategyManager.shared
  @ObservedObject private var emergencyManager = EmergencyUnblockManager.shared
  @ObservedObject private var heartbeatManager = HeartbeatManager.shared

  @Environment(\.dismiss) private var dismiss

  @State private var showLockCodeSetup = false
  @State private var showError = false
  @State private var errorMessage = ""
  @State private var isDashboardUnlocked = false
  @State private var showLockCodeEntry = false
  @State private var showLeaveConfirmation = false
  @State private var showLeaveLockCodeEntry = false
  @State private var showClearLockCodeAlert = false
  @State private var showResetFamilySheet = false
  @State private var showResetEverythingConfirmation = false
  @State private var isResettingFamily = false
  // Share coordinator for direct sharing
  @StateObject private var shareCoordinator = ShareCoordinator()

  /// Whether the page is functional (iCloud signed in and available)
  private var isPageFunctional: Bool {
    cloudKitManager.isSignedIn
  }

  /// Whether the current user is in child mode
  private var isChildMode: Bool {
    appModeManager.currentMode == .child
  }

  /// Tier 2: device-local settings enabled after PIN unlock
  /// Controls like emergency settings toggle that are configured on this device
  /// Independent of iCloud — PIN verification uses the last-synced lock codes cached on-device
  private var deviceSettingsEnabled: Bool {
    !isChildMode || isDashboardUnlocked
  }

  /// Tier 3: CloudKit parent operations — always disabled for child
  /// Controls like set/change lock code, add/remove family members
  private var parentOperationsEnabled: Bool {
    isPageFunctional && !isChildMode
  }

  /// Whether the current user is in a family (parent or child mode)
  private var isInFamily: Bool {
    appModeManager.currentMode != .individual
  }

  /// Whether the leave button should be disabled (owner with members still present)
  private var isLeaveDisabled: Bool {
    guard appModeManager.currentMode == .parent else { return false }
    guard cloudKitManager.isShareOwner else { return false }
    return !cloudKitManager.familyMembers.isEmpty
      || !cloudKitManager.shareParticipants.isEmpty
  }

  /// Whether the child needs a PIN check before leaving
  private var childNeedsPinCheck: Bool {
    isChildMode && (lockCodeManager.hasAnyLockCode || lockCodeManager.canVerifyCode)
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          // Header
          headerSection

          // Child mode unlock banner
          if isChildMode {
            childUnlockBanner
          }

          // iCloud status
          if !cloudKitManager.isSignedIn {
            iCloudWarning
          }

          // Lock code management section
          lockCodeSection
            .disabled(!parentOperationsEnabled)
            .opacity(parentOperationsEnabled ? 1.0 : 0.5)

          // Emergency settings lock (only when lock code is set)
          if lockCodeManager.hasAnyLockCode || lockCodeManager.canVerifyCode {
            emergencyLockSection
              .disabled(!deviceSettingsEnabled)
              .opacity(deviceSettingsEnabled ? 1.0 : 0.5)
          }

          // Co-parents section
          coParentsSection
            .disabled(!parentOperationsEnabled)
            .opacity(parentOperationsEnabled ? 1.0 : 0.5)

          // Children section
          childrenSection
            .disabled(!parentOperationsEnabled)
            .opacity(parentOperationsEnabled ? 1.0 : 0.5)

          // Device heartbeat monitoring (#190)
          if !isChildMode {
            deviceStatusSection
              .disabled(!parentOperationsEnabled)
              .opacity(parentOperationsEnabled ? 1.0 : 0.5)
          }

          // Pending members section (accepted share but haven't opened the app yet)
          if !cloudKitManager.pendingParticipants.isEmpty {
            pendingMembersSection
              .disabled(!parentOperationsEnabled)
              .opacity(parentOperationsEnabled ? 1.0 : 0.5)
          }

          // Reset Family Sharing (parent mode only, danger zone)
          if !isChildMode && cloudKitManager.isConnectedToFamily {
            resetFamilySharingSection
              .disabled(!parentOperationsEnabled || isResettingFamily)
              .opacity((parentOperationsEnabled && !isResettingFamily) ? 1.0 : 0.5)
          }

          // How to use section
          howToUseSection

          // Leave family section (only for parent/child modes)
          if isInFamily {
            leaveFamilySection
          }
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
                let previousMode = appModeManager.currentMode
                try await lockCodeManager.setLockCode(code, scope: .allChildren)
                if let newMode = AppModeManager.modeAfterSettingLockCode(from: previousMode) {
                  await MainActor.run { appModeManager.selectMode(newMode) }
                }
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
      .sheet(isPresented: $showLockCodeEntry) {
        LockCodeEntryView(
          title: "Enter Lock Code",
          subtitle: "Enter the parent lock code to change device settings",
          onVerify: { code in
            lockCodeManager.validateCode(code)
          },
          onSuccess: {
            isDashboardUnlocked = true
          }
        )
      }
      .enrollFamilyMemberSheet(coordinator: shareCoordinator)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button(action: { dismiss() }) {
            Image(systemName: "xmark")
          }
          .accessibilityLabel("Cancel")
        }
      }
      .alert("Error", isPresented: $showError) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(errorMessage)
      }
      .confirmationDialog(
        "Leave Family",
        isPresented: $showLeaveConfirmation,
        titleVisibility: .visible
      ) {
        Button("Leave Family", role: .destructive) {
          if cloudKitManager.isShareOwner {
            cloudKitManager.clearSharedState()
            appModeManager.selectMode(.individual)
            dismiss()
          } else {
            shareCoordinator.prepareToLeaveShare()
          }
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text(
          "You will be removed from this family group and switched to individual mode. This cannot be undone."
        )
      }
      .sheet(isPresented: $showLeaveLockCodeEntry) {
        LockCodeEntrySheet(
          onSuccess: {
            showLeaveLockCodeEntry = false
            showLeaveConfirmation = true
          },
          onCancel: {
            showLeaveLockCodeEntry = false
          }
        )
      }
      .leaveShareSheet(coordinator: shareCoordinator)
      .onChange(of: shareCoordinator.didLeaveShare) { _, didLeave in
        if didLeave {
          appModeManager.selectMode(.individual)
          dismiss()
        }
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

  private var childUnlockBanner: some View {
    VStack(spacing: 12) {
      HStack(spacing: 12) {
        Image(systemName: isDashboardUnlocked ? "lock.open.fill" : "lock.fill")
          .font(.title2)
          .foregroundColor(isDashboardUnlocked ? .green : .accentColor)

        VStack(alignment: .leading, spacing: 4) {
          Text(isDashboardUnlocked ? "Dashboard Unlocked" : "Dashboard Locked")
            .font(.headline)
          Text(
            isDashboardUnlocked
              ? "You can now change device settings."
              : "Enter the lock code to change device settings."
          )
          .font(.caption)
          .foregroundColor(.secondary)
        }

        Spacer()
      }

      if !isDashboardUnlocked {
        Button {
          showLockCodeEntry = true
        } label: {
          HStack {
            Image(systemName: "lock.open")
            Text("Unlock")
          }
          .font(.subheadline)
          .fontWeight(.medium)
        }
        .buttonStyle(.bordered)
        .tint(.accentColor)
      }
    }
    .padding()
    .background(
      RoundedRectangle(cornerRadius: 12)
        .fill(Color.accentColor.opacity(0.1))
        .overlay(
          RoundedRectangle(cornerRadius: 12)
            .stroke(Color.accentColor.opacity(0.2), lineWidth: 1)
        )
    )
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
          },
          onClear: {
            showClearLockCodeAlert = true
          }
        )
      } else {
        NoLockCodeCard(onSetup: {
          showLockCodeSetup = true
        })
      }
    }
    .alert("Remove Lock Code?", isPresented: $showClearLockCodeAlert) {
      Button("Cancel", role: .cancel) {}
      Button("Remove", role: .destructive) {
        Task {
          do {
            try await lockCodeManager.deleteAllLockCodes()
          } catch {
            errorMessage = "Failed to remove lock code: \(error.localizedDescription)"
            showError = true
          }
        }
      }
    } message: {
      Text("Children will be able to freely edit all profiles without entering a code.")
    }
  }

  private var emergencyLockSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Emergency Settings")
        .font(.headline)

      HStack(spacing: 16) {
        Image(systemName: emergencyManager.isEmergencySettingsLocked() ? "lock.fill" : "lock.open")
          .font(.title2)
          .foregroundColor(emergencyManager.isEmergencySettingsLocked() ? .orange : .secondary)

        VStack(alignment: .leading, spacing: 4) {
          Text("Lock Emergency Settings")
            .font(.subheadline)
            .fontWeight(.medium)

          Text("Requires lock code to change reset period on children's devices")
            .font(.caption)
            .foregroundColor(.secondary)
        }

        Spacer()

        Toggle(
          "",
          isOn: Binding(
            get: { emergencyManager.isEmergencySettingsLocked() },
            set: { emergencyManager.setEmergencySettingsLocked($0) }
          )
        )
        .labelsHidden()
      }
      .padding()
      .background(
        RoundedRectangle(cornerRadius: 12)
          .fill(Color(.tertiarySystemBackground))
      )
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
          FamilyMemberCard(
            member: member,
            onRemove: {
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
          FamilyMemberCard(
            member: member,
            onRemove: {
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

  private var deviceStatusSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Device Status")
          .font(.headline)
        Spacer()
        Toggle("Notify", isOn: $heartbeatManager.heartbeatNotificationsEnabled)
          .labelsHidden()
          .toggleStyle(.switch)
          .scaleEffect(0.8)
      }

      if heartbeatManager.monitoredDevices.isEmpty {
        EmptyMemberCard(
          icon: "antenna.radiowaves.left.and.right",
          title: "No devices reporting",
          description:
            "Devices appear here once they report status. A child on an older app version won't "
            + "appear even while actively blocking — update their app to see it here."
        )
      } else {
        ForEach(heartbeatManager.monitoredDevices) { device in
          DeviceStatusCard(
            device: device,
            onSuppress: {
              heartbeatManager.toggleSuppression(for: device.id)
            },
            onRemove: {
              Task {
                await heartbeatManager.removeDevice(device)
              }
            }
          )
        }
      }
    }
  }

  private var pendingMembersSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Pending")
        .font(.headline)

      ForEach(cloudKitManager.pendingParticipants, id: \.self) { participant in
        let name =
          participant.userIdentity.nameComponents?.formatted()
          ?? participant.userIdentity.lookupInfo?.emailAddress
          ?? "Family Member"

        HStack(spacing: 12) {
          Image(systemName: "person.crop.circle.badge.clock")
            .font(.title2)
            .foregroundColor(.secondary)

          VStack(alignment: .leading, spacing: 2) {
            Text(name)
              .font(.subheadline)
              .fontWeight(.medium)

            Text("Waiting for setup")
              .font(.caption)
              .foregroundColor(.secondary)
          }

          Spacer()
        }
        .padding()
        .background(
          RoundedRectangle(cornerRadius: 12)
            .fill(Color(.tertiarySystemBackground))
        )
        .opacity(0.6)
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

  private var leaveFamilySection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Family Membership")
        .font(.headline)

      VStack(spacing: 16) {
        HStack(spacing: 12) {
          Image(systemName: "rectangle.portrait.and.arrow.right")
            .font(.title2)
            .foregroundColor(.red)

          VStack(alignment: .leading, spacing: 4) {
            Text("Leave Family")
              .font(.subheadline)
              .fontWeight(.medium)

            if isLeaveDisabled {
              Text("Remove all family members and pending invitations before leaving.")
                .font(.caption)
                .foregroundColor(.secondary)
            } else {
              Text("Leave this family group and switch to individual mode.")
                .font(.caption)
                .foregroundColor(.secondary)
            }
          }

          Spacer()
        }

        Button(role: .destructive) {
          if childNeedsPinCheck {
            showLeaveLockCodeEntry = true
          } else {
            showLeaveConfirmation = true
          }
        } label: {
          Text("Leave Family")
            .fontWeight(.semibold)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(.red)
        .disabled(isLeaveDisabled)
      }
      .padding()
      .background(
        RoundedRectangle(cornerRadius: 12)
          .fill(Color.red.opacity(0.05))
          .overlay(
            RoundedRectangle(cornerRadius: 12)
              .stroke(Color.red.opacity(0.15), lineWidth: 1)
          )
      )
    }
  }

  private var resetFamilySharingSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Troubleshooting")
        .font(.headline)

      Button {
        showResetFamilySheet = true
      } label: {
        HStack(spacing: 12) {
          Image(systemName: "arrow.triangle.2.circlepath")
            .font(.title2)
            .foregroundColor(.red)

          VStack(alignment: .leading, spacing: 2) {
            Text("Reset Family Sharing")
              .font(.subheadline)
              .fontWeight(.medium)

            Text("Clear shared data for troubleshooting")
              .font(.caption)
              .foregroundColor(.secondary)
          }

          Spacer()

          if isResettingFamily {
            ProgressView()
              .scaleEffect(0.8)
          }
        }
        .padding()
        .background(
          RoundedRectangle(cornerRadius: 12)
            .fill(Color(.secondarySystemBackground))
        )
      }
      .buttonStyle(.plain)
      .confirmationDialog("Reset Family Sharing", isPresented: $showResetFamilySheet) {
        Button("Reset Rules Only") {
          performFamilyReset(clearEverything: false)
        }
        Button("Reset Everything", role: .destructive) {
          showResetEverythingConfirmation = true
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text(
          "Choose what to reset. \"Reset Rules Only\" erases lock codes and pending instructions but keeps your family connected. \"Reset Everything\" deletes all shared family data."
        )
      }
      .alert("Are you sure?", isPresented: $showResetEverythingConfirmation) {
        Button("Cancel", role: .cancel) {}
        Button("Reset Everything", role: .destructive) {
          performFamilyReset(clearEverything: true)
        }
      } message: {
        Text(
          "This will delete all shared family data including member records. Other family members may need to leave and rejoin the family share."
        )
      }
    }
  }

  private func performFamilyReset(clearEverything: Bool) {
    isResettingFamily = true
    Task {
      do {
        try await cloudKitManager.resetFamilySharing(clearEverything: clearEverything)
      } catch {
        errorMessage = "Failed to reset family sharing: \(error.localizedDescription)"
        showError = true
      }
      isResettingFamily = false
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
        Log.error("Failed to sync share participants: \(redactedErrorForLog(error))", category: .cloudKit)
      }

      _ = try await cloudKitManager.fetchFamilyMembers()
      await lockCodeManager.fetchLockCodes()

      // Refresh heartbeats for device monitoring (#190)
      if !isChildMode {
        await HeartbeatManager.shared.refreshHeartbeats()
      }
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
  let onClear: () -> Void

  var body: some View {
    VStack(spacing: 12) {
      HStack(spacing: 12) {
        Image(systemName: "lock.shield.fill")
          .font(.title2)
          .foregroundColor(.green)

        VStack(alignment: .leading, spacing: 2) {
          Text("Lock Code Set")
            .font(.subheadline)
            .fontWeight(.medium)

          Text("Your lock code is active and shared with all parents")
            .font(.caption)
            .foregroundColor(.secondary)
        }

        Spacer()
      }

      HStack(spacing: 8) {
        Button {
          onClear()
        } label: {
          Text("Clear")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(.red)

        Button {
          onEdit()
        } label: {
          Text("Change")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }
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
  @State private var isResettingEmergency = false
  @State private var isResettingThrottle = false
  @State private var resetStatus: ParentResetCommandStatus = .idle
  @State private var showResetError = false
  @State private var resetErrorMessage = ""

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

        if let statusText = resetStatus.displayText {
          Text(statusText)
            .font(.caption2)
            .foregroundColor(resetStatus == .confirmed ? .green : .secondary)
        }
      }

      Spacer()

      Circle()
        .fill(member.isActive ? Color.green : Color.gray)
        .frame(width: 8, height: 8)

      Menu {
        if member.role == .child {
          Button {
            resetEmergencyCount()
          } label: {
            Label("Reset Emergency Count", systemImage: "arrow.counterclockwise")
          }
          .disabled(isResettingEmergency)

          Button {
            resetLockCodeThrottle()
          } label: {
            Label("Reset PIN Attempts", systemImage: "lock.rotation")
          }
          .disabled(isResettingThrottle)
        }

        Button(role: .destructive) {
          showRemoveConfirmation = true
        } label: {
          Label("Remove", systemImage: "trash")
        }
      } label: {
        if isResettingEmergency || isResettingThrottle {
          ProgressView()
            .scaleEffect(0.8)
        } else {
          switch resetStatus {
          case .awaitingChild:
            Image(systemName: "paperplane.circle")
              .foregroundColor(.secondary)
          case .confirmed:
            Image(systemName: "checkmark.circle.fill")
              .foregroundColor(.green)
          case .idle:
            Image(systemName: "ellipsis.circle")
              .foregroundColor(.secondary)
          }
        }
      }
      .accessibilityLabel(resetStatus.displayText ?? "More")
      .alert("Error", isPresented: $showResetError) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(resetErrorMessage)
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

  private func resetEmergencyCount() {
    guard member.role == .child else { return }

    guard let currentUserRecordName = CloudKitManager.shared.currentUserRecordID?.recordName else {
      resetErrorMessage = "Not signed in to iCloud"
      showResetError = true
      return
    }

    resetStatus = .idle
    isResettingEmergency = true

    Task {
      do {
        let command = FamilyCommand(
          commandType: .resetEmergencyCount,
          targetChildId: member.userRecordName,
          createdBy: currentUserRecordName
        )
        try await CloudKitManager.shared.sendCommand(command)

        await MainActor.run {
          isResettingEmergency = false
          resetStatus = .afterSuccessfulSave
        }
        await pollForConfirmation(command)
      } catch {
        await MainActor.run {
          isResettingEmergency = false
          resetErrorMessage = error.localizedDescription
          showResetError = true
        }
      }
    }
  }

  private func resetLockCodeThrottle() {
    guard member.role == .child else { return }

    guard let currentUserRecordName = CloudKitManager.shared.currentUserRecordID?.recordName else {
      resetErrorMessage = "Not signed in to iCloud"
      showResetError = true
      return
    }

    resetStatus = .idle
    isResettingThrottle = true

    Task {
      do {
        let command = FamilyCommand(
          commandType: .resetLockCodeThrottle,
          targetChildId: member.userRecordName,
          createdBy: currentUserRecordName
        )
        try await CloudKitManager.shared.sendCommand(command)

        await MainActor.run {
          isResettingThrottle = false
          resetStatus = .afterSuccessfulSave
        }
        await pollForConfirmation(command)
      } catch {
        await MainActor.run {
          isResettingThrottle = false
          resetErrorMessage = error.localizedDescription
          showResetError = true
        }
      }
    }
  }

  private func pollForConfirmation(_ command: FamilyCommand) async {
    for _ in 0..<5 {
      try? await Task.sleep(nanoseconds: 3_000_000_000)

      let stillPending: Bool
      do {
        stillPending = try await CloudKitManager.shared.commandIsPending(command)
      } catch {
        return
      }

      let next = ParentResetCommandStatus.afterConfirmationProbe(
        commandStillPending: stillPending)
      await MainActor.run { resetStatus = next }
      if next == .confirmed { return }
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

#Preview {
  ParentDashboardView()
}
