//
//  FoqosApp.swift
//  foqos
//
//  Created by Ali Waseem on 2024-10-06.
//

import AppIntents
import BackgroundTasks
import CloudKit
import FamilyControls
import SwiftData
import SwiftUI
import UserNotifications

/// True when running inside the XCTest host process (hosted unit tests fully launch this
/// app, including SwiftUI's `.onAppear`). Guards one-shot production side effects — like
/// the I10 `attachEngine` composition root — from racing ahead of a test's own explicit
/// call and permanently latching `ProfileSyncManager`'s idempotency guard.
private var isRunningUnitTests: Bool {
  NSClassFromString("XCTestCase") != nil
}

/// Redact query and fragment from URL for safe logging (may contain tokens)
private func redactedURLString(_ url: URL) -> String {
  var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
  if components?.query != nil {
    components?.query = "[REDACTED]"
  }
  if components?.fragment != nil {
    components?.fragment = "[REDACTED]"
  }
  return components?.string ?? url.host ?? "unknown"
}

private let container: ModelContainer = {
  do {
    return try AppModelStore.makeContainer()
  } catch {
    fatalError("Couldn't create ModelContainer: \(error)")
  }
}()

// MARK: - Pending Share Acceptance State

/// Holds state between role detection and user confirmation during share acceptance
@MainActor
class PendingShareAcceptance: ObservableObject {
  static let shared = PendingShareAcceptance()

  @Published var pendingMetadata: CKShare.Metadata?
  @Published var detectedRole: FamilyRole?
  @Published var showConfirmation = false

  func reset() {
    pendingMetadata = nil
    detectedRole = nil
    showConfirmation = false
  }
}

@main
struct FoqosApp: App {
  private let startupRecoverySnapshot = StartupRecoveryLocalState.capture()
  @StateObject private var startupRecoveryRuntime = StartupRecoveryRuntime.shared
  @StateObject private var startupRecoveryCoordinator: StartupRecoveryCoordinator
  @StateObject private var requestAuthorizer = RequestAuthorizer()
  @StateObject private var navigationManager = NavigationManager.shared
  @StateObject private var nfcWriter = NFCWriter()
  @StateObject private var ratingManager = RatingManager.shared

  // Singletons for shared functionality
  @StateObject private var strategyManager = StrategyManager.shared
  @StateObject private var geofenceEvaluator = GeofenceEvaluator.shared
  @StateObject private var emergencyManager = EmergencyUnblockManager.shared
  @StateObject private var liveActivityManager = LiveActivityManager.shared
  @StateObject private var themeManager = ThemeManager.shared

  // App mode management for Family Sharing
  @StateObject private var appModeManager = AppModeManager.shared
  @StateObject private var cloudKitManager = CloudKitManager.shared
  @StateObject private var pendingAcceptance = PendingShareAcceptance.shared

  // Device sync for same-user multi-device sync
  @StateObject private var profileSyncManager = ProfileSyncManager.shared
  @StateObject private var startupRecoveryReachability = NetworkReachabilityMonitor()

  /// Sync upgrade notice (shown when legacy session records are cleaned up)
  @State private var showSyncUpgradeAlert = false

  /// Coalesces cold-launch and warm-foreground schedule refreshes.
  @State private var scheduleRefreshState = AppScheduleRefreshState()

  /// CloudKit share acceptance
  @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

  @Environment(\.scenePhase) private var scenePhase

