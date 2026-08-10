import FamilyControls
import SwiftData
import SwiftUI

let amznStoreLink = "https://amzn.to/4fbMuTM"

struct SettingsView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var context
  @EnvironmentObject var themeManager: ThemeManager
  @EnvironmentObject var requestAuthorizer: RequestAuthorizer
  @EnvironmentObject var strategyManager: StrategyManager

  @ObservedObject private var appModeManager = AppModeManager.shared
  @ObservedObject private var profileSyncManager = ProfileSyncManager.shared
  @ObservedObject private var lockCodeManager = LockCodeManager.shared

  @State private var showResetBlockingStateAlert = false
  @State private var showResetSyncAlert = false
  @State private var showWipeSyncConfirmation = false
  @State private var showParentDashboard = false
  @State private var showChildDashboard = false
  @State private var showSavedLocations = false
  @State private var showDebugView = false
  @State private var syncErrorMessage: String?

  @AppStorage("family_foqos_warn_when_activating_away_from_location") private var warnWhenActivatingAwayFromLocation =
    true

  nonisolated static let wipeConfirmationMessage =
    "This deletes every synced profile, location, emergency unblock record, and pending sync reset from every device on your iCloud account. Devices still on the old app version won't be affected and should be updated - they can't interoperate with the new sync."

  nonisolated static func wipeRequiresLockVerification(mode: AppMode, canVerifyCode: Bool) -> Bool {
    mode == .child && canVerifyCode
  }

  nonisolated static func wipeIsAllowed(mode: AppMode, canVerifyCode: Bool) -> Bool {
    mode == .child ? canVerifyCode : true
  }

  private var isWipeAllowed: Bool {
    Self.wipeIsAllowed(
      mode: appModeManager.currentMode,
      canVerifyCode: lockCodeManager.canVerifyCode)
  }

  private var appVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
      ?? "1.0"
  }

  private var syncStatusColor: Color {
    switch profileSyncManager.syncStatusSnapshot.status {
    case .disabled:
      return .gray
    case .synced:
      return .green
    case .syncing:
      return themeManager.themeColor
    case .waiting:
      return .orange
    case .offline:
      return .gray
    case .paused:
      return .orange
    }
  }

  private var syncStatusLabel: String {
    switch profileSyncManager.syncStatusSnapshot.status {
    case .disabled:
      return "Disabled"
    case .synced:
      return "Synced"
    case .waiting(let count):
      return "Waiting to sync (\(count) changes)"
    case .syncing:
      return "Syncing…"
    case .offline:
      return "Offline"
    case .paused(.signedOut):
      return "Signed out of iCloud"
    case .paused(.accountChanged):
      return "iCloud account changed"
    }
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Theme") {
          HStack {
            Image(systemName: "paintpalette.fill")
              .foregroundStyle(themeManager.themeColor)
              .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
              Text("Appearance")
                .font(.headline)
              Text("Customize the look of your app")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          .padding(.vertical, 8)

          Picker("Theme Color", selection: $themeManager.selectedColorName) {
            ForEach(ThemeManager.availableColors, id: \.name) { colorOption in
              HStack {
                Circle()
                  .fill(colorOption.color)
                  .frame(width: 20, height: 20)
                Text(colorOption.name)
              }
              .tag(colorOption.name)
            }
          }
          .onChange(of: themeManager.selectedColorName) { _, _ in
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
          }
        }

        Section {
          Button {
            showSavedLocations = true
          } label: {
            HStack {
              Image(systemName: "mappin.circle.fill")
                .foregroundColor(themeManager.themeColor)
                .font(.title3)

              VStack(alignment: .leading, spacing: 2) {
                Text("Saved Locations")
                  .font(.headline)
                  .foregroundColor(.primary)
                Text("Manage locations for geofence restrictions")
                  .font(.caption)
                  .foregroundColor(.secondary)
              }

              Spacer()

              Image(systemName: "chevron.right")
                .foregroundColor(.secondary)
                .font(.caption)
            }
          }
          Toggle(isOn: $warnWhenActivatingAwayFromLocation) {
            VStack(alignment: .leading, spacing: 2) {
              Text("Warn When Away from Unlock Location")
                .font(.headline)
              Text(
                "Show a warning when starting a profile with location restrictions while not at the required location"
              )
              .font(.caption)
              .foregroundColor(.secondary)
            }
          }
          .tint(themeManager.themeColor)
        } header: {
          Text("Location")
        } footer: {
          Text("Save locations to restrict when profiles can be stopped based on your physical location.")
        }

        // Device Sync Section
        Section {
          Toggle(isOn: $profileSyncManager.isEnabled) {
            HStack {
              Image(systemName: "arrow.triangle.2.circlepath.icloud.fill")
                .foregroundStyle(themeManager.themeColor)
                .font(.title3)

              VStack(alignment: .leading, spacing: 2) {
                Text("Enable Profile Sync")
                  .font(.headline)
                Text("Sync profiles across your devices")
                  .font(.caption)
                  .foregroundColor(.secondary)
              }
            }
          }
          .tint(themeManager.themeColor)

          if profileSyncManager.syncPausedReason == .accountChanged
            && profileSyncManager.pendingConflictName != nil
          {
            Button {
              profileSyncManager.reopenPendingAccountChangeConflict()
            } label: {
              HStack {
                Image(systemName: "exclamationmark.icloud.fill")
                  .foregroundColor(.orange)
                VStack(alignment: .leading, spacing: 2) {
                  Text("iCloud account changed")
                    .foregroundColor(.primary)
                  Text("Choose how to sync")
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                  .foregroundColor(.secondary)
                  .font(.caption)
              }
            }
          }

          if profileSyncManager.isEnabled {
            HStack {
              Text("Sync Status")
                .foregroundStyle(.primary)
              Spacer()
              HStack(spacing: 8) {
                if profileSyncManager.syncStatusSnapshot.isSyncing {
                  ProgressView()
                    .scaleEffect(0.8)
                } else {
                  Circle()
                    .fill(syncStatusColor)
                    .frame(width: 8, height: 8)
                }
                Text(syncStatusLabel)
                  .foregroundStyle(.secondary)
                  .font(.subheadline)
              }
            }

            if let lastSync = profileSyncManager.syncStatusSnapshot.lastSyncDate {
              HStack {
                Text("Last Synced")
                  .foregroundStyle(.primary)
                Spacer()
                Text(lastSync, style: .relative)
                  .foregroundStyle(.secondary)
                  .font(.subheadline)
              }
            }

            Button {
              do {
                try profileSyncManager.syncNow()
              } catch {
                syncErrorMessage = error.localizedDescription
              }
            } label: {
              HStack {
                Image(systemName: "arrow.clockwise")
                  .foregroundColor(themeManager.themeColor)
                Text("Sync Now")
                  .foregroundColor(.primary)
                Spacer()
                if profileSyncManager.syncStatusSnapshot.isSyncing {
                  ProgressView()
                    .scaleEffect(0.8)
                }
              }
            }
            .disabled(profileSyncManager.syncStatusSnapshot.isSyncing)
          }
        } header: {
          Text("Device Sync")
        } footer: {
          if profileSyncManager.isEnabled {
            Text("Profiles marked as synced will be available on all your devices. App selections must be configured separately on each device.")
          } else {
            Text("Enable to sync profiles across your iPhone and iPad via iCloud.")
          }
        }

        // Family Controls Section
        Section {
          // Current mode display
          HStack {
            Image(systemName: appModeManager.currentMode.iconName)
              .foregroundStyle(themeManager.themeColor)
              .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
              Text("Current Mode")
                .font(.headline)
              Text(appModeManager.currentMode.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
          }
          .padding(.vertical, 4)

          // Family Dashboard access (all modes)
          Button {
            showParentDashboard = true
          } label: {
            HStack {
              Image(systemName: "person.2.fill")
                .foregroundColor(themeManager.themeColor)
              Text("Family Controls Dashboard")
                .foregroundColor(.primary)
              Spacer()
              Image(systemName: "chevron.right")
                .foregroundColor(.secondary)
                .font(.caption)
            }
          }

          // Child Dashboard access (for child mode — shows locked/unlocked profiles on this device)
          if appModeManager.currentMode == .child {
            Button {
              showChildDashboard = true
            } label: {
              HStack {
                Image(systemName: "lock.shield.fill")
                  .foregroundColor(themeManager.themeColor)
                Text("Parental Controls")
                  .foregroundColor(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                  .foregroundColor(.secondary)
                  .font(.caption)
              }
            }
          }

        } header: {
          Text("Family Controls")
        } footer: {
          if appModeManager.currentMode == .individual {
            Text("Access Family Controls to manage screen time for your children, or switch to Parent Mode to make it your primary view.")
          } else if appModeManager.currentMode == .parent {
            Text("You can still use personal profiles in Parent Mode via the Family Controls Dashboard.")
          } else {
            Text("Your screen time is managed by your parent. Access the Family Controls Dashboard to view family settings.")
          }
        }

        Section("About") {
          HStack {
            Text("Version")
              .foregroundStyle(.primary)
            Spacer()
            Text("v\(appVersion)")
              .foregroundStyle(.secondary)
          }

          HStack {
            Text("Screen Time Access")
              .foregroundStyle(.primary)
            Spacer()
            let status = requestAuthorizer.authorizationStatus
            HStack(spacing: 8) {
              Circle()
                .fill(status == .approved ? .green : .red)
                .frame(width: 8, height: 8)
              Text(status == .approved ? "Authorized" : "Not Authorized")
                .foregroundStyle(.secondary)
                .font(.subheadline)
            }
          }

          HStack {
            Text("Made in")
              .foregroundStyle(.primary)
            Spacer()
            Text("Calgary AB 🇨🇦\nand London 🇬🇧")
              .foregroundStyle(.secondary)
              .multilineTextAlignment(.trailing)
          }
        }

        Section("Buy NFC Tags") {
          Link(destination: URL(string: amznStoreLink)!) {
            HStack {
              Text("Amazon (original author affiliate link)")
                .foregroundColor(.primary)
              Spacer()
              Image(systemName: "arrow.up.right.square")
                .foregroundColor(.secondary)
            }
          }
        }

        Section("Help from the original author") {
          Link(destination: URL(string: "https://www.foqos.app/blocking-native-apps.html")!) {
            HStack {
              Text("Blocking Native Apps")
                .foregroundColor(.primary)
              Spacer()
              Image(systemName: "arrow.up.right.square")
                .foregroundColor(.secondary)
            }
          }
        }

        Section("Diagnostics") {
          Button {
            showDebugView = true
          } label: {
            HStack {
              Image(systemName: "ladybug.fill")
                .foregroundColor(themeManager.themeColor)
                .font(.title3)

              VStack(alignment: .leading, spacing: 2) {
                Text("Debug Mode")
                  .font(.headline)
                  .foregroundColor(.primary)
                Text("View logs and export diagnostics")
                  .font(.caption)
                  .foregroundColor(.secondary)
              }

              Spacer()

              Image(systemName: "chevron.right")
                .foregroundColor(.secondary)
                .font(.caption)
            }
          }
        }

        if !strategyManager.isBlocking {
          Section("Troubleshooting") {
            Button {
              showResetBlockingStateAlert = true
            } label: {
              Text("Reset Blocking State")
                .foregroundColor(themeManager.themeColor)
            }

            if profileSyncManager.isEnabled {
              Button {
                showResetSyncAlert = true
              } label: {
                Text("Reset Syncing")
                  .foregroundColor(themeManager.themeColor)
              }

              Button(role: .destructive) {
                showWipeSyncConfirmation = true
              } label: {
                Text("Wipe Synced Data Everywhere")
              }
              .disabled(!isWipeAllowed)

              if appModeManager.currentMode == .child && !lockCodeManager.canVerifyCode {
                Text("Ask a parent - lock code not available.")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
          }
        }
      }
      .navigationTitle("Settings")
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button(action: { dismiss() }) {
            Image(systemName: "xmark")
          }
          .accessibilityLabel("Close")
        }
      }
      .alert("Reset Blocking State", isPresented: $showResetBlockingStateAlert) {
        Button("Cancel", role: .cancel) {}
        Button("Reset", role: .destructive) {
          strategyManager.resetBlockingState(context: context)
        }
      } message: {
        Text("This will clear all app restrictions and remove any ghost schedules. Only use this if you're locked out and no profile is active.")
      }
      .alert("Reset Syncing", isPresented: $showResetSyncAlert) {
        Button("Cancel", role: .cancel) {}
        Button("Keep App Selections") {
          do {
            try profileSyncManager.resetSync(clearRemoteAppSelections: false)
          } catch {
            syncErrorMessage = error.localizedDescription
          }
        }
        Button("Clear App Selections", role: .destructive) {
          do {
            try profileSyncManager.resetSync(clearRemoteAppSelections: true)
          } catch {
            syncErrorMessage = error.localizedDescription
          }
        }
      } message: {
        Text("This will re-sync from this device. Choose how other devices should respond:\n\n• Keep app selections: Other devices keep their blocked apps\n• Clear app selections: Other devices must re-select apps")
      }
      .alert(
        "Sync Error",
        isPresented: .init(
          get: { syncErrorMessage != nil },
          set: { if !$0 { syncErrorMessage = nil } }
        )
      ) {
        Button("OK", role: .cancel) {}
      } message: {
        if let message = syncErrorMessage {
          Text(message)
        }
      }
      .sheet(isPresented: $showSavedLocations) {
        SavedLocationsView()
      }
      .sheet(isPresented: $showParentDashboard) {
        ParentDashboardView()
      }
      .sheet(isPresented: $showChildDashboard) {
        ChildDashboardView()
      }
      .sheet(isPresented: $showDebugView) {
        DebugView()
      }
      .fullScreenCover(isPresented: $showWipeSyncConfirmation) {
        WipeSyncConfirmationView(
          requiresLockVerification: Self.wipeRequiresLockVerification(
            mode: appModeManager.currentMode,
            canVerifyCode: lockCodeManager.canVerifyCode
          ),
          onCancel: {
            showWipeSyncConfirmation = false
          },
          onConfirm: {
            showWipeSyncConfirmation = false
            performWipeSyncReset()
          }
        )
      }
      .onChange(of: appModeManager.currentMode) { oldMode, newMode in
        // Auto-dismiss settings when switching from child to individual mode
        if oldMode == .child && newMode == .individual {
          dismiss()
        }
      }
    }
  }

  private func performWipeSyncReset() {
    do {
      try profileSyncManager.resetSync(wipe: true, clearRemoteAppSelections: false)
    } catch {
      syncErrorMessage = error.localizedDescription
    }
  }
}

