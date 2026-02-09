//
//  foqosApp.swift
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
    // Configure SwiftData to use local storage only (not CloudKit sync)
    // We handle CloudKit manually for FamilyPolicy via CloudKitManager
    let schema = Schema([BlockedProfileSession.self, BlockedProfiles.self, SavedLocation.self])
    let modelConfiguration = ModelConfiguration(
      schema: schema,
      isStoredInMemoryOnly: false,
      cloudKitDatabase: .none  // Disable automatic CloudKit sync for these models
    )
    return try ModelContainer(for: schema, configurations: [modelConfiguration])
  } catch {
    fatalError("Couldn't create ModelContainer: \(error)")
  }
}()

@main
struct foqosApp: App {
  @StateObject private var requestAuthorizer = RequestAuthorizer()
  @StateObject private var navigationManager = NavigationManager()
  @StateObject private var nfcWriter = NFCWriter()
  @StateObject private var ratingManager = RatingManager()

  // Singletons for shared functionality
  @StateObject private var strategyManager = StrategyManager.shared
  @StateObject private var liveActivityManager = LiveActivityManager.shared
  @StateObject private var themeManager = ThemeManager.shared

  // App mode management for Family Sharing
  @StateObject private var appModeManager = AppModeManager.shared
  @StateObject private var cloudKitManager = CloudKitManager.shared
  @StateObject private var pendingShareAcceptance = PendingShareAcceptance.shared

  // Device sync for same-user multi-device sync
  @StateObject private var profileSyncManager = ProfileSyncManager.shared
  @StateObject private var syncCoordinator = SyncCoordinator.shared

  // Sync upgrade notice (shown when legacy session records are cleaned up)
  @State private var showSyncUpgradeAlert = false

  // CloudKit share acceptance
  @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

  @Environment(\.scenePhase) private var scenePhase

  init() {
    Log.info("init() called", category: .app)
    TimersUtil.registerBackgroundTasks()

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
          Log.debug("scenePhase changed from \(oldPhase) to \(newPhase)", category: .app)
          if newPhase == .active {
            // Verify child authorization when app becomes active
            verifyChildAuthorizationIfNeeded()
            // Self-heal FamilyMember record if in a family mode
            Task {
              await CloudKitManager.shared.verifySelfFamilyMemberRecord()
            }
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
          cloudKitManager.shareAcceptanceIsError
            ? "Unable to Join Family"
            : (AppModeManager.shared.currentMode == .parent
              ? "Linked as Parent" : "Linked to Parent"),
          isPresented: Binding(
            get: {
              cloudKitManager.shareAcceptedMessage != nil
                && !cloudKitManager.childAuthorizationFailed
            },
            set: { if !$0 { cloudKitManager.shareAcceptedMessage = nil } }
          )
        ) {
          Button("OK") {
            cloudKitManager.shareAcceptedMessage = nil
            cloudKitManager.shareAcceptanceIsError = false
          }
        } message: {
          Text(cloudKitManager.shareAcceptedMessage ?? "")
        }
        .alert(
          "Confirm Role",
          isPresented: $pendingShareAcceptance.showConfirmation
        ) {
          Button("Continue") {
            if let metadata = pendingShareAcceptance.pendingMetadata,
              let role = pendingShareAcceptance.detectedRole
            {
              completeShareAcceptance(metadata: metadata, role: role)
            }
            pendingShareAcceptance.reset()
          }
          Button("Cancel", role: .cancel) {
            pendingShareAcceptance.reset()
          }
        } message: {
          if pendingShareAcceptance.detectedRole == .parent {
            Text(
              "This device will be set up as a parent. You'll be able to manage lock codes and focus profiles for this family."
            )
          } else {
            Text(
              "This device will be set up as a child. A parent will be able to manage focus profiles and set lock codes on this device."
            )
          }
        }
        .sheet(isPresented: $cloudKitManager.childAuthorizationFailed) {
          ChildAuthorizationRequiredView {
            cloudKitManager.clearChildAuthorizationFailure()
          }
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
        .environmentObject(requestAuthorizer)
        .environmentObject(strategyManager)
        .environmentObject(navigationManager)
        .environmentObject(nfcWriter)
        .environmentObject(ratingManager)
        .environmentObject(liveActivityManager)
        .environmentObject(themeManager)
        .environmentObject(appModeManager)
        .environmentObject(cloudKitManager)
        .environmentObject(profileSyncManager)
        .onAppear {
          // Set up sync coordinator with model context
          syncCoordinator.setModelContext(container.mainContext)
          // Set up remote session observers
          strategyManager.setupRemoteSessionObservers()
          // Initialize sync if enabled
          if profileSyncManager.isEnabled {
            Task {
              await profileSyncManager.setupSync()
            }
          }
        }
    }
    .handlesExternalEvents(matching: ["*"])  // Handle all external events including CloudKit shares
    .modelContainer(container)
  }

