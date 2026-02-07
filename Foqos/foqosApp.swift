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
            cloudKitDatabase: .none // Disable automatic CloudKit sync for these models
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

    // Device sync for same-user multi-device sync
    @StateObject private var profileSyncManager = ProfileSyncManager.shared
    @StateObject private var syncCoordinator = SyncCoordinator.shared

    /// Sync upgrade notice (shown when legacy session records are cleaned up)
    @State private var showSyncUpgradeAlert = false

    /// CloudKit share acceptance
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
                        // Resume One More Minute timer if it was active before backgrounding
                        StrategyManager.shared.resumeOneMoreMinuteIfNeeded()
                        // Reschedule pre-activation reminders (handles warm returns on new days)
                        PreActivationReminderScheduler.rescheduleAllReminders(context: container.mainContext)
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
                    // Migrate profiles to V2 trigger system if needed
                    migrateProfilesIfNeeded(context: container.mainContext)
                    // Initialize sync if enabled
                    if profileSyncManager.isEnabled {
                        Task {
                            await profileSyncManager.setupSync()
                        }
                    }
                    // Reschedule pre-activation reminders for today
                    PreActivationReminderScheduler.rescheduleAllReminders(context: container.mainContext)
                }
        }
        .handlesExternalEvents(matching: ["*"]) // Handle all external events including CloudKit shares
        .modelContainer(container)
    }

    /// Root view that routes based on app mode
    private var rootView: some View {
        // All modes use HomeView as the default landing page
        // Parent dashboard is accessible from settings (parent mode)
        // Child parental controls info is accessible from settings (child mode)
        HomeView()
    }

    /// Migrates profiles from legacy blockingStrategyId to new trigger system (Schema V2)
    private func migrateProfilesIfNeeded(context: ModelContext) {
        do {
            let profiles = try BlockedProfiles.fetchProfiles(in: context)

            // Find profile ID with active session (if any)
            let activeSession = BlockedProfileSession.mostRecentActiveSession(in: context)
            let activeProfileId = activeSession?.blockedProfile.id

            var migratedCount = 0
            var deferredCount = 0
            var migratedProfiles: [BlockedProfiles] = []
            for profile in profiles {
                if profile.needsMigration {
                    let hasActiveSession = (profile.id == activeProfileId)
                    if profile.migrateToV2IfEligible(hasActiveSession: hasActiveSession) {
                        migratedProfiles.append(profile)
                        migratedCount += 1
                    } else if hasActiveSession {
                        deferredCount += 1
                    }
                }
            }
            if migratedCount > 0 {
                try context.save()
                Log.info("Migrated \(migratedCount) profiles to schema V2", category: .app)
                // Register schedules with DeviceActivityCenter for migrated profiles
                for profile in migratedProfiles {
                    DeviceActivityCenterUtil.scheduleTimerActivity(for: profile)
                }
            }
            if deferredCount > 0 {
                Log.info(
                    "Deferred migration for \(deferredCount) profiles with active sessions",
                    category: .app
                )
            }
        } catch {
            Log.error("Failed to migrate profiles: \(error.localizedDescription)", category: .app)
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

// MARK: - App Delegate for CloudKit Share Handling

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        Log.info("didFinishLaunchingWithOptions", category: .app)

        // Register for remote notifications to receive CloudKit push notifications
        application.registerForRemoteNotifications()

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
        Log.error("Failed to register for remote notifications: \(error)", category: .app)
    }

    func application(
        _: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Log.info("Received remote notification", category: .cloudKit)

        // Check if this is a CloudKit notification
        if let ckNotification = CKNotification(fromRemoteNotificationDictionary: userInfo) {
            Log.info("CloudKit notification received - type: \(ckNotification.notificationType.rawValue)", category: .cloudKit)

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
    func scene(_: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        for context in URLContexts {
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

func acceptCloudKitShare(_ metadata: CKShare.Metadata) {
    Log.info("Processing share", category: .cloudKit)
    Log.info("Container ID = \(metadata.containerIdentifier)", category: .cloudKit)

    Task {
        do {
            try await CloudKitManager.shared.acceptShare(metadata: metadata)
            Log.info("Successfully accepted CloudKit share", category: .cloudKit)

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
            Log.warning("Child authorization required", category: .authorization)
            await MainActor.run {
                CloudKitManager.shared.setChildAuthorizationFailure(
                    message: CloudKitError.childAuthorizationRequired.errorDescription ?? "Child authorization required"
                )
            }
        } catch {
            Log.error("Share acceptance failed: \(error)", category: .cloudKit)
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