  init() {
    let cloudService = StartupRecoveryCloudService()
    let recoveryDefaults =
      isRunningUnitTests || ScreenshotDemoMode.isActive
      ? UserDefaults(suiteName: "StartupRecoveryBypass-\(UUID().uuidString)")!
      : UserDefaults.standard
    let recoveryCoordinator = StartupRecoveryCoordinator(
      store: StartupRecoveryStore(defaults: recoveryDefaults),
      captureLocalClassification: {
        StartupRecoveryLocalState.classify(StartupRecoveryLocalState.capture())
      },
      captureOrigin: captureStartupRecoveryOrigin,
      restoreOrigin: restoreStartupRecoveryOrigin,
      lookupMembership: { await cloudService.lookupMembership() },
      lookupSyncedProfileCount: { ownerUserRecordName in
        await cloudService.fetchSyncedProfileCount(
          expectedOwnerUserRecordName: ownerUserRecordName)
      },
      restoreFamilyRole: restoreRecoveredFamilyRole,
      refreshChildLockCodes: {
        _ = await LockCodeManager.shared.refreshSharedLockCodesForVerification()
      },
      setSyncEnabled: { ProfileSyncManager.shared.isEnabled = $0 },
      releaseStartup: { StartupRecoveryRuntime.shared.release() })
    _startupRecoveryCoordinator = StateObject(wrappedValue: recoveryCoordinator)
    StartupRecoveryRuntime.shared.register(coordinator: recoveryCoordinator)

    // Migrate UserDefaults keys BEFORE any @AppStorage reads.
    // Must run here (not in .onAppear) because SwiftUI reads @AppStorage
    // when building the view hierarchy, which happens before .onAppear fires.
    UserDefaultsMigration.migrateIfNeeded()
    UserDefaultsMigration.migrateAppGroupIfNeeded()

    SharedData.configure(
      suite: UserDefaults(suiteName: "group.com.cynexia.family-foqos")!
    )
    #if DEBUG
      if ScreenshotDemoMode.isActive {
        do {
          try ScreenshotDemoSeeder.seed(container: container)
        } catch {
          Log.error("Demo seed failed: \(error.localizedDescription)", category: .app)
        }
      }
    #endif
    Log.info("init() called", category: .app)
    TimersUtil.registerBackgroundTasks()
    UNUserNotificationCenter.current().delegate = NotificationDelegate.shared

    let asyncDependency: @Sendable () async -> (ModelContainer) = {
      @MainActor in
      return container
    }
    AppDependencyManager.shared.add(
      key: "ModelContainer",
      dependency: asyncDependency
    )
  }