private struct WipeSyncConfirmationView: View {
  let requiresLockVerification: Bool
  let onCancel: () -> Void
  let onConfirm: () -> Void

  @State private var showLockCodeEntry = false

  var body: some View {
    NavigationStack {
      VStack(spacing: 24) {
        Spacer(minLength: 24)

        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 56))
          .foregroundStyle(.red)

        VStack(spacing: 12) {
          Text("Wipe Synced Data Everywhere")
            .font(.title2)
            .fontWeight(.bold)
            .multilineTextAlignment(.center)

          Text(SettingsView.wipeConfirmationMessage)
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24)

        Spacer()

        VStack(spacing: 12) {
          Button(role: .destructive) {
            if requiresLockVerification {
              showLockCodeEntry = true
            } else {
              onConfirm()
            }
          } label: {
            Text(requiresLockVerification ? "Verify and Wipe" : "Wipe Everything")
              .fontWeight(.semibold)
              .frame(maxWidth: .infinity)
              .frame(height: 50)
          }
          .buttonStyle(.borderedProminent)
          .tint(.red)

          Button("Cancel", role: .cancel) {
            onCancel()
          }
          .frame(maxWidth: .infinity)
          .frame(height: 44)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 32)
      }
      .navigationTitle("Confirm Wipe")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Cancel") {
            onCancel()
          }
        }
      }
      .sheet(isPresented: $showLockCodeEntry) {
        LockCodeEntrySheet(
          onSuccess: {
            showLockCodeEntry = false
            onConfirm()
          },
          onCancel: {
            showLockCodeEntry = false
          }
        )
      }
    }
  }
}

#Preview {
  SettingsView()
    .environmentObject(ThemeManager.shared)
    .environmentObject(RequestAuthorizer())
    .environmentObject(StrategyManager.shared)
}
