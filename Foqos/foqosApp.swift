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

  init() {
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
        .onOpenURL { url in
          handleURL(url)
        }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) {
          userActivity in
          guard let url = userActivity.webpageURL else {
            return
          }
          handleURL(url)
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
    .modelContainer(container)
  }

  /// Root view that routes based on app mode
  @ViewBuilder
  private var rootView: some View {
    // If user hasn't selected a mode yet, show mode selection after intro
    if !appModeManager.hasSelectedMode {
      // Show normal HomeView which will show intro, then we'll show mode selection
      HomeView()
    } else {
      // Route based on selected mode
      switch appModeManager.currentMode {
      case .individual:
        HomeView()
      case .parent:
        ParentDashboardView()
      case .child:
        ChildDashboardView()
      }
    }
  }

  private func handleURL(_ url: URL) {
    // Check if this is a CloudKit share URL
    if let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
       components.host == "www.icloud.com" || components.path.contains("share") {
      // This might be a CloudKit share - let the app delegate handle it
      return
    }

    // Otherwise, handle as universal link
    navigationManager.handleLink(url)
  }
}

// MARK: - App Delegate for CloudKit Share Handling

class AppDelegate: NSObject, UIApplicationDelegate {
  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    return true
  }

  /// Handle CloudKit share acceptance
  func application(
    _ application: UIApplication,
    userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata
  ) {
    // Accept the share
    Task {
      do {
        try await CloudKitManager.shared.acceptShare(metadata: cloudKitShareMetadata)
        print("Successfully accepted CloudKit share")

        // If user accepted a share, they're likely a child
        // Update mode if not already set
        await MainActor.run {
          if !AppModeManager.shared.hasSelectedMode {
            AppModeManager.shared.selectMode(.child)
          }
        }
      } catch {
        print("Failed to accept CloudKit share: \(error)")
      }
    }
  }

  /// Handle remote notifications for CloudKit changes
  func application(
    _ application: UIApplication,
    didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
  ) {
    // Check if this is a CloudKit notification
    if let _ = CKNotification(fromRemoteNotificationDictionary: userInfo) {
      Task {
        await CloudKitManager.shared.handlePushNotification(userInfo)
        completionHandler(.newData)
      }
    } else {
      completionHandler(.noData)
    }
  }
}