  var body: some Scene {
    WindowGroup {
      // Route to appropriate view based on app mode
      rootView
        .onAppear {
          Log.debug("rootView onAppear", category: .app)
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
          Log.debug("scenePhase changed", category: .app)
          guard !startupRecoveryRuntime.isHeld else {
            return
          }
          let shouldRefreshSchedules = scheduleRefreshState.shouldRefresh(for: newPhase)
          guard newPhase == .active else { return }
          Task {
            await handleActiveScene(shouldRefreshSchedules: shouldRefreshSchedules)
          }
        }
        .onOpenURL { url in
          Log.info("onOpenURL triggered with: \(redactedURLString(url))", category: .app)
          handleURL(url)
        }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { userActivity in
          Log.debug("NSUserActivityTypeBrowsingWeb received", category: .app)
          guard let url = userActivity.webpageURL else {
            return
          }
          handleURL(url)
        }
        .alert(
          CloudKitManager.familyRevocationAlertTitle,
          isPresented: Binding(
            get: { cloudKitManager.familyRevocationMessage != nil },
            set: {
              if !$0 {
                cloudKitManager.dismissFamilyRevocationMessage()
              }
            }
          )
        ) {
          Button("OK") {
            cloudKitManager.dismissFamilyRevocationMessage()
          }
        } message: {
          Text(cloudKitManager.familyRevocationMessage ?? "")
        }
        .alert(
          StartupRecoveryCopy.roleRestoredTitle,
          isPresented: Binding(
            get: {
              if case .roleRestored = startupRecoveryCoordinator.state { return true }
              return false
            },
            set: { isPresented in
              if !isPresented {
                startupRecoveryCoordinator.dismissRoleRestoredNotice()
              }
            }
          )
        ) {
          Button("OK") {
            startupRecoveryCoordinator.dismissRoleRestoredNotice()
          }
        } message: {
          Text(StartupRecoveryCopy.roleRestoredMessage)
        }
        // Share acceptance result alert (success or error)
        .alert(
          cloudKitManager.shareAcceptanceIsError ? "Unable to Join Family" : shareAcceptanceTitle,
          isPresented: Binding(
            get: { cloudKitManager.shareAcceptedMessage != nil },
            set: {
              if !$0 {
                cloudKitManager.shareAcceptedMessage = nil
                cloudKitManager.shareAcceptanceIsError = false
              }
            }
          )
        ) {
          Button("OK") {
            cloudKitManager.shareAcceptedMessage = nil
            cloudKitManager.shareAcceptanceIsError = false
          }
        } message: {
          Text(cloudKitManager.shareAcceptedMessage ?? "")
        }
        // Role confirmation alert before accepting share
        .alert(
          confirmationAlertTitle,
          isPresented: $pendingAcceptance.showConfirmation
        ) {
          Button("Continue") {
            guard let metadata = pendingAcceptance.pendingMetadata,
              let role = pendingAcceptance.detectedRole
            else {
              return
            }
            pendingAcceptance.reset()
            completeShareAcceptance(metadata: metadata, role: role)
          }
          Button("Cancel", role: .cancel) {
            pendingAcceptance.reset()
          }
        } message: {
          Text(confirmationAlertMessage)
        }
        .onReceive(profileSyncManager.$shouldShowSyncUpgradeNotice) { shouldShow in
          if shouldShow {
            showSyncUpgradeAlert = true
            profileSyncManager.shouldShowSyncUpgradeNotice = false
          }
        }
        .alert(
          "Multi-Device Sync Upgraded",
          isPresented: $showSyncUpgradeAlert
        ) {
          Button("OK", role: .cancel) {}
        } message: {
          Text(
            "Session sync has been improved. Please update Family Foqos on all your devices to ensure sessions sync correctly."
          )
        }
        .confirmationDialog(
          "iCloud account changed",
          isPresented: Binding(
            get: { profileSyncManager.accountChangeConflict != nil },
            set: { isPresented in
              if !isPresented, profileSyncManager.accountChangeConflict != nil {
                profileSyncManager.resolveConflictNotNow()
              }
            }
          ),
          titleVisibility: .visible
        ) {
          Button("Use this account's data") {
            Task { await profileSyncManager.resolveConflictSwitchToCloud() }
          }
          Button("Combine my data") {
            Task { await profileSyncManager.resolveConflictCombine() }
          }
          Button("Not now", role: .cancel) {
            profileSyncManager.resolveConflictNotNow()
          }
        } message: {
          Text(
            "Sync was turned off because this device signed into a different iCloud account. Use this account's data replaces this device's profiles with the ones already in the new account. Combine my data adds this device's profiles to the new account and they will appear on all devices signed into that account."
          )
        }
        .environmentObject(requestAuthorizer)
        .environmentObject(strategyManager)
        .environmentObject(geofenceEvaluator)
        .environmentObject(emergencyManager)
        .environmentObject(navigationManager)
        .environmentObject(nfcWriter)
        .environmentObject(ratingManager)
        .environmentObject(liveActivityManager)
        .environmentObject(themeManager)
        .environmentObject(appModeManager)
        .environmentObject(cloudKitManager)
        .environmentObject(profileSyncManager)
        .task {
          let classification =
            isRunningUnitTests || ScreenshotDemoMode.isActive
            ? StartupRecoveryLocalClassification.localStatePresent
            : StartupRecoveryLocalState.classify(startupRecoverySnapshot)
          await startupRecoveryCoordinator.start(classification: classification)
          handleRecoveryState(startupRecoveryCoordinator.state)
        }
        .onChange(of: startupRecoveryCoordinator.state) { _, state in
          handleRecoveryState(state)
        }
        .onChange(of: startupRecoveryReachability.isOnline) { wasOnline, isOnline in
          guard !wasOnline, isOnline else { return }
          Task {
            await startupRecoveryCoordinator.recheckIfNeeded()
          }
        }
        .onAppear {
          handleRecoveryState(startupRecoveryCoordinator.state)
        }
    }
    .handlesExternalEvents(matching: ["*"])  // Handle all external events including CloudKit shares
    .modelContainer(container)
  }

