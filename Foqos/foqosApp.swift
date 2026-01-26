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
  @StateObject private var startegyManager = StrategyManager.shared
  @StateObject private var liveActivityManager = LiveActivityManager.shared
  @StateObject private var themeManager = ThemeManager.shared

  // App mode management for Family Sharing
  @StateObject private var appModeManager = AppModeManager.shared
  @StateObject private var cloudKitManager = CloudKitManager.shared

  // Device sync for same-user multi-device sync
  @StateObject private var profileSyncManager = ProfileSyncManager.shared
  @StateObject private var syncCoordinator = SyncCoordinator.shared

  // CloudKit share acceptance
  @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

  @Environment(\.scenePhase) private var scenePhase

  init() {
    print("foqosApp: init() called")
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
          print("foqosApp: rootView onAppear")
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
          print("foqosApp: scenePhase changed from \(oldPhase) to \(newPhase)")
          if newPhase == .active {
            // Verify child authorization when app becomes active
            verifyChildAuthorizationIfNeeded()
          }
        }
        .onOpenURL { url in
          print("foqosApp: onOpenURL triggered with: \(url.absoluteString)")
          handleURL(url)
        }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { userActivity in
          print("foqosApp: NSUserActivityTypeBrowsingWeb received")
          guard let url = userActivity.webpageURL else {
            return
          }
          handleURL(url)
        }
        .alert(
          "Linked to Parent",
          isPresented: Binding(
            get: { cloudKitManager.shareAcceptedMessage != nil && !cloudKitManager.childAuthorizationFailed },
            set: { if !$0 { cloudKitManager.shareAcceptedMessage = nil } }
          )
        ) {
          Button("OK") {
            cloudKitManager.shareAcceptedMessage = nil
          }
        } message: {
          Text(cloudKitManager.shareAcceptedMessage ?? "")
        }
        .sheet(isPresented: $cloudKitManager.childAuthorizationFailed) {
          ChildAuthorizationRequiredView {
            cloudKitManager.clearChildAuthorizationFailure()
          }
        }
        .environmentObject(requestAuthorizer)
        .environmentObject(startegyManager)
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
          startegyManager.setupRemoteSessionObservers()
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
    print("foqosApp: handleURL called with: \(url.absoluteString)")

    // CloudKit share URLs are handled automatically by the system
    // via userDidAcceptCloudKitShareWith - we don't need to do anything here
    // Just log for debugging and pass non-share URLs to navigation
    if let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
      components.host == "www.icloud.com" || url.absoluteString.contains("cloudkit")
    {
      print("foqosApp: Detected CloudKit URL - system should handle via AppDelegate")
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
    print("AppDelegate: didFinishLaunchingWithOptions")

    // Register for remote notifications to receive CloudKit push notifications
    application.registerForRemoteNotifications()

    return true
  }

  func application(
    _ application: UIApplication,
    configurationForConnecting connectingSceneSession: UISceneSession,
    options: UIScene.ConnectionOptions
  ) -> UISceneConfiguration {
    print("AppDelegate: configurationForConnecting")
    let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
    config.delegateClass = SceneDelegate.self
    return config
  }

  // MARK: - Remote Notification Handling

  func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    print("AppDelegate: Registered for remote notifications")
  }

  func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    print("AppDelegate: Failed to register for remote notifications - \(error)")
  }

  func application(
    _ application: UIApplication,
    didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
  ) {
    print("AppDelegate: Received remote notification")

    // Check if this is a CloudKit notification
    if let ckNotification = CKNotification(fromRemoteNotificationDictionary: userInfo) {
      print("AppDelegate: CloudKit notification received - type: \(ckNotification.notificationType.rawValue)")

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
  func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
    print("SceneDelegate: willConnectTo")

    // Check if launched with a CloudKit share
    if let metadata = connectionOptions.cloudKitShareMetadata {
      print("SceneDelegate: Found CloudKit share in connectionOptions!")
      acceptCloudKitShare(metadata)
    }

    // Check user activities
    for activity in connectionOptions.userActivities {
      print("SceneDelegate: Found activity: \(activity.activityType)")
      handleUserActivity(activity)
    }

    // Check URL contexts
    for urlContext in connectionOptions.urlContexts {
      print("SceneDelegate: Found URL: \(urlContext.url)")
    }
  }

  // Called when app is already running and receives a user activity
  func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
    print("SceneDelegate: continue userActivity - \(userActivity.activityType)")
    handleUserActivity(userActivity)
  }

  // Called when app is already running and receives URLs
  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    for context in URLContexts {
      print("SceneDelegate: openURLContexts - \(context.url)")
    }
  }

  // The key method for CloudKit share acceptance
  func windowScene(
    _ windowScene: UIWindowScene,
    userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata
  ) {
    print("SceneDelegate: userDidAcceptCloudKitShareWith!")
    acceptCloudKitShare(cloudKitShareMetadata)
  }

  private func handleUserActivity(_ activity: NSUserActivity) {
    print("SceneDelegate: handleUserActivity - type: \(activity.activityType)")

    // Try to extract CloudKit share metadata
    if let metadata = activity.userInfo?["CKShareMetadata"] as? CKShare.Metadata {
      print("SceneDelegate: Found CKShareMetadata in userInfo")
      acceptCloudKitShare(metadata)
      return
    }

    // Log all userInfo keys for debugging
    if let userInfo = activity.userInfo {
      print("SceneDelegate: userInfo keys: \(userInfo.keys)")
    }
  }
}

// MARK: - Shared CloudKit Share Acceptance

func acceptCloudKitShare(_ metadata: CKShare.Metadata) {
  print("acceptCloudKitShare: Processing share")
  print("acceptCloudKitShare: Container ID = \(metadata.containerIdentifier)")

  Task {
    do {
      try await CloudKitManager.shared.acceptShare(metadata: metadata)
      print("acceptCloudKitShare: Successfully accepted CloudKit share")

      // Fetch shared lock codes immediately
      _ = try? await CloudKitManager.shared.fetchSharedLockCodes()

      // Switch to child mode and show confirmation
      await MainActor.run {
        if AppModeManager.shared.currentMode != .child {
          AppModeManager.shared.selectMode(.child)
        }
        CloudKitManager.shared.shareAcceptedMessage =
          "You are now linked to a parent's device. They can set a lock code to manage your focus profiles."
      }
    } catch CloudKitError.childAuthorizationRequired {
      // Show the authorization required view instead of a generic error
      print("acceptCloudKitShare: Child authorization required")
      await MainActor.run {
        CloudKitManager.shared.setChildAuthorizationFailure(
          message: CloudKitError.childAuthorizationRequired.errorDescription ?? "Child authorization required"
        )
      }
    } catch {
      print("acceptCloudKitShare: Failed - \(error)")
      await MainActor.run {
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
