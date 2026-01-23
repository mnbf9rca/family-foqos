import FamilyControls
import Foundation
import SwiftData
import SwiftUI

// Alert identifier for managing multiple alerts
struct AlertIdentifier: Identifiable {
  enum AlertType {
    case error
    case deleteProfile
  }

  let id: AlertType
  var errorMessage: String?
}

struct BlockedProfileView: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(\.dismiss) private var dismiss

  @EnvironmentObject private var themeManager: ThemeManager
  @EnvironmentObject private var nfcWriter: NFCWriter
  @EnvironmentObject private var strategyManager: StrategyManager

  @ObservedObject private var appModeManager = AppModeManager.shared
  @ObservedObject private var lockCodeManager = LockCodeManager.shared

  // If profile is nil, we're creating a new profile
  var profile: BlockedProfiles?

  @State private var name: String = ""
  @State private var enableLiveActivity: Bool = false
  @State private var enableReminder: Bool = false
  @State private var enableBreaks: Bool = false
  @State private var breakTimeInMinutes: Int = 15
  @State private var enableStrictMode: Bool = false
  @State private var reminderTimeInMinutes: Int = 15
  @State private var customReminderMessage: String
  @State private var enableAllowMode: Bool = false
  @State private var enableAllowModeDomain: Bool = false
  @State private var enableSafariBlocking: Bool = true
  @State private var disableBackgroundStops: Bool = false
  @State private var domains: [String] = []

  @State private var physicalUnblockNFCTagId: String?
  @State private var physicalUnblockQRCodeId: String?

  @State private var schedule: BlockedProfileSchedule

  // QR code generator
  @State private var showingGeneratedQRCode = false

  // Sheet for activity picker
  @State private var showingActivityPicker = false

  // Sheet for domain picker
  @State private var showingDomainPicker = false

  // Sheet for schedule picker
  @State private var showingSchedulePicker = false

  // Alert management
  @State private var alertIdentifier: AlertIdentifier?

  // Sheet for physical unblock
  @State private var showingPhysicalUnblockView = false

  // Alert for cloning
  @State private var showingClonePrompt = false
  @State private var cloneName: String = ""

  // Sheet for insights modal
  @State private var showingInsights = false

  // Sheet for sessions modal
  @State private var showingSessions = false

  // Managed profile state
  @State private var isManaged: Bool = false
  @State private var showingLockCodeEntry = false
  @State private var pendingAction: PendingAction?

  // Pending actions that require code verification
  private enum PendingAction {
    case edit
    case delete
    case stopBlocking
  }

  @State private var selectedActivity = FamilyActivitySelection()
  @State private var selectedStrategy: BlockingStrategy? = nil

  private let physicalReader: PhysicalReader = PhysicalReader()

  private var isEditing: Bool {
    profile != nil
  }

  private var isBlocking: Bool {
    strategyManager.activeSession?.isActive ?? false
  }

  /// Whether this profile is managed and requires code for editing
  private var isManagedProfile: Bool {
    profile?.isManaged == true
  }

  /// Whether the profile is currently unlocked for editing
  private var isUnlockedForEditing: Bool {
    guard let profile = profile else { return true }
    return lockCodeManager.isUnlocked(profile.id)
  }

  /// Whether editing should be disabled
  private var editingDisabled: Bool {
    isBlocking || (isManagedProfile && !isUnlockedForEditing && appModeManager.currentMode != .parent)
  }

  /// Whether to show the managed toggle (only in parent mode when lock code exists)
  private var showManagedToggle: Bool {
    // Parent mode allows marking profiles as managed on the child's device
    // The lock code is set on parent device and synced via CloudKit
    appModeManager.currentMode == .parent && lockCodeManager.hasAnyLockCode
  }

  init(profile: BlockedProfiles? = nil) {
    self.profile = profile
    _name = State(initialValue: profile?.name ?? "")
    _selectedActivity = State(
      initialValue: profile?.selectedActivity ?? FamilyActivitySelection()
    )
    _enableLiveActivity = State(
      initialValue: profile?.enableLiveActivity ?? false
    )
    _enableBreaks = State(
      initialValue: profile?.enableBreaks ?? false
    )
    _breakTimeInMinutes = State(
      initialValue: profile?.breakTimeInMinutes ?? 15
    )
    _enableStrictMode = State(
      initialValue: profile?.enableStrictMode ?? false
    )
    _enableAllowMode = State(
      initialValue: profile?.enableAllowMode ?? false
    )
    _enableAllowModeDomain = State(
      initialValue: profile?.enableAllowModeDomains ?? false
    )
    _enableSafariBlocking = State(
      initialValue: profile?.enableSafariBlocking ?? true
    )
    _enableReminder = State(
      initialValue: profile?.reminderTimeInSeconds != nil
    )
    _disableBackgroundStops = State(
      initialValue: profile?.disableBackgroundStops ?? false
    )
    _reminderTimeInMinutes = State(
      initialValue: Int(profile?.reminderTimeInSeconds ?? 900) / 60
    )
    _customReminderMessage = State(
      initialValue: profile?.customReminderMessage ?? ""
    )
    _domains = State(
      initialValue: profile?.domains ?? []
    )
    _physicalUnblockNFCTagId = State(
      initialValue: profile?.physicalUnblockNFCTagId ?? nil
    )
    _physicalUnblockQRCodeId = State(
      initialValue: profile?.physicalUnblockQRCodeId ?? nil
    )
    _schedule = State(
      initialValue: profile?.schedule
        ?? BlockedProfileSchedule(
          days: [],
          startHour: 9,
          startMinute: 0,
          endHour: 17,
          endMinute: 0,
          updatedAt: Date()
        )
    )
    _isManaged = State(initialValue: profile?.isManaged ?? false)

    if let profileStrategyId = profile?.blockingStrategyId {
      _selectedStrategy = State(
        initialValue:
          StrategyManager
          .getStrategyFromId(id: profileStrategyId)
      )
    } else {
      _selectedStrategy = State(initialValue: NFCBlockingStrategy())
    }
  }

  var body: some View {
    NavigationStack {
      Form {
        // Show lock status when profile is active
        if isBlocking {
          Section {
            HStack {
              Image(systemName: "lock.fill")
                .font(.title2)
                .foregroundColor(.orange)
              Text("A session is currently active, profile editing is disabled.")
                .font(.subheadline)
                .foregroundColor(.red)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 4)
          }
        }

        // Show managed profile lock status
        if isManagedProfile && !isUnlockedForEditing && appModeManager.currentMode != .parent {
          Section {
            HStack {
              Image(systemName: "lock.shield.fill")
                .font(.title2)
                .foregroundColor(.blue)
              VStack(alignment: .leading, spacing: 4) {
                Text("Parent-Controlled Profile")
                  .font(.subheadline)
                  .fontWeight(.medium)
                Text("This profile is managed by a parent. Enter the lock code to edit.")
                  .font(.caption)
                  .foregroundColor(.secondary)
              }
              Spacer()
              Button("Unlock") {
                pendingAction = .edit
                showingLockCodeEntry = true
              }
              .buttonStyle(.borderedProminent)
              .controlSize(.small)
            }
            .padding(.vertical, 4)
          }
        }

        if profile?.scheduleIsOutOfSync == true {
          Section {
            ScheduleWarningPrompt(onApply: { saveProfile() }, disabled: isBlocking)
          }
        }

        Section("Name") {
          TextField("Profile Name", text: $name)
            .textContentType(.none)
        }

        Section((enableAllowMode ? "Allowed" : "Blocked") + " Apps") {
          BlockedProfileAppSelector(
            selection: selectedActivity,
            buttonAction: { showingActivityPicker = true },
            allowMode: enableAllowMode,
            disabled: isBlocking
          )

          CustomToggle(
            title: "Apps Allow Mode",
            description:
              "Pick apps to allow and block everything else. This will erase any other selection you've made.",
            isOn: $enableAllowMode,
            isDisabled: isBlocking
          )

          CustomToggle(
            title: "Block Safari",
            description:
              "Block Safari websites that are selected in the app selector above. When disabled, Safari will remain unrestricted regardless of the websites you pick.",
            isOn: $enableSafariBlocking,
            isDisabled: isBlocking
          )
        }

        Section((enableAllowModeDomain ? "Allowed" : "Blocked") + " Domains") {
          BlockedProfileDomainSelector(
            domains: domains,
            buttonAction: { showingDomainPicker = true },
            allowMode: enableAllowModeDomain,
            disabled: isBlocking
          )

          CustomToggle(
            title: "Domain Allow Mode",
            description:
              "Pick domains to allow and block everything else. This will erase any other selection you've made.",
            isOn: $enableAllowModeDomain,
            isDisabled: isBlocking
          )
        }

        BlockingStrategyList(
          strategies: StrategyManager.availableStrategies.filter { !$0.hidden },
          selectedStrategy: $selectedStrategy,
          disabled: isBlocking
        )

        Section("Schedule") {
          BlockedProfileScheduleSelector(
            schedule: schedule,
            buttonAction: { showingSchedulePicker = true },
            disabled: isBlocking
          )
        }

        Section("Breaks") {
          CustomToggle(
            title: "Allow Timed Breaks",
            description:
              "Take a single break during your session. The break will automatically end after the selected duration.",
            isOn: $enableBreaks,
            isDisabled: isBlocking
          )

          if enableBreaks {
            Picker("Break Duration", selection: $breakTimeInMinutes) {
              Text("5 minutes").tag(5)
              Text("10 minutes").tag(10)
              Text("15 minutes").tag(15)
              Text("30 minutes").tag(30)
            }
            .disabled(isBlocking)
          }
        }

        Section("Safeguards") {
          CustomToggle(
            title: "Strict",
            description:
              "Block deleting apps from your phone, stops you from deleting Family Foqos to access apps",
            isOn: $enableStrictMode,
            isDisabled: isBlocking
          )

          CustomToggle(
            title: "Disable Background Stops",
            description:
              "Disable the ability to stop a profile from the background, this includes shortcuts and scanning links from NFC tags or QR codes.",
            isOn: $disableBackgroundStops,
            isDisabled: isBlocking
          )
        }

        // Parent-controlled profile section (only visible for parents)
        if showManagedToggle {
          Section {
            CustomToggle(
              title: "Parent-Controlled",
              description:
                "When enabled, this profile will require a lock code to edit or delete. Use this when setting up a profile on your child's device.",
              isOn: $isManaged,
              isDisabled: isBlocking
            )
          } header: {
            Text("Parent Controls")
          } footer: {
            if isManaged {
              Text("This profile will require your lock code to modify. The child will not be able to see the code.")
            }
          }
        }

        Section("Strict Unlocks") {
          BlockedProfilePhysicalUnblockSelector(
            nfcTagId: physicalUnblockNFCTagId,
            qrCodeId: physicalUnblockQRCodeId,
            disabled: isBlocking,
            onSetNFC: {
              physicalReader.readNFCTag(
                onSuccess: { physicalUnblockNFCTagId = $0 },
              )
            },
            onSetQRCode: {
              showingPhysicalUnblockView = true
            },
            onUnsetNFC: { physicalUnblockNFCTagId = nil },
            onUnsetQRCode: { physicalUnblockQRCodeId = nil }
          )
        }

        Section("Notifications") {
          CustomToggle(
            title: "Live Activity",
            description:
              "Shows a live activity on your lock screen with some inspirational quote",
            isOn: $enableLiveActivity,
            isDisabled: isBlocking
          )

          CustomToggle(
            title: "Reminder",
            description:
              "Sends a reminder to start this profile when its ended",
            isOn: $enableReminder,
            isDisabled: isBlocking
          )
          if enableReminder {
            HStack {
              Text("Reminder time")
              Spacer()
              TextField(
                "",
                value: $reminderTimeInMinutes,
                format: .number
              )
              .keyboardType(.numberPad)
              .multilineTextAlignment(.trailing)
              .frame(width: 50)
              .disabled(isBlocking)
              .font(.subheadline)
              .foregroundColor(.secondary)

              Text("minutes")
                .font(.subheadline)
                .foregroundColor(.secondary)
            }.listRowSeparator(.visible)
            VStack(alignment: .leading) {
              Text("Reminder message")
              TextField(
                "Reminder message",
                text: $customReminderMessage,
                prompt: Text(strategyManager.defaultReminderMessage(forProfile: profile)),
                axis: .vertical
              )
              .foregroundColor(.secondary)
              .lineLimit(...3)
              .onChange(of: customReminderMessage) { _, newValue in
                if newValue.count > 178 {
                  customReminderMessage = String(newValue.prefix(178))
                }
              }
              .disabled(isBlocking)
            }
          }

          if !isBlocking {
            Button {
              if let url = URL(
                string: UIApplication.openSettingsURLString
              ) {
                UIApplication.shared.open(url)
              }
            } label: {
              Text("Go to settings to disable globally")
                .foregroundStyle(themeManager.themeColor)
                .font(.caption)
            }
          }
        }

      }
      .onChange(of: enableAllowMode) {
        _,
        newValue in
        selectedActivity = FamilyActivitySelection(
          includeEntireCategory: newValue
        )
      }
      .navigationTitle(isEditing ? "Profile Details" : "New Profile")
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button(action: { dismiss() }) {
            Image(systemName: "xmark")
          }
          .accessibilityLabel("Cancel")
        }

        if isEditing, let validProfile = profile {
          ToolbarItemGroup(placement: .topBarTrailing) {
            if !isBlocking {
              Menu {
                Button {
                  writeProfile()
                } label: {
                  Label("Write to NFC Tag", systemImage: "tag")
                }

                Button {
                  showingGeneratedQRCode = true
                } label: {
                  Label("Generate QR code", systemImage: "qrcode")
                }

                Button {
                  cloneName = validProfile.name + " Copy"
                  showingClonePrompt = true
                } label: {
                  Label("Duplicate Profile", systemImage: "square.on.square")
                }

                Button {
                  showingSessions = true
                } label: {
                  Label("View Sessions", systemImage: "clock.arrow.circlepath")
                }

                Divider()

                Button(role: .destructive) {
                  // If managed profile on child device, require code
                  if isManagedProfile && appModeManager.currentMode != .parent && !isUnlockedForEditing {
                    pendingAction = .delete
                    showingLockCodeEntry = true
                  } else {
                    alertIdentifier = AlertIdentifier(id: .deleteProfile)
                  }
                } label: {
                  Label("Delete Profile", systemImage: "trash")
                }
              } label: {
                Image(systemName: "ellipsis.circle")
              }
              .accessibilityLabel("Profile Actions")
            }

            Button(action: { showingInsights = true }) {
              Image(systemName: "eyeglasses")
            }
            .accessibilityLabel("View Insights")
          }
        }

        if #available(iOS 26.0, *) {
          ToolbarSpacer(.flexible, placement: .topBarTrailing)
        }

        if !editingDisabled {
          ToolbarItem(placement: .topBarTrailing) {
            Button(action: { saveProfile() }) {
              Image(systemName: "checkmark")
            }
            .disabled(name.isEmpty)
            .accessibilityLabel(isEditing ? "Update" : "Create")
          }
        }
      }
      .sheet(isPresented: $showingActivityPicker) {
        AppPicker(
          selection: $selectedActivity,
          isPresented: $showingActivityPicker,
          allowMode: enableAllowMode
        )
      }
      .sheet(isPresented: $showingDomainPicker) {
        DomainPicker(
          domains: $domains,
          isPresented: $showingDomainPicker,
          allowMode: enableAllowModeDomain
        )
      }
      .sheet(isPresented: $showingSchedulePicker) {
        SchedulePicker(
          schedule: $schedule,
          isPresented: $showingSchedulePicker
        )
      }
      .sheet(isPresented: $showingGeneratedQRCode) {
        if let profileToWrite = profile {
          let url = BlockedProfiles.getProfileDeepLink(profileToWrite)
          QRCodeView(
            url: url,
            profileName: profileToWrite
              .name
          )
        }
      }
      .sheet(isPresented: $showingInsights) {
        if let validProfile = profile {
          ProfileInsightsView(profile: validProfile)
        }
      }
      .sheet(isPresented: $showingSessions) {
        if let validProfile = profile {
          BlockedProfileSessionsView(profile: validProfile)
        }
      }
      .sheet(isPresented: $showingLockCodeEntry) {
        LockCodeEntryView(
          title: "Enter Lock Code",
          subtitle: "Enter the parent lock code to modify this managed profile",
          onVerify: { code in
            guard let profile = profile else { return false }
            return lockCodeManager.verifyCodeForProfile(code, profile: profile)
          },
          onSuccess: {
            handleLockCodeSuccess()
          }
        )
      }
      .background(
        TextFieldAlert(
          isPresented: $showingClonePrompt,
          title: "Duplicate Profile",
          message: nil,
          text: $cloneName,
          placeholder: "Profile Name",
          confirmTitle: "Create",
          cancelTitle: "Cancel",
          onConfirm: { enteredName in
            let trimmed = enteredName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            do {
              if let source = profile {
                let clonedProfile = try BlockedProfiles.cloneProfile(
                  source, in: modelContext, newName: trimmed)
                DeviceActivityCenterUtil.scheduleTimerActivity(for: clonedProfile)
              }
            } catch {
              showError(message: error.localizedDescription)
            }
          }
        )
      )
      .sheet(isPresented: $showingPhysicalUnblockView) {
        BlockingStrategyActionView(
          customView: physicalReader.readQRCode(
            onSuccess: {
              showingPhysicalUnblockView = false
              physicalUnblockQRCodeId = $0
            },
            onFailure: { _ in
              showingPhysicalUnblockView = false
              showError(
                message: "Failed to read QR code, please try again or use a different QR code."
              )
            }
          )
        )
      }
      .alert(item: $alertIdentifier) { alert in
        switch alert.id {
        case .error:
          return Alert(
            title: Text("Error"),
            message: Text(alert.errorMessage ?? "An unknown error occurred"),
            dismissButton: .default(Text("OK"))
          )
        case .deleteProfile:
          return Alert(
            title: Text("Delete Profile"),
            message: Text(
              "Are you sure you want to delete this profile? This action cannot be undone."),
            primaryButton: .cancel(),
            secondaryButton: .destructive(Text("Delete")) {
              dismiss()
              if let profileToDelete = profile {
                do {
                  try BlockedProfiles.deleteProfile(profileToDelete, in: modelContext)
                } catch {
                  showError(message: error.localizedDescription)
                }
              }
            }
          )
        }
      }
      .onDisappear {
        // Revoke temporary unlock when leaving the profile view
        if let profile = profile, lockCodeManager.isUnlocked(profile.id) {
          lockCodeManager.revokeUnlock()
        }
      }
    }
  }

  private func showError(message: String) {
    alertIdentifier = AlertIdentifier(id: .error, errorMessage: message)
  }

  private func handleLockCodeSuccess() {
    guard let profile = profile else { return }

    // Grant temporary unlock for this profile
    lockCodeManager.grantTemporaryUnlock(for: profile.id)

    // Execute the pending action
    switch pendingAction {
    case .edit:
      // Profile is now unlocked, user can edit
      break
    case .delete:
      // Show delete confirmation
      alertIdentifier = AlertIdentifier(id: .deleteProfile)
    case .stopBlocking:
      // This would be handled by StrategyManager
      break
    case .none:
      break
    }

    pendingAction = nil
  }

  private func writeProfile() {
    if let profileToWrite = profile {
      let url = BlockedProfiles.getProfileDeepLink(profileToWrite)
      nfcWriter.writeURL(url)
    }
  }

  private func saveProfile() {
    do {
      // Update schedule date
      schedule.updatedAt = Date()

      // Calculate reminder time in seconds or nil if disabled
      let reminderTimeSeconds: UInt32? =
        enableReminder ? UInt32(reminderTimeInMinutes * 60) : nil

      // Only set managedByChildId on child devices - this identifies which child owns this profile
      let managedChildId: String? = (isManaged && appModeManager.currentMode == .child)
        ? CloudKitManager.shared.currentUserRecordID?.recordName
        : nil

      if let existingProfile = profile {
        // Update existing profile
        let updatedProfile = try BlockedProfiles.updateProfile(
          existingProfile,
          in: modelContext,
          name: name,
          selection: selectedActivity,
          blockingStrategyId: selectedStrategy?.getIdentifier(),
          enableLiveActivity: enableLiveActivity,
          reminderTime: reminderTimeSeconds,
          customReminderMessage: customReminderMessage,
          enableBreaks: enableBreaks,
          breakTimeInMinutes: breakTimeInMinutes,
          enableStrictMode: enableStrictMode,
          enableAllowMode: enableAllowMode,
          enableAllowModeDomains: enableAllowModeDomain,
          enableSafariBlocking: enableSafariBlocking,
          domains: domains,
          physicalUnblockNFCTagId: physicalUnblockNFCTagId,
          physicalUnblockQRCodeId: physicalUnblockQRCodeId,
          schedule: schedule,
          disableBackgroundStops: disableBackgroundStops,
          isManaged: isManaged,
          managedByChildId: managedChildId
        )

        // Schedule restrictions
        DeviceActivityCenterUtil.scheduleTimerActivity(for: updatedProfile)
      } else {
        let newProfile = try BlockedProfiles.createProfile(
          in: modelContext,
          name: name,
          selection: selectedActivity,
          blockingStrategyId: selectedStrategy?
            .getIdentifier() ?? NFCBlockingStrategy.id,
          enableLiveActivity: enableLiveActivity,
          reminderTimeInSeconds: reminderTimeSeconds,
          customReminderMessage: customReminderMessage,
          enableBreaks: enableBreaks,
          breakTimeInMinutes: breakTimeInMinutes,
          enableStrictMode: enableStrictMode,
          enableAllowMode: enableAllowMode,
          enableAllowModeDomains: enableAllowModeDomain,
          enableSafariBlocking: enableSafariBlocking,
          domains: domains,
          physicalUnblockNFCTagId: physicalUnblockNFCTagId,
          physicalUnblockQRCodeId: physicalUnblockQRCodeId,
          schedule: schedule,
          disableBackgroundStops: disableBackgroundStops,
          isManaged: isManaged,
          managedByChildId: managedChildId
        )

        // Schedule restrictions
        DeviceActivityCenterUtil.scheduleTimerActivity(for: newProfile)
      }

      dismiss()
    } catch {
      alertIdentifier = AlertIdentifier(id: .error, errorMessage: error.localizedDescription)
    }
  }
}

// Preview provider for SwiftUI previews
#Preview {
  BlockedProfileView()
    .environmentObject(NFCWriter())
    .environmentObject(StrategyManager())
    .modelContainer(for: BlockedProfiles.self, inMemory: true)
}

#Preview {
  let previewProfile = BlockedProfiles(
    name: "test",
    selectedActivity: FamilyActivitySelection(),
    reminderTimeInSeconds: 60
  )

  BlockedProfileView(profile: previewProfile)
    .environmentObject(NFCWriter())
    .environmentObject(StrategyManager())
    .modelContainer(for: BlockedProfiles.self, inMemory: true)
}