  /// Root view that routes based on app mode
  @ViewBuilder
  private var rootView: some View {
    if !startupRecoveryRuntime.isHeld {
      // All modes use HomeView as the default landing page.
      HomeView()
    } else {
      StartupRecoveryView(coordinator: startupRecoveryCoordinator)
    }
  }

  private func handleRecoveryState(_ state: StartupRecoveryState) {
    if case .normal(let recheckArmed) = state, recheckArmed {
      startupRecoveryReachability.start()
    } else {
      startupRecoveryReachability.stop()
    }

    guard !startupRecoveryRuntime.isHeld else { return }

    let shouldPerformInitialRefresh = scheduleRefreshState.shouldPerformInitialRefresh()
    if shouldPerformInitialRefresh {
      ProfileMigrationUtil.migrateProfilesIfNeeded(context: container.mainContext)
    }
    // Construct + wire the sync engine only after recovery releases startup (I10).
    // Hosted unit tests own the one-shot idempotency guard themselves.
    if !isRunningUnitTests && !ScreenshotDemoMode.isActive {
      Task {
        await profileSyncManager.attachEngine(
          modelContext: container.mainContext,
          emergencyManager: emergencyManager)
      }
    }
    if shouldPerformInitialRefresh && !ScreenshotDemoMode.isActive {
      reconcileSchedulesForCurrentState()
    }
    if scenePhase == .active {
      Task { await handleActiveScene(shouldRefreshSchedules: false) }
    }
  }

  @MainActor
  private func handleActiveScene(shouldRefreshSchedules: Bool) async {
    guard !startupRecoveryRuntime.isHeld else { return }
    if case .normal(let recheckArmed) = startupRecoveryCoordinator.state, recheckArmed {
      await startupRecoveryCoordinator.recheckIfNeeded()
      guard !startupRecoveryRuntime.isHeld else { return }
    }

    if !ScreenshotDemoMode.isActive {
      await CloudKitManager.shared.checkAccountStatus()
      await CloudKitManager.shared.verifySelfFamilyMemberRecord()
      await verifyChildAuthorizationIfNeeded()
      if AppModeManager.shared.currentMode == .child {
        do {
          try await CloudKitManager.shared.ensureSharedDatabaseSubscription()
        } catch {
          Log.error(
            "Failed to establish shared database subscription: \(redactedErrorForLog(error))",
            category: .cloudKit)
        }
        await LockCodeManager.shared.refreshSharedLockCodesForVerification()
      }

      // #201: re-drive persisted session-stop retries so a remote device doesn't see a
      // stopped session as perpetually active.
      await StrategyManager.shared.drainSessionStopOutbox()
      // #200: pull/push on foreground instead of the deleted notification throttle.
      if profileSyncManager.isEnabled {
        do {
          try profileSyncManager.syncNow()
        } catch {
          Log.warning("syncNow skipped: \(error.localizedDescription)", category: .sync)
        }
      }
    }
    if shouldRefreshSchedules && !ScreenshotDemoMode.isActive {
      reconcileSchedulesForCurrentState()
    }
  }

  private func reconcileSchedulesForCurrentState() {
    PreActivationReminderScheduler.mergeExtensionScheduleSuppression(
      context: container.mainContext)
    PreActivationReminderScheduler.reconcileMissingSnapshots(
      context: container.mainContext)
    PreActivationReminderScheduler.reconcileScheduleRegistrations(
      context: container.mainContext)
    PreActivationReminderScheduler.catchUpMissedScheduleStarts(context: container.mainContext)
  }

  // MARK: - Share Acceptance Alerts

  /// Title for success alert based on the mode that was set
  private var shareAcceptanceTitle: String {
    appModeManager.currentMode == .parent ? "Linked as Parent" : "Linked to Family"
  }

