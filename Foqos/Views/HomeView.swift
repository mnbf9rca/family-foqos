import FamilyControls
@preconcurrency import SwiftData  // ReferenceWritableKeyPath in @Query lacks Sendable conformance
import SwiftUI

struct HomeView: View {
  nonisolated static let syncedDataResetNoticeMessage =
    "Synced data was reset from another device."
  nonisolated static let syncEnginePurgedNoticeMessage =
    "Device Sync was disabled because its iCloud data is no longer available."

  @Environment(\.modelContext) private var context
  @Environment(\.openURL) var openURL
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  @Environment(\.scenePhase) private var scenePhase

  @EnvironmentObject var requestAuthorizer: RequestAuthorizer
  @EnvironmentObject var strategyManager: StrategyManager
  @EnvironmentObject var geofenceEvaluator: GeofenceEvaluator
  @EnvironmentObject var navigationManager: NavigationManager
  @EnvironmentObject var ratingManager: RatingManager

  // Profile management
  @SafeQuery(sort: [
    SortDescriptor(\BlockedProfiles.order, order: .forward),
    SortDescriptor(\BlockedProfiles.createdAt, order: .reverse),
  ]) private
    var profiles: [BlockedProfiles]
  @State private var isProfileListPresent = false

  // New profile view
  @State private var showNewProfileView = false

  // Edit profile
  @State private var profileToEdit: BlockedProfiles? = nil

  // Stats sheet
  @State private var profileToShowStats: BlockedProfiles? = nil

  // Support View
  @State private var showSupportView = false

  // Settings View
  @State private var showSettingsView = false

  // Emergency View
  @State private var showEmergencyView = false

  // Navigate to profile
  @State private var navigateToProfileId: UUID? = nil

  // Debug mode
  @State private var showingDebugMode = false

  // Parent dashboard (accessible in parent mode)
  @State private var showParentDashboard = false
  #if DEBUG
    @State private var showChildDashboardForScreenshots = false
  #endif

  @SafeQuery(
    filter: #Predicate<BlockedProfileSession> { $0.endTime != nil },
    sort: \BlockedProfileSession.endTime,
    order: .reverse
  ) private var recentCompletedSessions: [BlockedProfileSession]

  // Alerts
  @State private var showingAlert = false
  @State private var alertTitle = ""
  @State private var alertMessage = ""

  // Intro sheet
  @AppStorage("family_foqos_show_intro_screen") private var showIntroScreen = true

  // Mode selection
  @ObservedObject private var appModeManager = AppModeManager.shared
  @AppStorage("family_foqos_show_mode_selection") private var showModeSelection = false

  // Onboarding completion — persists across launches, cleared on app delete
  @AppStorage("family_foqos_has_completed_onboarding") private var hasCompletedOnboarding = false

  // Sync conflict manager
  @ObservedObject private var syncConflictManager = SyncConflictManager.shared

  // UI States
  @State private var opacityValue = 1.0

  // Start picker state
  @State private var showStartPicker = false
  @State private var startOptions: [StartAction] = []
  @State private var pendingPickerProfile: BlockedProfiles?

  // Scanner state for trigger-based starts
  @State private var showStartQRScanner = false
  @State private var scannerProfile: BlockedProfiles?
  @State private var scannerProfileId: UUID?
  @State private var confirmationScanAttempt = 0
  @ObservedObject private var startupRecoveryRuntime = StartupRecoveryRuntime.shared
  @StateObject private var nfcScanner = NFCScannerUtil()

  // Stop picker state
  @State private var showStopQRScanner = false
  @State private var showStopPicker = false
  @State private var stopOptions: [StopAction] = []

  var isBlocking: Bool {
    return strategyManager.isBlocking
  }

  var activeSessionProfileId: UUID? {
    return strategyManager.activeSession?.blockedProfile.id
  }

  var isBreakAvailable: Bool {
    return strategyManager.isBreakAvailable
  }

  var isBreakActive: Bool {
    return strategyManager.isBreakActive
  }

  var isOneMoreMinuteActive: Bool {
    return strategyManager.isOneMoreMinuteActive
  }

  var isOneMoreMinuteAvailable: Bool {
    return strategyManager.isOneMoreMinuteAvailable
  }