  /// Root view that routes based on app mode
  @ViewBuilder
  private var rootView: some View {
    // All modes use HomeView as the default landing page
    // Parent dashboard is accessible from settings (parent mode)
    // Child parental controls info is accessible from settings (child mode)
    HomeView()
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

// MARK: - App Delegate for CloudKit Share Handling

class AppDelegate: NSObject, UIApplicationDelegate {

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    Log.info("didFinishLaunchingWithOptions", category: .app)

    // Register for remote notifications to receive CloudKit push notifications
    application.registerForRemoteNotifications()

    return true
  }

  func application(
    _ application: UIApplication,
    configurationForConnecting connectingSceneSession: UISceneSession,
    options: UIScene.ConnectionOptions
  ) -> UISceneConfiguration {
    Log.debug("configurationForConnecting", category: .app)
    let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
    config.delegateClass = SceneDelegate.self
    return config
  }

  // MARK: - Remote Notification Handling

  func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    Log.info("Registered for remote notifications", category: .app)
  }

  func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    Log.error("Failed to register for remote notifications: \(error)", category: .app)
  }

  func application(
    _ application: UIApplication,
    didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
  ) {
    Log.info("Received remote notification", category: .cloudKit)

    // Check if this is a CloudKit notification
    if let ckNotification = CKNotification(fromRemoteNotificationDictionary: userInfo) {
      Log.info(
        "CloudKit notification received - type: \(ckNotification.notificationType.rawValue)",
        category: .cloudKit)

      // Handle the notification via ProfileSyncManager
      Task {
        await ProfileSyncManager.shared.handleRemoteNotification()
        completionHandler(.newData)
      }
    } else {
      completionHandler(.noData)
    }
  }

}

// MARK: - Scene Delegate for CloudKit Share Handling

class SceneDelegate: NSObject, UIWindowSceneDelegate {

  // Called when app launches fresh with the share
  func scene(
    _ scene: UIScene, willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
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

  // Called when app is already running and receives a user activity
  func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
    Log.debug("continue userActivity - \(userActivity.activityType)", category: .app)
    handleUserActivity(userActivity)
  }