  /// Title for confirmation alert based on detected role
  private var confirmationAlertTitle: String {
    let role = pendingAcceptance.detectedRole ?? .child
    return "Set up as \(role.displayName)?"
  }

  /// Message for confirmation alert based on detected role
  private var confirmationAlertMessage: String {
    let role = pendingAcceptance.detectedRole ?? .child
    switch role {
    case .child:
      return "This device will be set up as a child. A parent will be able to set lock codes to restrict editing and deleting focus profiles."
    case .parent:
      return "This device will be set up as a parent. You'll be able to set lock codes for child devices to restrict editing and deleting focus profiles."
    }
  }

  private func handleURL(_ url: URL) {
    Log.info("handleURL called with: \(redactedURLString(url))", category: .app)

    // CloudKit share URLs are handled automatically by the system
    // via userDidAcceptCloudKitShareWith - we don't need to do anything here
    // Just log for debugging and pass non-share URLs to navigation
    if let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
      components.host == "www.icloud.com" || url.absoluteString.contains("cloudkit")
    {
      Log.debug("Detected CloudKit URL - system should handle via AppDelegate", category: .cloudKit)
      return
    }

    // Handle as universal link for our app
    navigationManager.handleLink(url)
  }
}

@MainActor
private func captureStartupRecoveryOrigin() -> StartupRecoveryOriginState {
  let defaults = UserDefaults.standard
  return StartupRecoveryOriginState(
    modeRawValue: defaults.string(forKey: "family_foqos_app_mode"),
    hasSelectedMode: optionalBool(
      in: defaults,
      forKey: "family_foqos_has_selected_mode"),
    onboardingCompleted: optionalBool(
      in: defaults,
      forKey: "family_foqos_has_completed_onboarding"),
    showIntro: optionalBool(
      in: defaults,
      forKey: "family_foqos_show_intro_screen"),
    showModeSelection: optionalBool(
      in: defaults,
      forKey: "family_foqos_show_mode_selection"),
    deviceSyncEnabled: ProfileSyncManager.shared.isEnabled)
}

@MainActor
private func restoreStartupRecoveryOrigin(_ origin: StartupRecoveryOriginState) {
  let defaults = UserDefaults.standard
  let appModeManager = AppModeManager.shared

  if let rawValue = origin.modeRawValue, let mode = AppMode(rawValue: rawValue) {
    appModeManager.currentMode = mode
  } else {
    appModeManager.currentMode = .individual
    defaults.removeObject(forKey: "family_foqos_app_mode")
  }

  appModeManager.hasSelectedMode = origin.hasSelectedMode ?? false
  restoreOptionalBool(
    origin.hasSelectedMode,
    in: defaults,
    forKey: "family_foqos_has_selected_mode")
  restoreOptionalBool(
    origin.onboardingCompleted,
    in: defaults,
    forKey: "family_foqos_has_completed_onboarding")
  restoreOptionalBool(
    origin.showIntro,
    in: defaults,
    forKey: "family_foqos_show_intro_screen")
  restoreOptionalBool(
    origin.showModeSelection,
    in: defaults,
    forKey: "family_foqos_show_mode_selection")
  ProfileSyncManager.shared.isEnabled = origin.deviceSyncEnabled ?? false
}

private func optionalBool(in defaults: UserDefaults, forKey key: String) -> Bool? {
  guard defaults.object(forKey: key) != nil else { return nil }
  return defaults.bool(forKey: key)
}

private func restoreOptionalBool(
  _ value: Bool?,
  in defaults: UserDefaults,
  forKey key: String
) {
  guard let value else {
    defaults.removeObject(forKey: key)
    return
  }
  defaults.set(value, forKey: key)
}