  var body: some View {
    let headerLayout =
      dynamicTypeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading)) : AnyLayout(HStackLayout())
    ScrollView(showsIndicators: false) {
      VStack(alignment: .leading, spacing: 30) {
        headerLayout {
          AppTitle()
          if !dynamicTypeSize.isAccessibilitySize { Spacer() }
          HStack(spacing: 8) {
            // Show Family button in parent mode
            if appModeManager.currentMode == .parent {
              RoundedButton(
                "",
                action: {
                  showParentDashboard = true
                }, iconName: "person.2.fill"
              )
              .accessibilityLabel("Family Controls")
            }
            RoundedButton(
              "",
              action: {
                showSupportView = true
              }, iconName: "heart.fill"
            )
            .accessibilityLabel("Support")
            RoundedButton(
              "",
              action: {
                showSettingsView = true
              }, iconName: "gear"
            )
            .accessibilityLabel("Settings")
          }
          .padding(.leading, dynamicTypeSize.isAccessibilitySize ? 16 : 0)
        }
        .padding(.trailing, 16)
        .padding(.top, 16)

        AuthorizationCallout(
          authorizationStatus: requestAuthorizer.authorizationStatus,
          onAuthorizationHandler: {
            Task { await requestAuthorizer.requestAuthorization() }
          }
        )
        .padding(.horizontal, 16)

        if profiles.isEmpty {
          Welcome(onTap: {
            showNewProfileView = true
          })
          .padding(.horizontal, 16)
        }

        if !profiles.isEmpty {
          BlockedSessionsHabitTracker(
            sessions: recentCompletedSessions
          )
          .padding(.horizontal, 16)

          if syncConflictManager.shouldShowDivergenceBanner {
            SyncConflictBanner(
              message: syncConflictManager.divergenceMessage,
              onDismiss: { syncConflictManager.dismissDivergenceBanner() }
            )
            .padding(.vertical, 8)
          } else if syncConflictManager.shouldShowNewerVersionBanner {
            SyncConflictBanner(
              message: syncConflictManager.newerVersionMessage,
              onDismiss: { syncConflictManager.dismissBanner() }
            )
            .padding(.vertical, 8)
          } else if syncConflictManager.shouldShowOlderDeviceBanner {
            SyncConflictBanner(
              message: syncConflictManager.conflictMessage,
              onDismiss: { syncConflictManager.dismissBanner() }
            )
            .padding(.vertical, 8)
          }

          BlockedProfileCarousel(
            profiles: profiles,
            isBlocking: isBlocking,
            isBreakAvailable: isBreakAvailable,
            isBreakActive: isBreakActive,
            isBreakOpenRawFields: strategyManager.activeSession?.isBreakOpenRawFields == true,
            activeSessionProfileId: activeSessionProfileId,
            elapsedTime: strategyManager.elapsedTime,
            startingProfileId: navigateToProfileId,
            onStartingProfileConsumed: {
              navigateToProfileId = nil
            },
            onStartTapped: { profile in
              strategyButtonPress(profile)
            },
            onStopTapped: { profile in
              strategyButtonPress(profile)
            },
            onEditTapped: { profile in
              profileToEdit = profile
            },
            onStatsTapped: { profile in
              profileToShowStats = profile
            },
            onBreakTapped: { _ in
              strategyManager.toggleBreak(context: context)
            },
            onManageTapped: {
              isProfileListPresent = true
            },
            onEmergencyTapped: {
              showEmergencyView = true
            },
            onAppSelectionTapped: { profile in
              // Open profile editor to configure app selection
              profileToEdit = profile
            },
            isOneMoreMinuteActive: isOneMoreMinuteActive,
            isOneMoreMinuteAvailable: isOneMoreMinuteAvailable,
            oneMoreMinuteStartTime: strategyManager.activeSession?.oneMoreMinuteStartTime,
            onOneMoreMinuteTapped: { _ in
              strategyManager.startOneMoreMinute(context: context)
            }
          )
        }

        VersionFooter(
          profileIsActive: isBlocking,
          tapProfileDebugHandler: {
            showingDebugMode = true
          }
        )
        .frame(maxWidth: .infinity)
        .padding(.top, 15)
      }
    }
    .refreshable {
      loadApp()
    }
    .padding(.top, 1)
    .sheet(
      isPresented: $isProfileListPresent,
    ) {
      BlockedProfileListView()
    }
    .frame(
      minWidth: 0,
      maxWidth: .infinity,
      minHeight: 0,
      maxHeight: .infinity,
      alignment: .topLeading
    )
    .onChange(of: navigationManager.deliveries) { _, _ in
      receiveQueuedLinks()
    }
    .onChange(of: navigationManager.deliveryError) { _, message in
      if let message {
        strategyManager.errorMessage = message
        navigationManager.deliveryError = nil
      }
    }
    .onChange(of: navigationManager.navigateToProfileId, initial: true) { _, newValue in
      if let profileId = newValue {
        navigateToProfileId = UUID(uuidString: profileId)
        navigationManager.clearNavigation()
      }
    }
    .onChange(of: requestAuthorizer.isAuthorized) { _, newValue in
      Log.debug("isAuthorized changed", category: .authorization)
      if newValue {
        showIntroScreen = false
        hasCompletedOnboarding = true
      } else if !hasCompletedOnboarding {
        // Only reset to onboarding for users who haven't completed it yet.
        // Completed users who lose auth see AuthorizationCallout inline instead.
        showIntroScreen = true
        showModeSelection = false
      }
    }
    .onChange(of: profiles) { oldValue, newValue in
      if !newValue.isEmpty {
        loadApp()
      }
    }
    .onChange(of: scenePhase) { oldPhase, newPhase in
      if newPhase == .active {
        loadApp()
      } else if newPhase == .background {
        strategyManager.cancelTagOperation()
        unloadApp()
      }
    }
    .onReceive(strategyManager.$errorMessage) { errorMessage in
      if let message = errorMessage {
        showErrorAlert(message: message)
        strategyManager.errorMessage = nil
      }
    }
    .onReceive(geofenceEvaluator.$errorMessage) { errorMessage in
      if let message = errorMessage {
        showErrorAlert(message: message)
        geofenceEvaluator.errorMessage = nil
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .syncEstablishmentGenerationAdopted)) { _ in
      showNoticeAlert(title: "Sync Reset", message: Self.syncedDataResetNoticeMessage)
    }
    .onReceive(NotificationCenter.default.publisher(for: .syncEnginePurged)) { _ in
      showNoticeAlert(title: "Device Sync Disabled", message: Self.syncEnginePurgedNoticeMessage)
    }
    .onChange(of: startupRecoveryRuntime.isHeld) { _, held in
      if !held {
        loadApp()
        receiveQueuedLinks()
      }
    }
    .onAppear {
      onAppearApp()
    }
    .onDisappear { strategyManager.cancelTagOperation() }
    .fullScreenCover(isPresented: $showIntroScreen) {
      IntroView {
        showIntroScreen = false
        showModeSelection = true
      }.interactiveDismissDisabled()
    }
    .fullScreenCover(isPresented: $showModeSelection) {
      ModeSelectionView { selectedMode in
        showModeSelection = false
        // Note: The app will route to the appropriate view based on mode
        // If parent or child mode is selected, the root view in FoqosApp will handle routing
      }
      .interactiveDismissDisabled()
    }
    .sheet(item: $profileToEdit) { profile in
      BlockedProfileView(profile: profile)
    }
    .sheet(item: $profileToShowStats) { profile in
      ProfileInsightsView(profile: profile)
    }
    .sheet(
      isPresented: $showNewProfileView,
    ) {
      BlockedProfileView(profile: nil)
    }
    .sheet(isPresented: $strategyManager.showCustomStrategyView) {
      BlockingStrategyActionView(
        customView: strategyManager.customStrategyView
      )
      .presentationDetents([.medium, .large])
    }
    .sheet(isPresented: $showSupportView) {
      SupportView()
    }
    .sheet(isPresented: $showSettingsView) {
      SettingsView()
    }
    .sheet(isPresented: $showEmergencyView) {
      EmergencyView()
        .presentationDetents([.height(350), .large])
    }
    .sheet(isPresented: $showingDebugMode) {
      DebugView()
    }
    .sheet(isPresented: $showParentDashboard) {
      ParentDashboardView()
    }
    #if DEBUG
      .sheet(isPresented: $showChildDashboardForScreenshots) {
        ChildDashboardView()
      }
    #endif
    .alert(alertTitle, isPresented: $showingAlert) {
      Button("OK", role: .cancel) { dismissAlert() }
    } message: {
      Text(alertMessage)
    }
    .alert("Location Warning", isPresented: $geofenceEvaluator.showGeofenceStartWarning) {
      Button("Start Anyway") {
        geofenceEvaluator.confirmGeofenceStart(context: context)
      }
      Button("Cancel", role: .cancel) {
        geofenceEvaluator.cancelGeofenceStart()
      }
    } message: {
      Text(geofenceEvaluator.geofenceWarningMessage)
    }
    .confirmationDialog("Start by...", isPresented: $showStartPicker, titleVisibility: .visible) {
      ForEach(startOptions, id: \.self) { option in
        Button(displayName(for: option)) {
          if let profile = pendingPickerProfile {
            executeStartAction(option, profile: profile)
          }
          pendingPickerProfile = nil
        }
      }
      Button("Cancel", role: .cancel) {
        pendingPickerProfile = nil
      }
    }
    .confirmationDialog("Stop by...", isPresented: $showStopPicker, titleVisibility: .visible) {
      ForEach(stopOptions, id: \.self) { option in
        Button(displayName(for: option)) {
          if let profile = pendingPickerProfile {
            executeStopAction(option, profile: profile)
          }
          pendingPickerProfile = nil
        }
      }
      Button("Cancel", role: .cancel) {
        pendingPickerProfile = nil
      }
    }
    .sheet(
      isPresented: $strategyManager.showTagConfirmation,
      onDismiss: {
        if strategyManager.pendingTagSwitch != nil { strategyManager.cancelTagOperation() }
      }
    ) {
      if let pending = strategyManager.pendingTagSwitch {
        NavigationStack {
          VStack {
            if !tagConfirmationMessage.isEmpty { Text(tagConfirmationMessage).padding() }
            if let error = strategyManager.tagScanError { Text(error).foregroundStyle(.red).padding() }
            if pending.requiredType == .qr {
              LabeledCodeScannerView(heading: "Scan to Stop", subtitle: "") { result in
                switch result {
                case .success(let scan): if let event = scan.event { confirmTag(event) }
                case .failure(let error):
                  strategyManager.cancelTagOperation()
                  strategyManager.errorMessage = error.localizedDescription
                }
              }
              .id(confirmationScanAttempt)
            } else {
              Button("Scan NFC Tag") { scanConfirmationNFC() }
                .buttonStyle(.borderedProminent)
            }
          }
          .toolbar {
            ToolbarItem(placement: .cancellationAction) {
              Button("Cancel") { strategyManager.cancelTagOperation() }
            }
          }
        }
      }
    }
    .sheet(isPresented: $showStartQRScanner) {
      if let profile = scannerProfile {
        BlockingStrategyActionView(
          customView: LabeledCodeScannerView(
            heading: "Scan to Start",
            subtitle: "Scan a QR code to start \(profile.name)"
          ) { result in
            switch result {
            case .success(let hashedCode):
              showStartQRScanner = false
              if let id = scannerProfileId, let event = hashedCode.event {
                Task { await strategyManager.handleTagEvent(event, operation: .explicitStart(id), context: context) }
              }
              scannerProfile = nil
            case .failure(let error):
              strategyManager.errorMessage = error.localizedDescription
              showStartQRScanner = false
              scannerProfile = nil
            }
          }
        )
      }
    }
    .sheet(isPresented: $showStopQRScanner) {
      if let profile = scannerProfile {
        BlockingStrategyActionView(
          customView: LabeledCodeScannerView(
            heading: "Scan to Stop",
            subtitle: "Scan a QR code to stop \(profile.name)"
          ) { result in
            switch result {
            case .success(let hashedCode):
              showStopQRScanner = false
              if let event = hashedCode.event {
                Task { await strategyManager.handleTagEvent(event, operation: .scan, context: context) }
              }
              scannerProfile = nil
            case .failure(let error):
              strategyManager.errorMessage = error.localizedDescription
              showStopQRScanner = false
              scannerProfile = nil
            }
          }
        )
      }
    }
  }

  private func displayName(for action: StartAction) -> String {
    switch action {
    case .startImmediately:
      return "Start Now"
    case .scanNFC:
      return "Scan NFC Tag"
    case .scanQR:
      return "Scan QR Code"
    case .waitForSchedule:
      return "Wait for Schedule"
    case .deepLinkOnly:
      return "Deep Link Only"
    case .cannotStart:
      return "Cannot Start"
    case .showPicker:
      return "Choose Method"
    }
  }

  private func displayName(for action: StopAction) -> String {
    switch action {
    case .stopImmediately:
      return "Stop Now"
    case .scanNFC:
      return "Scan NFC Tag"
    case .scanQR:
      return "Scan QR Code"
    case .cannotStop:
      return "Cannot Stop"
    case .showPicker:
      return "Choose Method"
    }
  }

  private func receiveQueuedLinks() {
    Task { @MainActor in
      await navigationManager.dispatchQueued(
        using: strategyManager, context: context,
        ready: !startupRecoveryRuntime.isHeld)
      if let message = navigationManager.deliveryError {
        strategyManager.errorMessage = message
        navigationManager.deliveryError = nil
      }
    }
  }

  private func strategyButtonPress(_ profile: BlockedProfiles) {
    if strategyManager.isBlocking {
      handleStopTap(profile)
    } else {
      handleStartTap(profile)
    }
    ratingManager.incrementLaunchCount()
  }

  private func handleStartTap(_ profile: BlockedProfiles) {
    do { try strategyManager.prepareProfileForStart(profile, context: context) } catch {
      strategyManager.errorMessage = error.localizedDescription
      return
    }
    let action = StartStopActionResolver.determineStartAction(
      for: profile.startTriggers,
      stopConditions: profile.stopConditions
    )

    switch action {
    case .startImmediately:
      strategyManager.toggleBlocking(context: context, activeProfile: profile)

    case .scanNFC:
      scannerProfile = profile
      startNFCScan(for: profile)

    case .scanQR:
      scannerProfile = profile
      scannerProfileId = profile.id
      showStartQRScanner = true

    case .waitForSchedule:
      strategyManager.errorMessage = "This profile starts on schedule"

    case .deepLinkOnly:
      strategyManager.errorMessage =
        "This profile can only be started with a programmed NFC tag or custom QR code"

    case .cannotStart(let reason):
      strategyManager.errorMessage = reason

    case .showPicker(let options):
      startOptions = options
      pendingPickerProfile = profile
      showStartPicker = true
    }
  }

  private func handleStopTap(_ profile: BlockedProfiles) {
    // An active V1 profile deliberately has no V2 conditions until its session ends.
    if strategyManager.activeSession?.blockedProfile.profileSchemaVersion == 1 {
      strategyManager.toggleBlocking(context: context, activeProfile: profile)
      return
    }
    let action = StartStopActionResolver.determineStopAction(
      for: profile.stopConditions
    )

    switch action {
    case .stopImmediately:
      strategyManager.toggleBlocking(context: context, activeProfile: profile)

    case .scanNFC:
      scannerProfile = profile
      stopNFCScan(for: profile)

    case .scanQR:
      scannerProfile = profile
      showStopQRScanner = true

    case .cannotStop(let reason):
      strategyManager.errorMessage = reason

    case .showPicker(let options):
      stopOptions = options
      pendingPickerProfile = profile
      showStopPicker = true
    }
  }

  private func executeStartAction(_ action: StartAction, profile: BlockedProfiles) {
    switch action {
    case .startImmediately:
      strategyManager.toggleBlocking(context: context, activeProfile: profile)

    case .scanNFC:
      scannerProfile = profile
      startNFCScan(for: profile)

    case .scanQR:
      scannerProfile = profile
      scannerProfileId = profile.id
      showStartQRScanner = true

    case .waitForSchedule, .deepLinkOnly, .showPicker, .cannotStart:
      break  // Should not be called with these
    }
  }

  private func executeStopAction(_ action: StopAction, profile: BlockedProfiles) {
    switch action {
    case .stopImmediately:
      strategyManager.toggleBlocking(context: context, activeProfile: profile)

    case .scanNFC:
      scannerProfile = profile
      stopNFCScan(for: profile)

    case .scanQR:
      scannerProfile = profile
      showStopQRScanner = true

    case .showPicker, .cannotStop:
      break  // Should not be called with these
    }
  }

  private func startNFCScan(for profile: BlockedProfiles) {
    let id = profile.id
    nfcScanner.onTagScanned = { result in
      if let event = result.event {
        Task { await strategyManager.handleTagEvent(event, operation: .explicitStart(id), context: context) }
      }
      scannerProfile = nil
    }
    nfcScanner.onError = { error in
      strategyManager.errorMessage = error
      scannerProfile = nil
    }
    nfcScanner.scan(profileName: profile.name)
  }

  private func stopNFCScan(for profile: BlockedProfiles) {
    nfcScanner.onTagScanned = { result in
      if let event = result.event {
        Task { await strategyManager.handleTagEvent(event, operation: .scan, context: context) }
      }
      scannerProfile = nil
    }
    nfcScanner.onError = { error in
      strategyManager.errorMessage = error
      scannerProfile = nil
    }
    nfcScanner.scan(profileName: profile.name)
  }

  private var tagConfirmationMessage: String {
    guard let pending = strategyManager.pendingTagSwitch,
      let session = try? BlockedProfileSession.findSession(byID: pending.victimId, in: context)
    else { return "" }
    let item = pending.requiredType == .nfc ? "NFC tag" : "QR code"
    if let id = pending.targetProfileId, let target = try? BlockedProfiles.findProfile(byID: id, in: context) {
      return "Scan the required \(item) to stop \(session.blockedProfile.name), then \(target.name) can start."
    }
    return ""
  }

  private func confirmTag(_ event: TagEvent) {
    Task {
      await strategyManager.handleTagEvent(event, operation: .confirmSwitch, context: context)
      confirmationScanAttempt += 1
    }
  }

  private func scanConfirmationNFC() {
    nfcScanner.onTagScanned = { result in
      if let event = result.event { confirmTag(event) }
    }
    nfcScanner.onError = { message in
      strategyManager.cancelTagOperation()
      strategyManager.errorMessage = message
    }
    nfcScanner.onCancel = { strategyManager.cancelTagOperation() }
    nfcScanner.scan(profileName: "")
  }

  private func loadApp() {
    #if DEBUG
      if ScreenshotDemoMode.isActive {
        try? strategyManager.loadScreenshotDemoSession(context: context)
        return
      }
    #endif
    try? strategyManager.loadActiveSession(context: context)
  }

  private func onAppearApp() {
    loadApp()
    receiveQueuedLinks()
    #if DEBUG
      if ScreenshotDemoMode.scenario == .profileEditor {
        profileToEdit = profiles.valid.first { $0.name == "Deep Focus" }
      }
      if ScreenshotDemoMode.scenario == .locationRestrictions {
        profileToEdit = profiles.valid.first { $0.name == "No social at work" }
      }
      if ScreenshotDemoMode.scenario == .childLocked {
        showChildDashboardForScreenshots = true
      }
      if ScreenshotDemoMode.scenario == .parentDashboard {
        showParentDashboard = true
      }
    #endif
    if !ScreenshotDemoMode.isActive {
      strategyManager.cleanUpGhostSchedules(context: context)
    }

    // Migration: existing users upgrading from a version without hasCompletedOnboarding.
    // showIntroScreen defaults to true, so if it's false the user must have completed
    // onboarding in a prior version. Bootstrap the new flag for them.
    // Also check !showModeSelection to avoid triggering for new users mid-onboarding
    // (e.g., tapped "Get Started" but crashed before completing authorization).
    if !hasCompletedOnboarding && !showIntroScreen && !showModeSelection {
      Log.info(
        "Upgrade migration: setting hasCompletedOnboarding=true for existing user",
        category: .authorization)
      hasCompletedOnboarding = true
    }

    // Safety net: if onboarding was never completed and both screens are dismissed, reset
    Log.debug("onAppearApp safety net check", category: .authorization)
    if !hasCompletedOnboarding && !showIntroScreen && !showModeSelection {
      Log.warning(
        "Safety net triggered: onboarding incomplete but both screens dismissed, resetting",
        category: .authorization)
      showIntroScreen = true
    }
  }

  private func unloadApp() {
    strategyManager.stopTimer()
  }

  private func showErrorAlert(message: String) {
    alertTitle = "Whoops"
    alertMessage = message
    showingAlert = true
  }

  private func showNoticeAlert(title: String, message: String) {
    alertTitle = title
    alertMessage = message
    showingAlert = true
  }

  private func dismissAlert() {
    showingAlert = false
  }
}

#Preview {
  HomeView()
    .environmentObject(RequestAuthorizer())
    .environmentObject(GeofenceEvaluator.shared)
    .environmentObject(NavigationManager.shared)
    .environmentObject(StrategyManager.shared)
    .environmentObject(RatingManager.shared)
    .defaultAppStorage(UserDefaults(suiteName: "preview")!)
    .onAppear {
      let defaults = UserDefaults(suiteName: "preview")!
      defaults.set(false, forKey: "family_foqos_show_intro_screen")
      defaults.set(true, forKey: "family_foqos_has_completed_onboarding")
    }
}
