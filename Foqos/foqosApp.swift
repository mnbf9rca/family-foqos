//
//  foqosApp.swift
//  foqos
//
//  Created by Ali Waseem on 2024-10-06.
//

import AppIntents
import BackgroundTasks
import CloudKit
import SwiftData
import SwiftUI

private let container: ModelContainer = {
  do {
    // Configure SwiftData to use local storage only (not CloudKit sync)
    // We handle CloudKit manually for FamilyPolicy via CloudKitManager
    let schema = Schema([BlockedProfileSession.self, BlockedProfiles.self])
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
  @StateObject private var donationManager = TipManager()
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
            get: { cloudKitManager.shareAcceptedMessage != nil },
            set: { if !$0 { cloudKitManager.shareAcceptedMessage = nil } }
          )
        ) {
          Button("OK") {
            cloudKitManager.shareAcceptedMessage = nil
          }
        } message: {
          Text(cloudKitManager.shareAcceptedMessage ?? "")
        }
        .environmentObject(requestAuthorizer)
        .environmentObject(donationManager)
        .environmentObject(startegyManager)
        .environmentObject(navigationManager)
        .environmentObject(nfcWriter)
        .environmentObject(ratingManager)
        .environmentObject(liveActivityManager)
        .environmentObject(themeManager)
        .environmentObject(appModeManager)
        .environmentObject(cloudKitManager)
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

  private func handleShareAcceptance(_ metadata: CKShare.Metadata) {
    print("foqosApp: handleShareAcceptance called")
    Task {
      do {
        try await CloudKitManager.shared.acceptShare(metadata: metadata)
        print("foqosApp: Successfully accepted CloudKit share")

        // Fetch shared lock codes immediately
        _ = try? await CloudKitManager.shared.fetchSharedLockCodes()

        // Switch to child mode
        await MainActor.run {
          if AppModeManager.shared.currentMode != .child {
            AppModeManager.shared.selectMode(.child)
          }
        }
      } catch {
        print("foqosApp: Failed to accept share: \(error)")
      }
    }
  }
}


// MARK: - App Delegate for CloudKit Share Handling

class AppDelegate: NSObject, UIApplicationDelegate {

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    print("AppDelegate: didFinishLaunchingWithOptions")
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

  /// Handle CloudKit share acceptance (fallback for older iOS)
  func application(
    _ application: UIApplication,
    userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata
  ) {
    print("AppDelegate: userDidAcceptCloudKitShareWith called!")
    acceptCloudKitShare(cloudKitShareMetadata)
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
    } catch {
      print("acceptCloudKitShare: Failed - \(error)")
      await MainActor.run {
        CloudKitManager.shared.shareAcceptedMessage =
          "Failed to accept invitation: \(error.localizedDescription)"
      }
    }
  }
}