@MainActor
private func restoreRecoveredFamilyRole(_ role: FamilyRole) {
  AppModeManager.shared.selectMode(role == .parent ? .parent : .child)
  UserDefaults.standard.set(true, forKey: "family_foqos_has_completed_onboarding")
  UserDefaults.standard.set(false, forKey: "family_foqos_show_intro_screen")
  UserDefaults.standard.set(false, forKey: "family_foqos_show_mode_selection")
}

// MARK: - App Delegate for CloudKit Share Handling

class AppDelegate: NSObject, UIApplicationDelegate {
  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    Log.info("didFinishLaunchingWithOptions", category: .app)

    // Register for remote notifications to receive CloudKit push notifications
    if !ScreenshotDemoMode.isActive {
      application.registerForRemoteNotifications()
    }

    return true
  }

  func application(
    _: UIApplication,
    configurationForConnecting connectingSceneSession: UISceneSession,
    options _: UIScene.ConnectionOptions
  ) -> UISceneConfiguration {
    Log.debug("configurationForConnecting", category: .app)
    let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
    config.delegateClass = SceneDelegate.self
    return config
  }

  // MARK: - Remote Notification Handling

  static func shouldRefreshChildSharedData(
    databaseScope: CKDatabase.Scope?,
    mode: AppMode
  ) -> Bool {
    mode == .child && databaseScope == .shared
  }

  @MainActor
  static func refreshChildSharedDataAfterMembershipVerification(
    refreshAccountStatus: () async -> Void,
    verifyMembership: () async -> Bool,
    refreshSharedData: () async -> ChildSharedDataRefreshResult
  ) async -> ChildSharedDataRefreshResult {
    await refreshAccountStatus()
    let didHandleConfirmedRevocation = await verifyMembership()
    guard !didHandleConfirmedRevocation else { return .newData }
    return await refreshSharedData()
  }

  func application(
    _: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken _: Data
  ) {
    Log.info("Registered for remote notifications", category: .app)
  }

  func application(
    _: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    Log.error("Failed to register for remote notifications: \(redactedErrorForLog(error))", category: .app)
  }

  func application(
    _: UIApplication,
    didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
  ) {
    Log.info("Received remote notification", category: .cloudKit)
    Task { @MainActor in
      await StartupRecoveryPushRouter.route(
        isHeld: StartupRecoveryRuntime.shared.isHeld,
        onHeld: { completionHandler(.noData) },
        onReleased: {
          // Check if this is a CloudKit notification only after recovery releases startup.
          guard let ckNotification = CKNotification(fromRemoteNotificationDictionary: userInfo)
          else {
            completionHandler(.noData)
            return
          }
          Log.info(
            "CloudKit notification received - type: \(ckNotification.notificationType.rawValue)",
            category: .cloudKit)

          let databaseScope = (ckNotification as? CKDatabaseNotification)?.databaseScope
          let shouldRefreshChildSharedData = Self.shouldRefreshChildSharedData(
            databaseScope: databaseScope,
            mode: AppModeManager.shared.currentMode)

          // Route the CloudKit push to the engine (schedules a fetch+send); the engine
          // also owns its own database subscription. Preserve heartbeat refresh (#190).
          let childRefreshResult: UIBackgroundFetchResult?
          if shouldRefreshChildSharedData {
            childRefreshResult =
              await Self.refreshChildSharedDataAfterMembershipVerification(
                refreshAccountStatus: {
                  await CloudKitManager.shared.checkAccountStatus()
                },
                verifyMembership: {
                  await CloudKitManager.shared.verifySelfFamilyMemberRecord()
                },
                refreshSharedData: {
                  await LockCodeManager.shared.refreshSharedLockCodesForVerification()
                }
              )
              .backgroundFetchResult
          } else {
            childRefreshResult = nil
          }
          if ProfileSyncManager.shared.isEnabled {
            do {
              try ProfileSyncManager.shared.syncNow()
            } catch {
              Log.warning("syncNow skipped: \(error.localizedDescription)", category: .sync)
            }
          }
          if AppModeManager.shared.currentMode == .parent {
            await HeartbeatManager.shared.refreshHeartbeats()
          }
          completionHandler(childRefreshResult ?? .newData)
        })
    }
  }
}

