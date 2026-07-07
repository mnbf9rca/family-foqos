import FoqosShared
import SwiftData
import SwiftUI
import WidgetKit

@MainActor
class StrategyManager: ObservableObject {
  static let shared = StrategyManager()

  private let geofenceEvaluator: GeofenceEvaluator
  private let emergencyUnblockManager: EmergencyUnblockManager
  private let liveActivityManager: LiveActivityManager
  private let profileSyncManager: ProfileSyncManager
  private let sessionSyncService: SessionSyncService
  private let locationManager: LocationManager

  /// #201: persisted intents for session-stops dropped by a failed/exhausted CAS write.
  /// Internal (not private) so Phase-E tests can assert routing without a live CloudKit call.
  let sessionStopOutbox = SessionStopOutbox()

  @Published var elapsedTime: TimeInterval = 0
  @Published var timerTask: Task<Void, Never>?
  @Published var activeSession: BlockedProfileSession?

  @Published var showCustomStrategyView: Bool = false
  @Published var customStrategyView: (any View)? = nil

  @Published var errorMessage: String?

  private let timersUtil = TimersUtil()
  private let appBlocker: RestrictionApplying
  private let backstopRegistrar: BackstopRegistering

  init(
    geofenceEvaluator: GeofenceEvaluator = .shared,
    emergencyUnblockManager: EmergencyUnblockManager = .shared,
    liveActivityManager: LiveActivityManager = .shared,
    profileSyncManager: ProfileSyncManager = .shared,
    sessionSyncService: SessionSyncService = .shared,
    locationManager: LocationManager = .shared,
    appBlocker: RestrictionApplying = AppBlockerUtil(),
    backstopRegistrar: BackstopRegistering = DeviceActivityBackstopRegistrar()
  ) {
    self.geofenceEvaluator = geofenceEvaluator
    self.emergencyUnblockManager = emergencyUnblockManager
    self.liveActivityManager = liveActivityManager
    self.profileSyncManager = profileSyncManager
    self.sessionSyncService = sessionSyncService
    self.locationManager = locationManager
    self.appBlocker = appBlocker
    self.backstopRegistrar = backstopRegistrar
  }

  // Track if we're currently processing a remote session change
  private var processingRemoteChange = false
  private var sessionSyncTask: Task<Void, Never>?

  /// Whether session changes should be synced to CloudKit.
  /// Returns false when processing remote changes (to avoid echo loops)
  /// or when sync is disabled.
  /// Note: All access is @MainActor-isolated, eliminating race conditions.
  private var shouldSyncSessionChange: Bool {
    profileSyncManager.isEnabled && !processingRemoteChange
  }

  var isBlocking: Bool {
    return activeSession?.isActive == true
  }

  var isBreakActive: Bool {
    return activeSession?.isBreakActive == true
  }

  var isBreakAvailable: Bool {
    return activeSession?.isBreakAvailable ?? false
  }

  var isOneMoreMinuteActive: Bool {
    return activeSession?.isOneMoreMinuteActive() == true
  }

  var isOneMoreMinuteAvailable: Bool {
    return activeSession?.isOneMoreMinuteAvailable ?? false
  }

  func defaultReminderMessage(forProfile profile: BlockedProfiles?) -> String {
    let baseMessage = "Get back to productivity"
    guard let profile else {
      return baseMessage
    }
    return baseMessage + " by enabling \(profile.name)"
  }

  func loadActiveSession(context: ModelContext) throws {
    do {
      activeSession = try getActiveSession(context: context)
    } catch {
      activeSession = nil
      liveActivityManager.endSessionActivity()
      throw error
    }

    if activeSession?.isActive == true {
      startTimer()

      // Start live activity for existing session if one exists
      // live activities can only be started when the app is in the foreground
      if let session = activeSession {
        liveActivityManager.startSessionActivity(session: session)

        // Re-register stop schedule on app launch
        DeviceActivityCenterUtil.scheduleStopActivity(for: session.blockedProfile)
      }
    } else {
      // Close live activity if no session is active and a scheduled session might have ended
      liveActivityManager.endSessionActivity()
      // Re-attempt migration for profiles deferred due to active sessions
      ProfileMigrationUtil.migrateProfilesIfNeeded(context: context)
    }
  }

  func toggleBlocking(context: ModelContext, activeProfile: BlockedProfiles?) {
    if isBlocking {
      // #237 / MD3: reconcile against cross-process state before ending a possibly stale
      // on-screen session. The next Stop acts on the refreshed state.
      if let displayed = activeSession,
        let sharedSession = SharedData.getActiveSharedSession(),
        sharedSession.id != displayed.id
      {
        try? loadActiveSession(context: context)
        errorMessage =
          "This session was changed by a scheduled timer. The view has been refreshed. "
          + "Tap Stop again if a session is still active."
        return
      }

      // Check geofence rule if one exists
      if let session = activeSession,
        let geofenceRule = session.blockedProfile.geofenceRule,
        geofenceRule.hasLocations
      {
        geofenceEvaluator.checkGeofenceAndStop(context: context, profile: session.blockedProfile) {
          self.stopBlocking(context: context, bypassStrategy: true)
        }
        return
      }

      stopBlocking(context: context, bypassStrategy: true)
    } else {
      geofenceEvaluator.checkGeofenceAndStart(context: context, activeProfile: activeProfile) {
        ctx, profile in
        self.startBlocking(context: ctx, activeProfile: profile, bypassStrategy: true)
      }
    }
  }

  func toggleBreak(context: ModelContext) {
    guard let session = activeSession else {
      Log.info("active session does not exist", category: .strategy)
      return
    }

    if session.isBreakOpenRawFields {
      stopBreak(context: context)
    } else {
      startBreak(context: context)
    }
  }