  // Called when app is already running and receives URLs
  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    for context in URLContexts {
      Log.debug("openURLContexts - \(redactedURLString(context.url))", category: .app)
    }
  }

  // The key method for CloudKit share acceptance
  func windowScene(
    _ windowScene: UIWindowScene,
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

// MARK: - Pending Share State

/// Holds state for pending share acceptance (waiting for user confirmation)
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

// MARK: - Shared CloudKit Share Acceptance

func acceptCloudKitShare(_ metadata: CKShare.Metadata) {
  Log.info("Processing share", category: .cloudKit)
  Log.info("Container ID = \(metadata.containerIdentifier)", category: .cloudKit)

  Task {
    // Refresh family connection state before checking (cached flag may be stale)
    let isConnected = await CloudKitManager.shared.checkFamilyConnectionStatus()
    await MainActor.run {
      CloudKitManager.shared.isConnectedToFamily = isConnected
    }

    // Guard: if already connected to a family, warn the user
    if isConnected {
      Log.warning("Device already connected to a family, rejecting new share", category: .cloudKit)
      await MainActor.run {
        CloudKitManager.shared.shareAcceptanceIsError = true
        CloudKitManager.shared.shareAcceptedMessage =
          "This device is already connected to a family. Please leave the current family first before joining a new one."
      }
      return
    }

    // Step 1: Determine role by trying child authorization
    let verificationResult = await AuthorizationVerifier.shared.verifyChildAuthorization()

    let detectedRole: FamilyRole
    switch verificationResult {
    case .authorized:
      detectedRole = .child
    case .notChildDevice:
      detectedRole = .parent
    case .networkError(let error):
      Log.error("Network error during authorization check: \(error)", category: .authorization)
      await MainActor.run {
        CloudKitManager.shared.shareAcceptanceIsError = true
        CloudKitManager.shared.shareAcceptedMessage =
          "Unable to verify device. Please check your internet connection and try again."
      }
      return
    case .notAuthorized, .unknownError:
      Log.error(
        "Authorization check failed: \(verificationResult.errorMessage ?? "unknown")",
        category: .authorization
      )
      await MainActor.run {
        CloudKitManager.shared.shareAcceptanceIsError = true
        CloudKitManager.shared.shareAcceptedMessage =
          verificationResult.errorMessage ?? "Authorization failed. Please try again."
      }
      return
    }

    // Step 2: Show confirmation dialog
    await MainActor.run {
      let pending = PendingShareAcceptance.shared
      pending.pendingMetadata = metadata
      pending.detectedRole = detectedRole
      pending.showConfirmation = true
    }
  }
}

/// Complete share acceptance after user confirms their role.
/// Role has already been verified via FamilyControls in acceptCloudKitShare(),
/// so we use acceptShareAsParent() for both paths (it skips redundant auth checks).
/// The child path's auth was already validated during role detection.
func completeShareAcceptance(metadata: CKShare.Metadata, role: FamilyRole) {
  Task {
    do {
      // Both paths use the same CloudKit accept — role was already verified
      try await CloudKitManager.shared.acceptShareAsParent(metadata: metadata)
      Log.info("Successfully accepted CloudKit share as \(role.displayName)", category: .cloudKit)

      // Register self as FamilyMember with correct role
      await CloudKitManager.shared.registerSelfAsFamilyMember(role: role)

      // Switch to appropriate mode and show confirmation
      await MainActor.run {
        let appMode: AppMode = role == .parent ? .parent : .child
        if AppModeManager.shared.currentMode != appMode {
          AppModeManager.shared.selectMode(appMode)
        }

        CloudKitManager.shared.shareAcceptanceIsError = false
        if role == .parent {
          CloudKitManager.shared.shareAcceptedMessage =
            "You are now linked as a parent. You can manage lock codes and focus profiles for this family."
        } else {
          CloudKitManager.shared.shareAcceptedMessage =
            "You are now linked to a parent's device. They can set a lock code to manage your focus profiles."
        }
      }
    } catch {
      Log.error("Share acceptance failed: \(error)", category: .cloudKit)
      await MainActor.run {
        CloudKitManager.shared.shareAcceptanceIsError = true
        CloudKitManager.shared.shareAcceptedMessage =
          "Failed to accept invitation: \(error.localizedDescription)"
      }
    }
  }
}

// MARK: - Authorization Verification

/// Verify child authorization when app becomes active (if in child mode)
/// If authorization is lost, clear shared data and switch to individual mode
func verifyChildAuthorizationIfNeeded() {
  Task { @MainActor in
    if let message = await AuthorizationVerifier.shared.verifyIfNeeded() {
      CloudKitManager.shared.shareAcceptedMessage = message
    }
  }
}