extension ChildSharedDataRefreshResult {
  var backgroundFetchResult: UIBackgroundFetchResult {
    switch self {
    case .newData:
      return .newData
    case .noData:
      return .noData
    case .failed:
      return .failed
    }
  }
}

// MARK: - Scene Delegate for CloudKit Share Handling

class SceneDelegate: NSObject, UIWindowSceneDelegate {
  /// Called when app launches fresh with the share
  func scene(_: UIScene, willConnectTo _: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
    Log.debug("willConnectTo", category: .app)

    // Check if launched with a CloudKit share
    if let metadata = connectionOptions.cloudKitShareMetadata {
      Log.info("Found CloudKit share in connectionOptions", category: .cloudKit)
      acceptCloudKitShare(metadata)
    }

    // Check user activities
    for activity in connectionOptions.userActivities {
      Log.debug("Found activity: \(activity.activityType)", category: .app)
      handleUserActivity(activity)
    }

    // Check URL contexts
    for urlContext in connectionOptions.urlContexts {
      Log.debug("Found URL: \(redactedURLString(urlContext.url))", category: .app)
    }
  }

  /// Called when app is already running and receives a user activity
  func scene(_: UIScene, continue userActivity: NSUserActivity) {
    Log.debug("continue userActivity - \(userActivity.activityType)", category: .app)
    handleUserActivity(userActivity)
  }

  /// Called when app is already running and receives URLs
  func scene(_: UIScene, openURLContexts urlContexts: Set<UIOpenURLContext>) {
    for context in urlContexts {
      Log.debug("openURLContexts - \(redactedURLString(context.url))", category: .app)
    }
  }

  /// The key method for CloudKit share acceptance
  func windowScene(
    _: UIWindowScene,
    userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata
  ) {
    Log.info("userDidAcceptCloudKitShareWith", category: .cloudKit)
    acceptCloudKitShare(cloudKitShareMetadata)
  }

  private func handleUserActivity(_ activity: NSUserActivity) {
    Log.debug("handleUserActivity - type: \(activity.activityType)", category: .app)

    // Try to extract CloudKit share metadata
    if let metadata = activity.userInfo?["CKShareMetadata"] as? CKShare.Metadata {
      Log.info("Found CKShareMetadata in userInfo", category: .cloudKit)
      acceptCloudKitShare(metadata)
      return
    }

    // Log all userInfo keys for debugging
    if let userInfo = activity.userInfo {
      Log.debug("userInfo keys: \(userInfo.keys)", category: .app)
    }
  }
}

// MARK: - Shared CloudKit Share Acceptance

/// Entry point for CloudKit share acceptance — detects role and shows confirmation
func acceptCloudKitShare(_ metadata: CKShare.Metadata) {
  Log.info("Processing share", category: .cloudKit)
  Log.info("Container ID = \(metadata.containerIdentifier)", category: .cloudKit)

  Task { @MainActor in
    // 1. Fresh connection check
    let isConnected = await CloudKitManager.shared.checkFamilyConnectionStatus()

    if isConnected {
      Log.info("Device already connected to a family", category: .cloudKit)
      CloudKitManager.shared.shareAcceptanceIsError = true
      CloudKitManager.shared.shareAcceptedMessage =
        "This device is already connected to a family. Leave the current family before joining a new one."
      return
    }

    // 2. Detect role via AuthorizationVerifier
    let verificationResult = await AuthorizationVerifier.shared.verifyChildAuthorization()

    guard let detectedRole = AuthorizationVerifier.detectedFamilyRole(for: verificationResult)
    else {
      Log.warning(
        "Unable to detect a family role from Screen Time authorization",
        category: .cloudKit)
      CloudKitManager.shared.shareAcceptanceIsError = true
      CloudKitManager.shared.shareAcceptedMessage =
        verificationResult.errorMessage
        ?? "Unable to verify device type. Please try again."
      return
    }

    Log.info("Detected role: \(detectedRole.rawValue)", category: .cloudKit)

    // 3. Store metadata and role, show confirmation
    PendingShareAcceptance.shared.pendingMetadata = metadata
    PendingShareAcceptance.shared.detectedRole = detectedRole
    PendingShareAcceptance.shared.showConfirmation = true
  }
}