  func startOneMoreMinute(context: ModelContext) {
    guard let session = activeSession else {
      Log.info("One more minute only available in active session", category: .strategy)
      return
    }

    guard session.isOneMoreMinuteAvailable else {
      Log.info("One more minute already used this session", category: .strategy)
      return
    }

    let now = Date()
    let profile = session.blockedProfile
    let deadline = now.addingTimeInterval(60)
    let live = BlockedProfiles.getSnapshot(for: profile)

    do {
      try backstopRegistrar.replaceOneMoreMinuteBackstop(
        profileId: profile.id, deadline: deadline, now: now)
    } catch {
      errorMessage = "Couldn't grant one more minute. Please try again."
      Log.error("startOneMoreMinute: backstop registration failed: \(error.localizedDescription)", category: .timer)
      return
    }

    let opened = SharedData.openOneMoreMinuteGrant(
      startDate: now,
      deadline: deadline,
      expectedSessionId: session.id,
      liveSnapshot: live,
      applier: appBlocker)
    guard opened else {
      backstopRegistrar.removeOneMoreMinuteBackstop(profileId: profile.id)
      try? loadActiveSession(context: context)
      errorMessage = "This session changed. Please try again."
      return
    }

    mirrorGrantFieldsFromShared(session)
    liveActivityManager.updateOneMoreMinuteState(session: session)
    WidgetCenter.shared.reloadTimelines(ofKind: "ProfileControlWidget")
  }

