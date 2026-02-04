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
  @Query(sort: [
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

  // Activity sessions
  @Query(sort: \BlockedProfileSession.startTime, order: .reverse) private
    var sessions: [BlockedProfileSession]
  @Query(
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
  @State private var showModeSelection = false

  // Sync conflict manager
  @ObservedObject private var syncConflictManager = SyncConflictManager.shared

  // UI States
  @State private var opacityValue = 1.0

  // Start picker state
  @State private var showStartPicker = false
  @State private var startOptions: [StartAction] = []
  @State private var pendingStartProfile: BlockedProfiles?

  // Scanner sheet state for trigger-based starts
  @State private var showStartNFCScanner = false
  @State private var showStartQRScanner = false
  @State private var scannerProfile: BlockedProfiles?

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

          if syncConflictManager.showConflictBanner {
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
            oneMoreMinuteTimeRemaining: strategyManager.oneMoreMinuteTimeRemaining,
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
      if newValue {
        showIntroScreen = false
        // Show mode selection if user hasn't selected a mode yet
        if !appModeManager.hasSelectedMode {
          showModeSelection = true
        }
      } else {
        showIntroScreen = true
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
        requestAuthorizer.requestAuthorization()
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
        strategyManager.confirmGeofenceStart()
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
          if let profile = pendingStartProfile {
            executeStartAction(option, profile: profile)
          }
        }
      }
      Button("Cancel", role: .cancel) {
        pendingStartProfile = nil
      }
    }
    .sheet(isPresented: $showStartNFCScanner) {
      StartNFCScannerSheet(
        profileName: scannerProfile?.name ?? "Profile",
        onTagScanned: { _ in
          if let profile = scannerProfile {
            strategyManager.toggleBlocking(context: context, activeProfile: profile)
          }
          showStartNFCScanner = false
          scannerProfile = nil
        },
        onCancel: {
          showStartNFCScanner = false
          scannerProfile = nil
        }
      )
    }
    .sheet(isPresented: $showStartQRScanner) {
      StartQRScannerSheet(
        profileName: scannerProfile?.name ?? "Profile",
        onCodeScanned: { _ in
          if let profile = scannerProfile {
            strategyManager.toggleBlocking(context: context, activeProfile: profile)
          }
          showStartQRScanner = false
          scannerProfile = nil
        },
        onCancel: {
          showStartQRScanner = false
          scannerProfile = nil
        }
      )
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
    case .showPicker:
      return "Choose Method"
    }
  }

  private func toggleSessionFromDeeplink(_ profileId: String, link: URL) {
    strategyManager
      .toggleSessionFromDeeplink(profileId, url: link, context: context)
  }

  private func strategyButtonPress(_ profile: BlockedProfiles) {
    // For stops, use existing logic
    if strategyManager.isBlocking {
      strategyManager.toggleBlocking(context: context, activeProfile: profile)
      ratingManager.incrementLaunchCount()
      return
    }

    // For starts, use trigger-based logic
    handleStartTap(profile)
    ratingManager.incrementLaunchCount()
  }

  private func handleStartTap(_ profile: BlockedProfiles) {
    let action = StrategyManager.determineStartAction(for: profile.startTriggers)

    switch action {
    case .startImmediately:
      strategyManager.toggleBlocking(context: context, activeProfile: profile)

    case .scanNFC:
      scannerProfile = profile
      showStartNFCScanner = true

    case .scanQR:
      scannerProfile = profile
      showStartQRScanner = true

    case .waitForSchedule:
      strategyManager.errorMessage = "This profile starts on schedule"

    case .showPicker(let options):
      startOptions = options
      pendingStartProfile = profile
      showStartPicker = true
    }
  }

  private func executeStartAction(_ action: StartAction, profile: BlockedProfiles) {
    switch action {
    case .startImmediately:
      strategyManager.toggleBlocking(context: context, activeProfile: profile)

    case .scanNFC:
      scannerProfile = profile
      showStartNFCScanner = true

    case .scanQR:
      scannerProfile = profile
      showStartQRScanner = true

    case .waitForSchedule, .showPicker:
      break  // Should not be called with these
    }
  }

  private func loadApp() {
    strategyManager.loadActiveSession(context: context)
  }

  private func onAppearApp() {
    strategyManager.loadActiveSession(context: context)
    strategyManager.cleanUpGhostSchedules(context: context)
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
      UserDefaults(suiteName: "preview")!.set(
        false,
        forKey: "showIntroScreen"
      )
    }
}