@MainActor
func applyAcceptedFamilyMode(
  role: FamilyRole,
  selectMode: (AppMode) -> Void = { AppModeManager.shared.selectMode($0) },
  clearFamilyRevocationNotice: () -> Void = {
    CloudKitManager.shared.dismissFamilyRevocationMessage()
  }
) -> AppMode {
  let appMode: AppMode = role == .parent ? .parent : .child
  selectMode(appMode)
  clearFamilyRevocationNotice()
  return appMode
}

/// Called from confirmation alert "Continue" — accepts share and sets up role
func completeShareAcceptance(metadata: CKShare.Metadata, role: FamilyRole) {
  Task { @MainActor in
    StartupRecoveryRuntime.shared.beginShareAcceptance()

    // 1. Accept CloudKit share (no auth gate)
    do {
      try await CloudKitManager.shared.acceptShareDirect(metadata: metadata)
      Log.info("Share accepted for role: \(role.rawValue)", category: .cloudKit)
    } catch {
      Log.error("Share acceptance failed: \(redactedErrorForLog(error))", category: .cloudKit)
      CloudKitManager.shared.shareAcceptanceIsError = true
      CloudKitManager.shared.shareAcceptedMessage =
        "Failed to accept invitation: \(error.localizedDescription)"
      StartupRecoveryRuntime.shared.failShareAcceptance()
      return
    }

    // 2. Switch app mode immediately after successful share acceptance
    let appMode = applyAcceptedFamilyMode(role: role)
    StartupRecoveryRuntime.shared.completeShareAcceptanceAfterModeApplied()

    // 3. Best-effort: register self as family member
    do {
      _ = try await CloudKitManager.shared.ensureUserRecordID()
      await CloudKitManager.shared.registerSelfAsFamilyMember(role: role)
    } catch {
      Log.error("Self-registration failed (will retry on next activation): \(redactedErrorForLog(error))", category: .cloudKit)
    }

    // 4. Best-effort: fetch shared lock codes
    if appMode == .child {
      do {
        try await CloudKitManager.shared.ensureSharedDatabaseSubscription()
      } catch {
        Log.error(
          "Failed to establish shared database subscription after share acceptance: \(redactedErrorForLog(error))",
          category: .cloudKit)
      }
      await LockCodeManager.shared.refreshSharedLockCodesForVerification()
    }

    // 5. Show role-specific success message
    CloudKitManager.shared.shareAcceptanceIsError = false
    switch role {
    case .parent:
      CloudKitManager.shared.shareAcceptedMessage =
        "You are now linked as a parent. You can set lock codes for child devices to restrict editing and deleting focus profiles."
    case .child:
      CloudKitManager.shared.shareAcceptedMessage =
        "You are now linked to a parent's device. They can set a lock code to restrict editing and deleting your focus profiles."
    }
  }
}

// MARK: - Authorization Verification

/// Verify child authorization when app becomes active (if in child mode)
/// Family Controls failures are recoverable and preserve the current family mode.
@MainActor
func verifyChildAuthorizationIfNeeded() async {
  await verifyChildAuthorizationIfNeeded {
    await AuthorizationVerifier.shared.verifyChildAuthorization()
  }
}

@MainActor
func verifyChildAuthorizationIfNeeded(
  verify: () async -> AuthorizationVerifier.VerificationResult
) async {
  if let message = await AuthorizationVerifier.shared.verifyIfNeeded(verify: verify) {
    CloudKitManager.shared.shareAcceptanceIsError = true
    CloudKitManager.shared.shareAcceptedMessage = message
  }
}