  func startTimer() {
    stopTimer()
    timerTask = Task {
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled else { break }
        guard let session = activeSession else { break }

        if session.isBreakActive {
          // Calculate break time remaining (countdown)
          guard let breakStartTime = session.breakStartTime else { continue }
          let timeSinceBreakStart = Date().timeIntervalSince(breakStartTime)
          let breakDurationInSeconds = TimeInterval(session.blockedProfile.breakTimeInMinutes * 60)
          elapsedTime = max(0, breakDurationInSeconds - timeSinceBreakStart)
        } else {
          // Calculate session elapsed time
          let rawElapsedTime = Date().timeIntervalSince(session.startTime)
          let breakDuration = session.calculateBreakDuration()
          elapsedTime = rawElapsedTime - breakDuration
        }
      }
    }
  }

  func stopTimer() {
    timerTask?.cancel()
    timerTask = nil
  }

  private func mirrorGrantFieldsFromShared(_ session: BlockedProfileSession) {
    guard let shared = SharedData.getActiveSharedSession(), shared.id == session.id else { return }
    session.breakStartTime = shared.breakStartTime
    session.breakEndTime = shared.breakEndTime
    session.breakEndDeadline = shared.breakEndDeadline
    session.oneMoreMinuteStartTime = shared.oneMoreMinuteStartTime
    session.oneMoreMinuteDeadline = shared.oneMoreMinuteDeadline
    session.oneMoreMinuteUsed = shared.oneMoreMinuteUsed
    session.pinnedProfileConfigData = shared.pinnedProfileConfig.flatMap {
      try? JSONEncoder().encode($0)
    }
    try? session.modelContext?.save()
  }

  func toggleSessionFromDeeplink(
    _ profileId: String,
    url: URL,
    context: ModelContext
  ) async {
    guard let profileUUID = UUID(uuidString: profileId) else {
      self.errorMessage = "This tag doesn't contain a valid profile link"
      return
    }

    do {
      guard
        let profile: BlockedProfiles = try BlockedProfiles.findProfile(
          byID: profileUUID,
          in: context
        )
      else {
        self.errorMessage =
          "No matching profile found on this device. The profile may have been deleted or this tag belongs to a different device."
        return
      }

      let manualStrategy = getStrategy(id: ManualBlockingStrategy.id)

      let activeSession = try getActiveSession(context: context)

      if let localActiveSession = activeSession {
        if localActiveSession.blockedProfile.disableBackgroundStops {
          Log.info(
            "profile: \(localActiveSession.blockedProfile.name) has disable background stops enabled, not stopping it",
            category: .strategy)
          self.errorMessage =
            "profile: \(localActiveSession.blockedProfile.name) has disable background stops enabled, not stopping it"
          return
        }

        // When switching profiles, validate the new profile's start trigger
        // BEFORE stopping the current session to avoid leaving the user with
        // no active session if the new profile isn't configured for deep links
        let isSwitching = localActiveSession.blockedProfile.id != profile.id
        if isSwitching {
          guard profile.startTriggers.deepLink else {
            self.errorMessage =
              "\(profile.name) is not configured to start via written NFC or printed QR"
            return
          }
        }

        let stopResult = StartStopActionResolver.canStop(
          with: .deepLink,
          conditions: localActiveSession.blockedProfile.stopConditions,
          sessionTag: localActiveSession.tag,
          stopNFCTagId: localActiveSession.blockedProfile.stopNFCTagId,
          stopQRCodeId: localActiveSession.blockedProfile.stopQRCodeId
        )
        guard stopResult.allowed else {
          self.errorMessage =
            stopResult.errorMessage
            ?? "\(localActiveSession.blockedProfile.name) cannot be stopped via written NFC or printed QR"
          return
        }

        // Check geofence rule — in foreground, handle permissions with user-facing messages
        if let geofenceRule = localActiveSession.blockedProfile.geofenceRule,
          geofenceRule.hasLocations
        {
          let locationManager = self.locationManager
          if locationManager.isNotDetermined {
            locationManager.requestAuthorization()
            self.errorMessage =
              "Please allow location access to stop this profile, then try again."
            return
          }
          if locationManager.isDenied {
            self.errorMessage =
              "Location access is denied. Enable location services in Settings to use location-based restrictions."
            return
          }
        }

        let geofenceResult = await geofenceEvaluator.evaluateGeofenceForStop(
          profile: localActiveSession.blockedProfile,
          context: context
        )
        if let geofenceResult, !geofenceResult.isSatisfied {
          self.errorMessage = geofenceResult.failureMessage ?? "Location restriction not met."
          return
        }

        _ =
          manualStrategy
          .stopBlocking(
            context: context,
            session: localActiveSession
          )

        if isSwitching {
          Log.info("User is switching sessions from deep link", category: .strategy)

          _ = manualStrategy.startBlocking(
            context: context,
            profile: profile,
            forceStart: false
          )
        }
      } else {
        guard profile.startTriggers.deepLink else {
          self.errorMessage =
            "\(profile.name) is not configured to start via written NFC or printed QR"
          return
        }

        _ = manualStrategy.startBlocking(
          context: context,
          profile: profile,
          forceStart: false
        )
      }
    } catch {
      self.errorMessage = "Something went wrong. Please try again."
    }
  }

  func startSessionFromBackground(
    _ profileId: UUID,
    context: ModelContext,
    durationInMinutes: Int? = nil
  ) throws {
    do {
      guard
        let profile = try BlockedProfiles.findProfile(
          byID: profileId,
          in: context
        )
      else {
        self.errorMessage = "Could not find that profile."
        throw IntentError.profileNotFound
      }

      if let localActiveSession = try getActiveSession(context: context) {
        Log.info(
          "session is already active for profile: \(localActiveSession.blockedProfile.name), not starting a new one",
          category: .strategy)
        self.errorMessage = "A session is already active."
        throw IntentError.sessionAlreadyActive
      }

      if let duration = durationInMinutes {
        if duration < DeviceActivityLimits.minimumIntervalMinutes
          || duration > DeviceActivityLimits.maximumTimerMinutes
        {
          // Plain String → interpolate the min constant and the derived
          // human-readable max (single-sourced; no bare literals).
          self.errorMessage =
            "Duration must be between \(DeviceActivityLimits.minimumIntervalMinutes) minutes "
            + "and \(DeviceActivityLimits.maximumTimerDescription)."
          throw IntentError.durationOutOfRange
        }

        if let strategyTimerData = StrategyTimerData.toData(
          from: StrategyTimerData(durationInMinutes: duration)
        ) {
          profile.strategyData = strategyTimerData
          profile.updatedAt = Date()
          BlockedProfiles.updateSnapshot(for: profile)
          try context.save()
        }

        let shortcutTimerStrategy = getStrategy(id: ShortcutTimerBlockingStrategy.id)
        _ = shortcutTimerStrategy.startBlocking(
          context: context,
          profile: profile,
          forceStart: true
        )
      } else {
        let manualStrategy = getStrategy(id: ManualBlockingStrategy.id)
        _ = manualStrategy.startBlocking(
          context: context,
          profile: profile,
          forceStart: true
        )
      }
    } catch let error as IntentError {
      throw error
    } catch {
      Log.error(
        "Unexpected error in startSessionFromBackground: \(error.localizedDescription)",
        category: .strategy
      )
      let message = "Something went wrong starting the session"
      self.errorMessage = message
      throw IntentError.unexpected(message)
    }
  }

  func stopSessionFromBackground(
    _ profileId: UUID,
    context: ModelContext
  ) async throws {
    do {
      guard
        let profile = try BlockedProfiles.findProfile(
          byID: profileId,
          in: context
        )
      else {
        self.errorMessage = "Could not find that profile."
        throw IntentError.profileNotFound
      }

      let manualStrategy = getStrategy(id: ManualBlockingStrategy.id)

      guard let localActiveSession = try getActiveSession(context: context) else {
        Log.info(
          "session is not active for profile: \(profile.name), not stopping it", category: .strategy
        )
        self.errorMessage = "\(profile.name) is not currently active."
        throw IntentError.noActiveSession(profileName: profile.name)
      }

      if localActiveSession.blockedProfile.id != profile.id {
        Log.info(
          "session is not active for profile: \(profile.name), not stopping it", category: .strategy
        )
        self.errorMessage = "\(profile.name) is not currently active."
        throw IntentError.noActiveSession(profileName: profile.name)
      }

      if profile.disableBackgroundStops {
        Log.info(
          "profile: \(profile.name) has disable background stops enabled, not stopping it",
          category: .strategy)
        self.errorMessage = "\(profile.name) cannot be stopped remotely."
        throw IntentError.backgroundStopsDisabled(profileName: profile.name)
      }

      // Evaluate geofence with real location, then map to the shared policy.
      let geofenceResult = await geofenceEvaluator.evaluateGeofenceForStop(
        profile: profile,
        context: context
      )
      let geofenceState: BackgroundStopPolicy.GeofenceState
      if let geofenceResult {
        geofenceState =
          geofenceResult.isSatisfied
          ? .satisfied
          : .notSatisfied(reason: geofenceResult.failureMessage ?? "Location restriction not met.")
      } else {
        geofenceState = .noRule
      }

      // App-side typed guards above preserve existing IntentError mapping; the shared policy
      // evaluates only stop conditions and geofence for this already-matched, stoppable session.
      let decision = BackgroundStopPolicy.evaluate(
        channel: .shortcut,
        sessionMatchesProfile: true,
        disableBackgroundStops: false,
        geofence: geofenceState,
        stopConditions: profile.stopConditions
      )

      switch decision {
      case .allowed:
        break
      case .denied(.geofenceNotSatisfied(let reason)):
        Log.info(
          "Geofence blocked background stop for profile: \(profile.name) — \(reason)",
          category: .strategy)
        geofenceEvaluator.postGeofenceBlockedNotification(
          profileId: profile.id, profileName: profile.name, reason: reason)
        self.errorMessage = "Cannot stop — \(reason)"
        throw IntentError.geofenceBlocked(reason: reason)
      case .denied(.geofenceUnavailable):
        let reason = "Your location can't be confirmed right now."
        Log.info(
          "Geofence blocked background stop for profile: \(profile.name) — \(reason)",
          category: .strategy)
        geofenceEvaluator.postGeofenceBlockedNotification(
          profileId: profile.id, profileName: profile.name, reason: reason)
        self.errorMessage = "Cannot stop — \(reason)"
        throw IntentError.geofenceBlocked(reason: reason)
      case .denied(.stopConditionNotMet(let reason)):
        Log.info(
          "Background stop refused for profile: \(profile.name) — stop conditions not met",
          category: .strategy)
        self.errorMessage = reason
        throw IntentError.stopConditionsNotMet(reason: reason)
      case .denied(.backgroundStopsDisabled):
        // Defensive only: disableBackgroundStops is handled before the policy call above.
        self.errorMessage = "\(profile.name) cannot be stopped in the background."
        throw IntentError.backgroundStopsDisabled(profileName: profile.name)
      case .denied(.noMatchingSession):
        // Defensive only: session/profile matching is handled before the policy call above.
        self.errorMessage = "\(profile.name) cannot be stopped in the background."
        throw IntentError.backgroundStopsDisabled(profileName: profile.name)
      }

      let _ = manualStrategy.stopBlocking(
        context: context,
        session: localActiveSession
      )
    } catch let error as IntentError {
      throw error
    } catch {
      Log.error(
        "Unexpected error in stopSessionFromBackground: \(error.localizedDescription)",
        category: .strategy
      )
      let message = "Something went wrong stopping the session"
      self.errorMessage = message
      throw IntentError.unexpected(message)
    }
  }

  /// Delegate emergency unblock to EmergencyUnblockManager, providing session stop logic.
  /// Throws EmergencyUnblockError if unblock is not allowed (no remaining, geofence blocked, etc.).
  func emergencyUnblock(context: ModelContext) async throws(EmergencyUnblockError) {
    let session = try? getActiveSession(context: context)
    try await emergencyUnblockManager.emergencyUnblock(
      context: context,
      activeSession: session
    ) { [weak self] ctx, sess in
      guard let self else { return }
      let manualStrategy = self.getStrategy(id: ManualBlockingStrategy.id)
      _ = manualStrategy.stopBlocking(context: ctx, session: sess)
      self.liveActivityManager.endSessionActivity()
      self.scheduleReminder(profile: sess.blockedProfile)
      self.stopTimer()
    }
  }

  /// Sync a session start to CloudKit via CAS. Uses passed context for persistence.
  private func syncSessionStart(session: BlockedProfileSession, context: ModelContext) {
    guard shouldSyncSessionChange else { return }

    let previousTask = sessionSyncTask
    sessionSyncTask = Task {
      await previousTask?.value
      let result = await sessionSyncService.startSession(
        profileId: session.blockedProfile.id,
        startTime: session.startTime
      )

      switch result {
      case .started(let seq):
        Log.info("Session synced with seq=\(seq)", category: .strategy)
      case .alreadyActive(let existing):
        Log.info(
          "Joined existing session from \(existing.sessionOriginDevice ?? "unknown")",
          category: .strategy
        )
        // Reconcile local startTime to match authoritative remote startTime
        // Verify session identity — activeSession may have changed during async call
        if let remoteStartTime = existing.startTime,
          let currentSession = self.activeSession,
          currentSession.id == session.id,
          currentSession.startTime != remoteStartTime
        {
          currentSession.startTime = remoteStartTime
          do {
            try context.save()
          } catch {
            Log.error(
              "Failed to save reconciled startTime: \(error.localizedDescription)",
              category: .strategy)
          }
          Log.info("Reconciled local startTime to \(remoteStartTime)", category: .strategy)
        }
      case .error(let error):
        Log.info("Failed to sync session start - \(error)", category: .strategy)
      }
    }
  }

  /// #201: process the result of a session-stop CAS attempt. On success, logs. On the terminal
  /// outcomes (an immediate `.error`, or `.conflict`/`.error` after one retry), the dropped stop
  /// intent is persisted to the outbox for re-drive on foreground (`drainSessionStopOutbox()` is
  /// wired to scenePhase `.active` in `FoqosApp`).
  /// Extracted from the CAS Task closure so Phase-E tests can exercise the routing without a
  /// live CloudKit round trip.
  func handleStopResult(
    _ result: SessionSyncService.StopResult, profileId: UUID
  ) async {
    switch result {
    case .stopped(let seq):
      Log.info("Session stop synced with seq=\(seq)", category: .strategy)
    case .alreadyStopped:
      Log.info("Session was already stopped", category: .strategy)
    case .conflict(let current):
      Log.info("Stop conflict, current seq=\(current.sequenceNumber)", category: .strategy)
      // Retry stop once
      let retryResult = await sessionSyncService.stopSession(profileId: profileId)
      switch retryResult {
      case .stopped(let seq):
        Log.info("Stop retry succeeded with seq=\(seq)", category: .strategy)
      case .alreadyStopped:
        Log.info("Stop retry found session already stopped", category: .strategy)
      case .conflict, .error:
        Log.info("Stop retry failed - \(retryResult)", category: .strategy)
        // #201: persist the dropped stop intent for foreground re-drive instead of losing it.
        sessionStopOutbox.enqueue(profileId: profileId)
      }
    case .error(let error):
      Log.info("Failed to sync session stop - \(error)", category: .strategy)
      // #201: persist the dropped stop intent for foreground re-drive instead of losing it.
      sessionStopOutbox.enqueue(profileId: profileId)
    }
  }

  /// #201: re-drive persisted session-stop intents. Wired to scenePhase `.active` in `FoqosApp`.
  func drainSessionStopOutbox() async {
    await sessionStopOutbox.drain { [weak self] profileId in
      guard let self else { return true }
      let result = await self.sessionSyncService.stopSession(profileId: profileId)
      switch result {
      case .stopped, .alreadyStopped:
        return true
      case .conflict, .error:
        return false
      }
    }
  }

  /// Single source of truth for session activation — all start paths converge here.
  /// Handles state updates, timer, live activity, stop scheduling, widget refresh, and CAS sync.
  private func activateSession(
    _ session: BlockedProfileSession,
    context: ModelContext? = nil
  ) {
    // Cancel stale reminders/notifications from previous sessions
    timersUtil.cancelAll()

    // Update profile snapshot in case settings changed
    BlockedProfiles.updateSnapshot(for: session.blockedProfile)

    errorMessage = nil
    activeSession = session
    startTimer()
    liveActivityManager.startSessionActivity(session: session)

    // Schedule stop activity if configured
    DeviceActivityCenterUtil.scheduleStopActivity(for: session.blockedProfile)

    // Cancel pre-activation reminders now that profile is active
    TimersUtil.cancelAllPreActivationReminders(for: session.blockedProfile.id)

    // Refresh widgets
    WidgetCenter.shared.reloadTimelines(ofKind: "ProfileControlWidget")

    // Sync session start via CAS
    // Use passed context if available, fall back to session's modelContext
    if let ctx = context ?? session.modelContext {
      syncSessionStart(session: session, context: ctx)
    } else {
      Log.warning("No ModelContext available for session sync", category: .strategy)
    }

    // Write heartbeat for child device monitoring (#190)
    if AppModeManager.shared.currentMode == .child {
      HeartbeatManager.shared.writeHeartbeat()
    }
  }

  func getStrategy(id: String) -> BlockingStrategy {
    var strategy = StartStopActionResolver.getStrategyFromId(id: id)

    strategy.onSessionCreation = { session in
      self.dismissView()

      switch session {
      case .started(let session):
        self.activateSession(session)
      case .ended(let endedProfile):
        // Cancel stale reminders/notifications from the ended session
        self.timersUtil.cancelAll()

        self.activeSession = nil
        self.liveActivityManager.endSessionActivity()
        self.scheduleReminder(profile: endedProfile)

        self.stopTimer()
        self.elapsedTime = 0

        // Refresh widgets when session ends
        WidgetCenter.shared.reloadTimelines(ofKind: "ProfileControlWidget")

        // Remove all break timer activities
        DeviceActivityCenterUtil.removeAllBreakTimerActivities()

        // Remove one more minute activity for the ended profile
        DeviceActivityCenterUtil.removeOneMoreMinuteActivity(for: endedProfile)

        // Remove all strategy timer activities
        DeviceActivityCenterUtil.removeAllStrategyTimerActivities()

        // Migrate deferred profile now that session has ended
        if endedProfile.needsMigration {
          endedProfile.migrateToV2IfNeeded()
          if !endedProfile.needsMigration, let context = endedProfile.modelContext {
            do {
              try context.save()
            } catch {
              Log.error(
                "Failed to save deferred profile migration: \(error.localizedDescription)",
                category: .strategy)
            }
            Log.info(
              "Migrated deferred profile '\(endedProfile.name)' on session end", category: .app)
            DeviceActivityCenterUtil.scheduleTimerActivity(for: endedProfile)
          }
        }

        // Sync session stop using CAS (if global sync is enabled)
        if self.shouldSyncSessionChange {
          let previousTask = self.sessionSyncTask
          self.sessionSyncTask = Task {
            await previousTask?.value
            let result = await self.sessionSyncService.stopSession(
              profileId: endedProfile.id
            )
            await self.handleStopResult(result, profileId: endedProfile.id)
          }
        }
      }
    }

    strategy.onErrorMessage = { message in
      self.dismissView()

      self.errorMessage = message
    }

    return strategy
  }

  private func startBreak(context: ModelContext) {
    guard let session = activeSession else {
      Log.info("Breaks only available in active session", category: .strategy)
      return
    }

    guard session.isBreakAvailable else {
      Log.info("Breaks is not available", category: .strategy)
      return
    }

    let now = Date()
    let profile = session.blockedProfile
    let deadline = now.addingTimeInterval(TimeInterval(profile.breakTimeInMinutes * 60))
    let live = BlockedProfiles.getSnapshot(for: profile)

    do {
      try backstopRegistrar.replaceBreakBackstop(profileId: profile.id, deadline: deadline, now: now)
    } catch {
      errorMessage = "Couldn't start your break. Please try again."
      Log.error("startBreak: backstop registration failed: \(error.localizedDescription)", category: .timer)
      return
    }

    let opened = SharedData.openBreakGrant(
      startDate: now,
      deadline: deadline,
      expectedSessionId: session.id,
      liveSnapshot: live,
      applier: appBlocker)
    guard opened else {
      backstopRegistrar.removeBreakBackstop(profileId: profile.id)
      try? loadActiveSession(context: context)
      errorMessage = "This session changed. Please try again."
      return
    }
    backstopRegistrar.removeOneMoreMinuteBackstop(profileId: profile.id)
    mirrorGrantFieldsFromShared(session)

    // Schedule a reminder to get back to the profile after the break
    scheduleBreakReminder(profile: profile)

    // Refresh widgets when break starts
    WidgetCenter.shared.reloadTimelines(ofKind: "ProfileControlWidget")

    // Update live activity to show break state
    liveActivityManager.updateBreakState(session: session)
  }

  private func stopBreak(context: ModelContext) {
    guard let session = activeSession else {
      Log.info("Breaks only available in active session", category: .strategy)
      return
    }

    guard session.isBreakOpenRawFields else {
      Log.info("No open break to stop", category: .strategy)
      return
    }

    let now = Date()
    let profile = session.blockedProfile
    let live = BlockedProfiles.getSnapshot(for: profile)

    let closed = SharedData.closeBreakGrantIfExpiredOrExplicit(
      expectedSessionId: session.id,
      explicit: true,
      now: now,
      process: .mainApp,
      durationMinutes: profile.breakTimeInMinutes,
      liveSnapshot: live,
      applier: appBlocker)
    guard closed else {
      try? loadActiveSession(context: context)
      errorMessage = "This session changed. Please try again."
      return
    }
    mirrorGrantFieldsFromShared(session)

    backstopRegistrar.removeBreakBackstop(profileId: profile.id)

    // Cancel pending notifications and clean up any delivered pre-activation reminders
    timersUtil.cancelAllNotifications()

    // Refresh widgets when break ends
    WidgetCenter.shared.reloadTimelines(ofKind: "ProfileControlWidget")

    // Update live activity to show break has ended
    liveActivityManager.updateBreakState(session: session)
  }

  private func dismissView() {
    showCustomStrategyView = false
    customStrategyView = nil
  }

  private func getActiveSession(context: ModelContext) throws
    -> BlockedProfileSession?
  {
    // Before fetching the active session, sync any schedule sessions
    syncScheduleSessions(context: context)

    return
      try BlockedProfileSession
      .mostRecentActiveSession(in: context)
  }

  private func syncScheduleSessions(context: ModelContext) {
    var hadDanglingGrant = false

    // Process any active scheduled sessions
    if let activeScheduledSession = SharedData.getActiveSharedSession() {
      if SharedData.endedSessionHadOpenGrant(activeScheduledSession) {
        hadDanglingGrant = true
      }
      BlockedProfileSession.upsertSessionFromSnapshot(
        in: context,
        withSnapshot: activeScheduledSession
      )

      // Sync scheduled session start using CAS (if global sync is enabled)
      // This ensures multi-device coordination for scheduled profile activations
      if profileSyncManager.isEnabled {
        let previousTask = sessionSyncTask
        sessionSyncTask = Task {
          await previousTask?.value
          let result = await sessionSyncService.startSession(
            profileId: activeScheduledSession.blockedProfileId,
            startTime: activeScheduledSession.startTime
          )

          switch result {
          case .started(let seq):
            Log.info("Scheduled session synced with seq=\(seq)", category: .strategy)
          case .alreadyActive(let existing):
            Log.info(
              "Scheduled session joined existing from \(existing.sessionOriginDevice ?? "unknown")",
              category: .strategy
            )
            // Reconcile local startTime to match authoritative remote startTime
            if let remoteStartTime = existing.startTime,
              let currentSession = self.activeSession,
              currentSession.startTime != remoteStartTime
            {
              currentSession.startTime = remoteStartTime
              do {
                try context.save()
              } catch {
                Log.error(
                  "Failed to save reconciled scheduled session startTime: \(error.localizedDescription)",
                  category: .strategy)
              }
              Log.info(
                "Reconciled scheduled session startTime to \(remoteStartTime)", category: .strategy)
            }
          case .error(let error):
            Log.info("Failed to sync scheduled session - \(error)", category: .strategy)
          }
        }
      }
    }

    // Process any completed scheduled sessions
    let completedScheduleSessions = SharedData.getAndFlushCompletedSessionsForScheduler()
    for completedScheduleSession in completedScheduleSessions {
      if SharedData.endedSessionHadOpenGrant(completedScheduleSession) {
        hadDanglingGrant = true
      }
      BlockedProfileSession.upsertSessionFromSnapshot(
        in: context,
        withSnapshot: completedScheduleSession
      )

      // Sync scheduled session end using CAS (if global sync is enabled)
      if profileSyncManager.isEnabled, let endTime = completedScheduleSession.endTime {
        let previousTask = sessionSyncTask
        sessionSyncTask = Task {
          await previousTask?.value
          let result = await sessionSyncService.stopSession(
            profileId: completedScheduleSession.blockedProfileId,
            endTime: endTime
          )

          switch result {
          case .stopped(let seq):
            Log.info("Scheduled session stop synced with seq=\(seq)", category: .strategy)
          case .alreadyStopped:
            Log.info("Scheduled session was already stopped", category: .strategy)
          case .conflict, .error:
            break  // Handle silently for completed sessions
          }
        }
      }
    }

    if hadDanglingGrant {
      timersUtil.cancelAllNotifications()
    }
  }

  /// Start blocking for the given profile.
  /// - Parameter bypassStrategy: When true, uses ManualBlockingStrategy to create the session
  ///   directly. Use this when the V2 trigger system has already routed the start action
  ///   (e.g., NFC tag was already scanned) to avoid redundant scanning by legacy strategies.
  private func startBlocking(
    context: ModelContext,
    activeProfile: BlockedProfiles?,
    bypassStrategy: Bool = false
  ) {
    guard let definedProfile = activeProfile else {
      Log.info(
        "No active profile found, calling stop blocking with no session", category: .strategy)
      return
    }

    // When bypassStrategy is true, the V2 trigger system has already routed
    // the start action. Use ManualBlockingStrategy to create the session
    // directly, avoiding redundant NFC/QR scans from legacy strategies.
    let strategyId =
      bypassStrategy
      ? ManualBlockingStrategy.id
      : definedProfile.blockingStrategyId

    if let strategyId {
      let strategy = getStrategy(id: strategyId)
      let view = strategy.startBlocking(
        context: context,
        profile: definedProfile,
        forceStart: false
      )

      if let customView = view {
        showCustomStrategyView = true
        customStrategyView = customView
      }
    }
  }

  /// Start blocking with a pre-scanned NFC tag (for trigger-based start)
  func startWithNFCTag(context: ModelContext, profile: BlockedProfiles, tagId: String) {
    // Validate specific NFC tag if required
    if profile.startTriggers.specificNFC {
      guard let requiredTag = profile.startNFCTagId, tagId == requiredTag else {
        errorMessage = "This NFC tag doesn't match the one configured for this profile"
        return
      }
    }
    let prefixedTag = "nfc:\(tagId)"
    startWithTag(context: context, profile: profile, tag: prefixedTag)
  }

  /// Start blocking with a pre-scanned QR code (for trigger-based start)
  func startWithQRCode(context: ModelContext, profile: BlockedProfiles, codeValue: String) {
    // Validate specific QR code if required
    if profile.startTriggers.specificQR {
      guard let requiredCode = profile.startQRCodeId, codeValue == requiredCode else {
        errorMessage = "This QR code doesn't match the one configured for this profile"
        return
      }
    }
    let prefixedTag = "qr:\(codeValue)"
    startWithTag(context: context, profile: profile, tag: prefixedTag)
  }

  /// Stop blocking with a scanned NFC tag (for stop-condition-based stop)
  func stopWithNFCTag(context: ModelContext, tagId: String) {
    guard let session = activeSession else {
      errorMessage = "No active session to stop"
      return
    }

    let validation = StartStopActionResolver.canStop(
      with: .nfc(tag: tagId),
      conditions: session.blockedProfile.stopConditions,
      sessionTag: session.tag,
      stopNFCTagId: session.blockedProfile.stopNFCTagId,
      stopQRCodeId: session.blockedProfile.stopQRCodeId
    )

    if validation.allowed {
      // Check geofence before allowing the stop
      if let geofenceRule = session.blockedProfile.geofenceRule,
        geofenceRule.hasLocations
      {
        geofenceEvaluator.checkGeofenceAndStop(context: context, profile: session.blockedProfile) {
          self.stopBlocking(context: context, bypassStrategy: true)
        }
      } else {
        stopBlocking(context: context, bypassStrategy: true)
      }
    } else {
      errorMessage = validation.errorMessage
    }
  }

  /// Stop blocking with a scanned QR code (for stop-condition-based stop)
  func stopWithQRCode(context: ModelContext, codeValue: String) {
    guard let session = activeSession else {
      errorMessage = "No active session to stop"
      return
    }

    let validation = StartStopActionResolver.canStop(
      with: .qr(code: codeValue),
      conditions: session.blockedProfile.stopConditions,
      sessionTag: session.tag,
      stopNFCTagId: session.blockedProfile.stopNFCTagId,
      stopQRCodeId: session.blockedProfile.stopQRCodeId
    )

    if validation.allowed {
      // Check geofence before allowing the stop
      if let geofenceRule = session.blockedProfile.geofenceRule,
        geofenceRule.hasLocations
      {
        geofenceEvaluator.checkGeofenceAndStop(context: context, profile: session.blockedProfile) {
          self.stopBlocking(context: context, bypassStrategy: true)
        }
      } else {
        stopBlocking(context: context, bypassStrategy: true)
      }
    } else {
      errorMessage = validation.errorMessage
    }
  }

  /// Start blocking with a pre-scanned tag (internal helper)
  private func startWithTag(context: ModelContext, profile: BlockedProfiles, tag: String) {
    AppBlockerUtil().activateRestrictions(for: BlockedProfiles.getSnapshot(for: profile))

    let session = BlockedProfileSession.createSession(
      in: context,
      withTag: tag,
      withProfile: profile,
      forceStart: false
    )

    activateSession(session, context: context)

    Log.info("Started session for profile '\(profile.name)' with tag", category: .strategy)
  }

  /// Stop the active blocking session.
  /// - Parameter bypassStrategy: When true, uses ManualBlockingStrategy to end the session
  ///   directly. Use this when the V2 trigger system has already validated stop conditions
  ///   (e.g., NFC tag was already scanned) to avoid redundant scanning by legacy strategies.
  private func stopBlocking(context: ModelContext, bypassStrategy: Bool = false) {
    guard let session = activeSession else {
      Log.info(
        "No active session found, calling stop blocking with no session", category: .strategy)
      return
    }

    // When bypassStrategy is true, the caller has already handled any required
    // NFC/QR scanning and validation. Use ManualBlockingStrategy to end the
    // session directly, avoiding a redundant second scan from legacy strategies.
    let strategyId =
      bypassStrategy
      ? ManualBlockingStrategy.id
      : session.blockedProfile.blockingStrategyId

    if let strategyId {
      let strategy = getStrategy(id: strategyId)
      let view = strategy.stopBlocking(context: context, session: session)

      if let customView = view {
        showCustomStrategyView = true
        customStrategyView = customView
      }
    }

    DeviceActivityCenterUtil.removeStopScheduleActivity(for: session.blockedProfile)
    DeviceActivityCenterUtil.removeOneMoreMinuteActivity(for: session.blockedProfile)
  }

  private func scheduleReminder(profile: BlockedProfiles) {
    guard let reminderTimeInSeconds = profile.reminderTimeInSeconds else {
      return
    }

    let profileName = profile.name
    let message = profile.customReminderMessage ?? defaultReminderMessage(forProfile: profile)
    timersUtil
      .scheduleNotification(
        title: profileName + " time!",
        message: message,
        seconds: TimeInterval(reminderTimeInSeconds)
      )
  }

  private func scheduleBreakReminder(profile: BlockedProfiles) {
    // At 0 minutes, (0-1)*60 underflows; at 1 minute, (1-1)*60 = 0s is meaningless
    guard profile.breakTimeInMinutes > 1 else { return }

    let profileName = profile.name
    let breakNotificationTimeInSeconds = (profile.breakTimeInMinutes - 1) * 60

    timersUtil.scheduleNotification(
      title: "Break almost over!",
      message: "Hope you enjoyed your break, starting " + profileName + " in 1 minute.",
      seconds: TimeInterval(breakNotificationTimeInSeconds)
    )
  }

  func cleanUpGhostSchedules(context: ModelContext) {
    let allActivities = DeviceActivityCenterUtil.getDeviceActivities()
    let scheduleTimerActivity = ScheduleTimerActivity()
    let scheduleActivities = scheduleTimerActivity.getAllScheduleTimerActivities(
      from: allActivities)

    Log.info(
      "Found \(scheduleActivities.count) schedule timer activities out of \(allActivities.count) total activities",
      category: .strategy)

    for activity in scheduleActivities {
      let rawValue = activity.rawValue
      guard let profileId = UUID(uuidString: rawValue) else {
        // This shouldn't happen since we filtered above, but print just in case
        Log.info(
          "Unexpected: failed to parse profile id from filtered activity: \(rawValue)",
          category: .strategy)
        continue
      }

      do {
        if let profile = try BlockedProfiles.findProfile(byID: profileId, in: context) {
          let hasScheduledStart =
            profile.startTriggers.schedule
            && profile.startSchedule?.isActive == true
          let hasLegacySchedule = profile.schedule?.isActive == true
          if !hasScheduledStart && !hasLegacySchedule {
            Log.info(
              "Profile '\(profile.name)' has no schedule but has device activity registered. Removing ghost schedule...",
              category: .strategy)
            DeviceActivityCenterUtil.removeScheduleTimerActivities(for: profile)
          } else {
            Log.info(
              "Profile '\(profile.name)' has schedule - activity is valid", category: .strategy)
          }
        } else {
          // Profile truly doesn't exist in database
          Log.info(
            "No profile found for activity \(rawValue). Removing orphaned schedule...",
            category: .strategy)
          DeviceActivityCenterUtil.removeScheduleTimerActivities(for: activity)
        }
      } catch {
        // Database error occurred - do NOT delete the schedule since we don't know the true state
        Log.info(
          "Error fetching profile \(rawValue): \(error.localizedDescription). Skipping cleanup for safety.",
          category: .strategy)
      }
    }
  }

  func resetBlockingState(context: ModelContext) {
    guard !isBlocking else {
      Log.info("Cannot reset blocking state while a profile is active", category: .strategy)
      return
    }

    Log.info("Resetting blocking state...", category: .strategy)

    // Clean up ghost schedules
    cleanUpGhostSchedules(context: context)

    // Clear all restrictions
    appBlocker.deactivateRestrictions()

    // Remove all break timer activities
    DeviceActivityCenterUtil.removeAllBreakTimerActivities()

    // Remove all one more minute activities
    DeviceActivityCenterUtil.removeAllOneMoreMinuteActivities()

    // Remove all strategy timer activities
    DeviceActivityCenterUtil.removeAllStrategyTimerActivities()

    Log.info("Blocking state reset complete", category: .strategy)
  }

  // MARK: - Remote Session Sync

  /// Start a session triggered by remote device
  func startRemoteSession(
    context: ModelContext,
    profileId: UUID,
    sessionId: UUID,
    startTime: Date
  ) {
    guard !processingRemoteChange else { return }
    processingRemoteChange = true

    defer { processingRemoteChange = false }

    do {
      guard let profile = try BlockedProfiles.findProfile(byID: profileId, in: context) else {
        Log.info("Profile not found for remote session", category: .strategy)
        return
      }

      // Check if profile has local app selection
      if profile.needsAppSelection {
        Log.info("Profile needs app selection, cannot start remotely", category: .strategy)
        errorMessage =
          "Profile '\(profile.name)' is active on another device but needs app selection on this device."
        return
      }

      // Activate restrictions
      appBlocker.activateRestrictions(for: BlockedProfiles.getSnapshot(for: profile))

      // Create session with synced startTime
      let activeSession = BlockedProfileSession.createSession(
        in: context,
        withTag: "remote-sync",
        withProfile: profile,
        forceStart: true,
        startTime: startTime
      )

      // Converge on the single activation path so remote-started sessions get the same
      // side effects as local starts. syncSessionStart is suppressed while processingRemoteChange
      // is true, so this does not echo a session record back to CloudKit (#204).
      activateSession(activeSession, context: context)

      Log.info(
        "Started remote session for profile '\(profile.name)' with synced startTime",
        category: .strategy)
    } catch {
      Log.info("Error starting remote session - \(error)", category: .strategy)
    }
  }

  /// Stop a session triggered by remote device
  func stopRemoteSession(context: ModelContext, profileId: UUID) {
    guard !processingRemoteChange else { return }
    processingRemoteChange = true

    defer { processingRemoteChange = false }

    guard let session = activeSession,
      session.blockedProfile.id == profileId
    else {
      Log.info("No matching active session to stop", category: .strategy)
      return
    }

    // Stop using manual strategy (bypasses NFC/QR requirements)
    let manualStrategy = getStrategy(id: ManualBlockingStrategy.id)
    _ = manualStrategy.stopBlocking(context: context, session: session)

    Log.info("Stopped session via remote trigger", category: .strategy)
  }
}

// MARK: - SessionController Conformance

extension StrategyManager: SessionController {}

// MARK: - Remote Session Notification Names

extension Notification.Name {
  static let remoteSessionStartRequested = Notification.Name("remoteSessionStartRequested")
  static let remoteSessionStopRequested = Notification.Name("remoteSessionStopRequested")
}
