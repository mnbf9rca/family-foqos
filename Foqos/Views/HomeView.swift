import FamilyControls
@preconcurrency import SwiftData  // ReferenceWritableKeyPath in @Query lacks Sendable conformance
import SwiftUI

struct HomeView: View {
  @Environment(\.modelContext) private var context
  @Environment(\.openURL) var openURL

  @Environment(\.scenePhase) private var scenePhase

  @EnvironmentObject var requestAuthorizer: RequestAuthorizer
  @EnvironmentObject var strategyManager: StrategyManager
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
  @AppStorage("showIntroScreen") private var showIntroScreen = true

  // Mode selection
  @ObservedObject private var appModeManager = AppModeManager.shared
  @AppStorage("showModeSelection") private var showModeSelection = false

  // Onboarding completion — persists across launches, cleared on app delete
  @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

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
    ScrollView(showsIndicators: false) {
      VStack(alignment: .leading, spacing: 30) {
        HStack(alignment: .center) {
          AppTitle()
          Spacer()
          HStack(spacing: 8) {
            // Show Family button in parent mode
            if appModeManager.currentMode == .parent {
              RoundedButton(
                "",
                action: {
                  showParentDashboard = true
                }, iconName: "person.2.fill")
            }
            RoundedButton(
              "",
              action: {
                showSupportView = true
              }, iconName: "heart.fill")
            RoundedButton(
              "",
              action: {
                showSettingsView = true
              }, iconName: "gear")
          }
        }
        .padding(.trailing, 16)
        .padding(.top, 16)

        AuthorizationCallout(
          authorizationStatus: requestAuthorizer.getAuthorizationStatus(),
          onAuthorizationHandler: {
            requestAuthorizer.requestAuthorization()
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

          if syncConflictManager.shouldShowNewerVersionBanner {
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
            activeSessionProfileId: activeSessionProfileId,
            elapsedTime: strategyManager.elapsedTime,
            startingProfileId: navigateToProfileId,
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
    .onChange(of: navigationManager.profileId) { _, newValue in
      if let profileId = newValue, let url = navigationManager.link {
        toggleSessionFromDeeplink(profileId, link: url)
        navigationManager.clearNavigation()
      }
    }
    .onChange(of: navigationManager.navigateToProfileId) { _, newValue in
      if let profileId = newValue {
        navigateToProfileId = UUID(uuidString: profileId)
        navigationManager.clearNavigation()
      }
    }
    .onChange(of: requestAuthorizer.isAuthorized) { _, newValue in
      Log.debug("isAuthorized changed to \(newValue)", category: .authorization)
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
        unloadApp()
      }
    }
    .onReceive(strategyManager.$errorMessage) { errorMessage in
      if let message = errorMessage {
        showErrorAlert(message: message)
      }
    }
    .onAppear {
      onAppearApp()
    }
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
        // If parent or child mode is selected, the root view in foqosApp will handle routing
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
      .presentationDetents([.medium])
    }
    .sheet(isPresented: $showSupportView) {
      SupportView()
    }
    .sheet(isPresented: $showSettingsView) {
      SettingsView()
    }
    .sheet(isPresented: $showEmergencyView) {
      EmergencyView()
        .presentationDetents([.height(350)])
    }
    .sheet(isPresented: $showingDebugMode) {
      DebugView()
    }
    .sheet(isPresented: $showParentDashboard) {
      ParentDashboardView()
    }
    .alert(alertTitle, isPresented: $showingAlert) {
      Button("OK", role: .cancel) { dismissAlert() }
    } message: {
      Text(alertMessage)
    }
    .alert("Location Warning", isPresented: $strategyManager.showGeofenceStartWarning) {
      Button("Start Anyway") {
        strategyManager.confirmGeofenceStart(context: context)
      }
      Button("Cancel", role: .cancel) {
        strategyManager.cancelGeofenceStart()
      }
    } message: {
      Text(strategyManager.geofenceWarningMessage)
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
    .sheet(isPresented: $showStartQRScanner) {
      if let profile = scannerProfile {
        BlockingStrategyActionView(
          customView: LabeledCodeScannerView(
            heading: "Scan to Start",
            subtitle: "Scan a QR code to start \(profile.name)"
          ) { result in
            switch result {
            case .success(let scanResult):
              showStartQRScanner = false
              strategyManager.startWithQRCode(
                context: context, profile: profile, codeValue: scanResult.string)
              scannerProfile = nil
            case .failure:
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
            case .success(let scanResult):
              showStopQRScanner = false
              strategyManager.stopWithQRCode(
                context: context, codeValue: scanResult.string)
              scannerProfile = nil
            case .failure:
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

  private func toggleSessionFromDeeplink(_ profileId: String, link: URL) {
    Task { @MainActor in
      await strategyManager
        .toggleSessionFromDeeplink(profileId, url: link, context: context)
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
    let action = StrategyManager.determineStartAction(
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
    let action = StrategyManager.determineStopAction(
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
    nfcScanner.onTagScanned = { tag in
      let tagId = tag.id
      strategyManager.startWithNFCTag(context: context, profile: profile, tagId: tagId)
      scannerProfile = nil
    }
    nfcScanner.onError = { error in
      strategyManager.errorMessage = error
      scannerProfile = nil
    }
    nfcScanner.scan(profileName: profile.name)
  }

  private func stopNFCScan(for profile: BlockedProfiles) {
    nfcScanner.onTagScanned = { tag in
      let tagId = tag.id
      strategyManager.stopWithNFCTag(context: context, tagId: tagId)
      scannerProfile = nil
    }
    nfcScanner.onError = { error in
      strategyManager.errorMessage = error
      scannerProfile = nil
    }
    nfcScanner.scan(profileName: profile.name)
  }

  private func loadApp() {
    try? strategyManager.loadActiveSession(context: context)
  }

  private func onAppearApp() {
    try? strategyManager.loadActiveSession(context: context)
    strategyManager.cleanUpGhostSchedules(context: context)

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
    Log.debug(
      "onAppearApp safety net check: hasCompletedOnboarding=\(hasCompletedOnboarding), showIntroScreen=\(showIntroScreen), showModeSelection=\(showModeSelection)",
      category: .authorization)
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

  private func dismissAlert() {
    showingAlert = false
  }
}

#Preview {
  HomeView()
    .environmentObject(RequestAuthorizer())
    .environmentObject(NavigationManager())
    .environmentObject(StrategyManager())
    .defaultAppStorage(UserDefaults(suiteName: "preview")!)
    .onAppear {
      let defaults = UserDefaults(suiteName: "preview")!
      defaults.set(false, forKey: "showIntroScreen")
      defaults.set(true, forKey: "hasCompletedOnboarding")
    }
}
