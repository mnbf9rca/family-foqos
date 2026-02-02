import SwiftData
import SwiftUI
import WidgetKit

class StrategyManager: ObservableObject {
  static var shared = StrategyManager()

  private let appModeManager = AppModeManager.shared
  private let lockCodeManager = LockCodeManager.shared
  private let locationManager = LocationManager.shared

  static let availableStrategies: [BlockingStrategy] = [
    ManualBlockingStrategy(),
    NFCBlockingStrategy(),
    NFCManualBlockingStrategy(),
    NFCTimerBlockingStrategy(),
    QRCodeBlockingStrategy(),
    QRManualBlockingStrategy(),
    QRTimerBlockingStrategy(),
    ShortcutTimerBlockingStrategy(),
  ]

  @Published var elapsedTime: TimeInterval = 0
  @Published var timer: Timer?
  @Published var activeSession: BlockedProfileSession?

  @Published var showCustomStrategyView: Bool = false
  @Published var customStrategyView: (any View)? = nil

  @Published var errorMessage: String?
  @Published var isCheckingGeofence: Bool = false

  // Geofence start warning state
  @AppStorage("warnWhenActivatingAwayFromLocation") private var warnWhenActivatingAwayFromLocation =
    true
  @Published var showGeofenceStartWarning: Bool = false
  @Published var pendingStartProfile: BlockedProfiles? = nil
  @Published var pendingStartContext: ModelContext? = nil
  @Published var geofenceWarningMessage: String = ""

  @AppStorage("emergencyUnblocksRemaining") private var emergencyUnblocksRemaining: Int = 3
  @AppStorage("emergencyUnblocksResetPeriodInWeeks") private
    var emergencyUnblocksResetPeriodInWeeks: Int = 4
  @AppStorage("lastEmergencyUnblocksResetDate") private var lastEmergencyUnblocksResetDateTimestamp:
    Double = 0

  private let liveActivityManager = LiveActivityManager.shared
  private let profileSyncManager = ProfileSyncManager.shared

  private let timersUtil = TimersUtil()
  private let appBlocker = AppBlockerUtil()

  // Track if we're currently processing a remote session change
  private var processingRemoteChange = false

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
    return activeSession?.isOneMoreMinuteActive == true
  }

  var isOneMoreMinuteAvailable: Bool {
    return activeSession?.isOneMoreMinuteAvailable ?? false
  }

  @Published var oneMoreMinuteTimeRemaining: TimeInterval = 0
  private var oneMoreMinuteTimer: Timer?

  func defaultReminderMessage(forProfile profile: BlockedProfiles?) -> String {
    let baseMessage = "Get back to productivity"
    guard let profile else {
      return baseMessage
    }
    return baseMessage + " by enabling \(profile.name)"
  }

  func loadActiveSession(context: ModelContext) {
    activeSession = getActiveSession(context: context)

    if activeSession?.isActive == true {
      startTimer()

      // Start live activity for existing session if one exists
      // live activities can only be started when the app is in the foreground
      if let session = activeSession {
        liveActivityManager.startSessionActivity(session: session)
      }
    } else {
      // Close live activity if no session is active and a scheduled session might have ended
      liveActivityManager.endSessionActivity()
    }
  }

  func toggleBlocking(context: ModelContext, activeProfile: BlockedProfiles?) {
    if isBlocking {
      // Check if the active profile is managed and requires unlock
      if let session = activeSession,
        session.blockedProfile.isManaged,
        appModeManager.currentMode == .child,
        !lockCodeManager.isUnlocked(session.blockedProfile.id)
      {
        Log.info("Manual stop blocked: Managed profile requires lock code", category: .strategy)
        errorMessage = "This profile is parent-controlled. Enter the lock code to stop blocking."
        return
      }

      // Check geofence rule if one exists
      if let session = activeSession,
        let geofenceRule = session.blockedProfile.geofenceRule,
        geofenceRule.hasLocations
      {
        checkGeofenceAndStop(context: context, rule: geofenceRule)
        return
      }

      stopBlocking(context: context)
    } else {
      checkGeofenceAndStart(context: context, activeProfile: activeProfile)
    }
  }

  /// Check geofence rule and stop blocking if satisfied
  private func checkGeofenceAndStop(context: ModelContext, rule: ProfileGeofenceRule) {
    // Request permission if not determined
    if locationManager.isNotDetermined {
      locationManager.requestAuthorization()
      errorMessage = "Please allow location access to stop this profile, then try again."
      return
    }

    // Check if permission is denied
    if locationManager.isDenied {
      errorMessage =
        "Location access is denied. Enable location services in Settings to use location-based restrictions."
      return
    }

    isCheckingGeofence = true

    // Capture saved locations before entering the Task to avoid Sendable warnings
    let ruleToCheck = rule
    let savedLocationsSnapshot: [SavedLocation]
    do {
      savedLocationsSnapshot = try SavedLocation.fetchAll(in: context)
    } catch {
      self.isCheckingGeofence = false
      self.errorMessage = "Unable to load saved locations. Please try again."
      return
    }

    Task { @MainActor in
      let result = await locationManager.checkGeofenceRule(
        rule: ruleToCheck,
        savedLocations: savedLocationsSnapshot
      )

      self.isCheckingGeofence = false

      if result.isSatisfied {
        self.stopBlocking(context: context)
      } else {
        self.errorMessage = result.failureMessage ?? "Location restriction not met."
      }
    }
  }

  /// Check geofence rule before starting and show warning if user is not at location
  private func checkGeofenceAndStart(context: ModelContext, activeProfile: BlockedProfiles?) {
    guard let profile = activeProfile else {
      startBlocking(context: context, activeProfile: activeProfile)
      return
    }

    // Fast path: if setting is off, skip check
    guard warnWhenActivatingAwayFromLocation else {
      startBlocking(context: context, activeProfile: profile)
      return
    }

    // Fast path: if profile has no geofence rule, skip check
    guard let geofenceRule = profile.geofenceRule, geofenceRule.hasLocations else {
      startBlocking(context: context, activeProfile: profile)
      return
    }

    // If location permission not granted, proceed without warning (don't block activation)
    if locationManager.isNotDetermined || locationManager.isDenied {
      startBlocking(context: context, activeProfile: profile)
      return
    }

    isCheckingGeofence = true

    // Capture saved locations before entering the Task to avoid Sendable warnings
    let ruleToCheck = geofenceRule
    let savedLocationsSnapshot: [SavedLocation]
    do {
      savedLocationsSnapshot = try SavedLocation.fetchAll(in: context)
    } catch {
      self.isCheckingGeofence = false
      self.errorMessage = "Unable to load saved locations. Please try again."
      return
    }

    Task { @MainActor in
      let result = await locationManager.checkGeofenceRule(
        rule: ruleToCheck,
        savedLocations: savedLocationsSnapshot
      )

      self.isCheckingGeofence = false

      if result.isSatisfied {
        // User is at location, proceed without warning
        self.startBlocking(context: context, activeProfile: profile)
      } else {
        // User is NOT at location, show warning
        self.pendingStartProfile = profile
        self.pendingStartContext = context
        self.geofenceWarningMessage = self.buildStartWarningMessage(
          rule: ruleToCheck,
          savedLocations: savedLocationsSnapshot
        )
        self.showGeofenceStartWarning = true
      }
    }
  }

  /// Build user-friendly warning message for starting away from location
  private func buildStartWarningMessage(
    rule: ProfileGeofenceRule,
    savedLocations: [SavedLocation]
  ) -> String {
    let locationNames = rule.locationReferences.compactMap { ref in
      savedLocations.first { $0.id == ref.savedLocationId }?.name
    }

    if locationNames.isEmpty {
      return
        "This profile has location restrictions. You won't be able to stop it until you're at the required location."
    } else if locationNames.count == 1 {
      return
        "This profile can only be stopped at \"\(locationNames[0])\". You're not currently at that location."
    } else {
      let locationList = locationNames.joined(separator: ", ")
      return
        "This profile can only be stopped at one of these locations: \(locationList). You're not currently at any of them."
    }
  }

  /// Called when user confirms starting despite geofence warning
  func confirmGeofenceStart() {
    guard let profile = pendingStartProfile, let context = pendingStartContext else {
      cancelGeofenceStart()
      return
    }

    startBlocking(context: context, activeProfile: profile)
    cancelGeofenceStart()
  }

  /// Called when user cancels starting due to geofence warning
  func cancelGeofenceStart() {
    pendingStartProfile = nil
    pendingStartContext = nil
    geofenceWarningMessage = ""
    showGeofenceStartWarning = false
  }

  /// Check if the current blocking session can be stopped (for managed profiles)
  /// Note: This is a synchronous check and doesn't verify geofence rules
  func canStopBlocking() -> Bool {
    guard let session = activeSession else { return true }

    // If it's a managed profile on a child device, check if unlocked
    if session.blockedProfile.isManaged && appModeManager.currentMode == .child {
      return lockCodeManager.isUnlocked(session.blockedProfile.id)
    }

    return true
  }

  /// Check if the profile has geofence restrictions
  func hasGeofenceRestrictions() -> Bool {
    guard let session = activeSession else { return false }
    return session.blockedProfile.geofenceRule?.hasLocations == true
  }

  /// Get the reason why stopping is blocked
  func getStopBlockedReason() -> String? {
    guard let session = activeSession else { return nil }

    if session.blockedProfile.isManaged && appModeManager.currentMode == .child
      && !lockCodeManager.isUnlocked(session.blockedProfile.id)
    {
      return "This profile is parent-controlled. Enter the lock code to stop blocking."
    }

    if session.blockedProfile.geofenceRule?.hasLocations == true {
      return "This profile has location restrictions. You must be at the required location to stop."
    }

    return nil
  }

  func toggleBreak(context: ModelContext) {
    guard let session = activeSession else {
      Log.info("active session does not exist", category: .strategy)
      return
    }

    if session.isBreakActive {
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

    if !session.isOneMoreMinuteAvailable {
      Log.info("One more minute already used this session", category: .strategy)
      return
    }

    // Mark as used
    session.startOneMoreMinute()

    // LIFT RESTRICTIONS - user can now use blocked apps
    appBlocker.deactivateRestrictions()

    // Start 60-second countdown
    oneMoreMinuteTimeRemaining = 60
    startOneMoreMinuteTimer()

    // Update live activity
    liveActivityManager.updateOneMoreMinuteState(
      session: session, timeRemaining: oneMoreMinuteTimeRemaining)

    // Refresh widgets
    WidgetCenter.shared.reloadTimelines(ofKind: "ProfileControlWidget")

    Log.info("Started one more minute - restrictions lifted for 60s", category: .strategy)
  }

  private func endOneMoreMinute() {
    stopOneMoreMinuteTimer()
    oneMoreMinuteTimeRemaining = 0

    // RE-ACTIVATE RESTRICTIONS
    if let session = activeSession {
      appBlocker.activateRestrictions(for: BlockedProfiles.getSnapshot(for: session.blockedProfile))
      liveActivityManager.updateOneMoreMinuteState(session: session, timeRemaining: 0)
    }

    WidgetCenter.shared.reloadTimelines(ofKind: "ProfileControlWidget")
  }

  private func startOneMoreMinuteTimer() {
    stopOneMoreMinuteTimer()

    oneMoreMinuteTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      guard let self = self else { return }

      guard let session = self.activeSession,
        let startTime = session.oneMoreMinuteStartTime
      else {
        self.endOneMoreMinute()
        Log.info("One more minute ended - no session or start time", category: .strategy)
        return
      }

      let elapsed = Date().timeIntervalSince(startTime)
      let remaining = max(0, 60 - elapsed)
      self.oneMoreMinuteTimeRemaining = remaining

      self.liveActivityManager.updateOneMoreMinuteState(
        session: session, timeRemaining: self.oneMoreMinuteTimeRemaining)

      if remaining <= 0 {
        self.endOneMoreMinute()
        Log.info("One more minute ended - restrictions re-activated", category: .strategy)
      }
    }
  }

  private func stopOneMoreMinuteTimer() {
    oneMoreMinuteTimer?.invalidate()
    oneMoreMinuteTimer = nil
  }

  /// Resume the One More Minute timer if it was active when app went to background
  /// Call this when app returns to foreground
  func resumeOneMoreMinuteIfNeeded() {
    guard let session = activeSession,
      let startTime = session.oneMoreMinuteStartTime
    else {
      return
    }

    let elapsed = Date().timeIntervalSince(startTime)
    let remaining = max(0, 60 - elapsed)

    if remaining > 0 {
      // Time still remaining - restart the timer
      oneMoreMinuteTimeRemaining = remaining
      startOneMoreMinuteTimer()
      Log.info("Resumed one more minute timer with \(Int(remaining))s remaining", category: .strategy)
    } else {
      // Time expired while in background - end it now
      endOneMoreMinute()
      Log.info("One more minute expired while in background", category: .strategy)
    }
  }

  func startTimer() {
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
      guard let session = self.activeSession else { return }

      if session.isBreakActive {
        // Calculate break time remaining (countdown)
        guard let breakStartTime = session.breakStartTime else { return }
        let timeSinceBreakStart = Date().timeIntervalSince(breakStartTime)
        let breakDurationInSeconds = TimeInterval(session.blockedProfile.breakTimeInMinutes * 60)
        self.elapsedTime = max(0, breakDurationInSeconds - timeSinceBreakStart)
      } else {
        // Calculate session elapsed time
        let rawElapsedTime = Date().timeIntervalSince(session.startTime)
        let breakDuration = self.calculateBreakDuration()
        self.elapsedTime = rawElapsedTime - breakDuration
      }
    }
  }

  func stopTimer() {
    timer?.invalidate()
    timer = nil
    stopOneMoreMinuteTimer()
  }

  private func calculateBreakDuration() -> TimeInterval {
    guard let session = activeSession else {
      return 0
    }

    guard let breakStartTime = session.breakStartTime else {
      return 0
    }

    if let breakEndTime = session.breakEndTime {
      return breakEndTime.timeIntervalSince(breakStartTime)
    }

    return 0
  }

  func toggleSessionFromDeeplink(
    _ profileId: String,
    url: URL,
    context: ModelContext
  ) {
    guard let profileUUID = UUID(uuidString: profileId) else {
      self.errorMessage = "failed to parse profile in tag"
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
          "Failed to find a profile stored locally that matches the tag"
        return
      }

      let manualStrategy = getStrategy(id: ManualBlockingStrategy.id)

      if let localActiveSession = getActiveSession(context: context) {
        if localActiveSession.blockedProfile.disableBackgroundStops {
          Log.info("profile: \(localActiveSession.blockedProfile.name) has disable background stops enabled, not stopping it", category: .strategy)
          self.errorMessage =
            "profile: \(localActiveSession.blockedProfile.name) has disable background stops enabled, not stopping it"
          return
        }

        _ =
          manualStrategy
          .stopBlocking(
            context: context,
            session: localActiveSession
          )

        if localActiveSession.blockedProfile.id != profile.id {
          Log.info("User is switching sessions from deep link", category: .strategy)

          _ = manualStrategy.startBlocking(
            context: context,
            profile: profile,
            forceStart: true
          )
        }
      } else {
        _ = manualStrategy.startBlocking(
          context: context,
          profile: profile,
          forceStart: true
        )
      }
    } catch {
      self.errorMessage = "Something went wrong fetching profile"
    }
  }

  func startSessionFromBackground(
    _ profileId: UUID,
    context: ModelContext,
    durationInMinutes: Int? = nil
  ) {
    do {
      guard
        let profile = try BlockedProfiles.findProfile(
          byID: profileId,
          in: context
        )
      else {
        self.errorMessage =
          "Failed to find a profile stored locally that matches the tag"
        return
      }

      if let localActiveSession = getActiveSession(context: context) {
        Log.info("session is already active for profile: \(localActiveSession.blockedProfile.name), not starting a new one", category: .strategy)
        return
      }

      if let duration = durationInMinutes {
        if duration < 15 || duration > 1440 {
          self.errorMessage = "Duration must be between 15 and 1440 minutes"
          return
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
    } catch {
      self.errorMessage = "Something went wrong fetching profile"
    }
  }

  func stopSessionFromBackground(
    _ profileId: UUID,
    context: ModelContext
  ) {
    do {
      guard
        let profile = try BlockedProfiles.findProfile(
          byID: profileId,
          in: context
        )
      else {
        self.errorMessage =
          "Failed to find a profile stored locally that matches the tag"
        return
      }

      let manualStrategy = getStrategy(id: ManualBlockingStrategy.id)

      guard let localActiveSession = getActiveSession(context: context) else {
        Log.info("session is not active for profile: \(profile.name), not stopping it", category: .strategy)
        return
      }

      if localActiveSession.blockedProfile.id != profile.id {
        Log.info("session is not active for profile: \(profile.name), not stopping it", category: .strategy)
        self.errorMessage =
          "session is not active for profile: \(profile.name), not stopping it"
        return
      }

      if profile.disableBackgroundStops {
        Log.info("profile: \(profile.name) has disable background stops enabled, not stopping it", category: .strategy)
        self.errorMessage =
          "profile: \(profile.name) has disable background stops enabled, not stopping it"
        return
      }

      let _ = manualStrategy.stopBlocking(
        context: context,
        session: localActiveSession
      )
    } catch {
      self.errorMessage = "Something went wrong fetching profile"
    }
  }

  func getRemainingEmergencyUnblocks() -> Int {
    return emergencyUnblocksRemaining
  }

  func emergencyUnblock(context: ModelContext) {
    // Do not allow emergency unblocks if there are no remaining
    if emergencyUnblocksRemaining == 0 {
      return
    }

    // Do not allow emergency unblocks if there is no active session
    guard let activeSession = getActiveSession(context: context) else {
      return
    }

    // Check if the active profile is managed and requires unlock
    if activeSession.blockedProfile.isManaged,
      appModeManager.currentMode == .child,
      !lockCodeManager.isUnlocked(activeSession.blockedProfile.id)
    {
      Log.info("Emergency unblock blocked: Managed profile requires lock code", category: .strategy)
      errorMessage =
        "This profile is parent-controlled. Enter the lock code to use emergency unblock."
      return
    }

    // Check geofence rule if one exists and emergency override is not allowed
    if let geofenceRule = activeSession.blockedProfile.geofenceRule,
      geofenceRule.hasLocations,
      !geofenceRule.allowEmergencyOverride
    {
      checkGeofenceAndEmergencyUnblock(context: context, rule: geofenceRule, session: activeSession)
      return
    }

    performEmergencyUnblock(context: context, session: activeSession)
  }

  /// Check geofence rule and perform emergency unblock if satisfied
  private func checkGeofenceAndEmergencyUnblock(
    context: ModelContext,
    rule: ProfileGeofenceRule,
    session: BlockedProfileSession
  ) {
    // Request permission if not determined
    if locationManager.isNotDetermined {
      locationManager.requestAuthorization()
      errorMessage = "Please allow location access to use emergency unblock, then try again."
      return
    }

    // Check if permission is denied
    if locationManager.isDenied {
      errorMessage =
        "Location access is denied. Enable location services in Settings to use emergency unblock."
      return
    }

    isCheckingGeofence = true

    // Capture saved locations before entering the Task to avoid Sendable warnings
    let ruleToCheck = rule
    let savedLocationsSnapshot: [SavedLocation]
    do {
      savedLocationsSnapshot = try SavedLocation.fetchAll(in: context)
    } catch {
      self.isCheckingGeofence = false
      self.errorMessage = "Unable to load saved locations. Please try again."
      return
    }

    Task { @MainActor in
      let result = await locationManager.checkGeofenceRule(
        rule: ruleToCheck,
        savedLocations: savedLocationsSnapshot
      )

      self.isCheckingGeofence = false

      if result.isSatisfied {
        self.performEmergencyUnblock(context: context, session: session)
      } else {
        self.errorMessage = result.failureMessage ?? "Location restriction not met."
      }
    }
  }

  /// Actually perform the emergency unblock (called after all checks pass)
  private func performEmergencyUnblock(context: ModelContext, session: BlockedProfileSession) {
    // Stop the active session using the manual strategy, bypasses any other strategy in view
    let manualStrategy = getStrategy(id: ManualBlockingStrategy.id)
    _ = manualStrategy.stopBlocking(
      context: context,
      session: session
    )

    // Do end sections for the profile
    self.liveActivityManager.endSessionActivity()
    self.scheduleReminder(profile: session.blockedProfile)
    self.stopTimer()

    // Decrement the remaining emergency unblocks
    emergencyUnblocksRemaining -= 1

    // Refresh widgets when emergency unblock ends session
    WidgetCenter.shared.reloadTimelines(ofKind: "ProfileControlWidget")
  }

  func resetEmergencyUnblocks() {
    emergencyUnblocksRemaining = 3
    lastEmergencyUnblocksResetDateTimestamp = Date().timeIntervalSinceReferenceDate
  }

  func checkAndResetEmergencyUnblocks() {
    // Initialize the last reset date if it hasn't been set
    if lastEmergencyUnblocksResetDateTimestamp == 0 {
      lastEmergencyUnblocksResetDateTimestamp = Date().timeIntervalSinceReferenceDate
      return
    }

    let lastResetDate = Date(
      timeIntervalSinceReferenceDate: lastEmergencyUnblocksResetDateTimestamp)
    let weeksInSeconds: TimeInterval = TimeInterval(
      emergencyUnblocksResetPeriodInWeeks * 7 * 24 * 60 * 60)
    let elapsedTime = Date().timeIntervalSince(lastResetDate)

    // Check if the reset period has elapsed
    if elapsedTime >= weeksInSeconds {
      emergencyUnblocksRemaining = 3
      lastEmergencyUnblocksResetDateTimestamp = Date().timeIntervalSinceReferenceDate
    }
  }

  func getNextResetDate() -> Date? {
    guard lastEmergencyUnblocksResetDateTimestamp > 0 else {
      return nil
    }

    let lastResetDate = Date(
      timeIntervalSinceReferenceDate: lastEmergencyUnblocksResetDateTimestamp)
    let calendar = Calendar.current
    return calendar.date(
      byAdding: .weekOfYear,
      value: emergencyUnblocksResetPeriodInWeeks,
      to: lastResetDate
    )
  }

  func getResetPeriodInWeeks() -> Int {
    return emergencyUnblocksResetPeriodInWeeks
  }

  func setResetPeriodInWeeks(_ weeks: Int) {
    emergencyUnblocksResetPeriodInWeeks = weeks
    lastEmergencyUnblocksResetDateTimestamp = Date().timeIntervalSinceReferenceDate
  }

  static func getStrategyFromId(id: String) -> BlockingStrategy {
    if let strategy = availableStrategies.first(
      where: {
        $0.getIdentifier() == id
      })
    {
      return strategy
    } else {
      return NFCBlockingStrategy()
    }
  }

  func getStrategy(id: String) -> BlockingStrategy {
    var strategy = StrategyManager.getStrategyFromId(id: id)

    strategy.onSessionCreation = { session in
      self.dismissView()

      // Remove any timers and notifications that were scheduled
      self.timersUtil.cancelAll()

      switch session {
      case .started(let session):
        // Update the snapshot of the profile in case some settings were changed
        BlockedProfiles.updateSnapshot(for: session.blockedProfile)

        self.errorMessage = nil

        self.activeSession = session
        self.startTimer()
        self.liveActivityManager
          .startSessionActivity(session: session)

        // Refresh widgets when session starts
        WidgetCenter.shared.reloadTimelines(ofKind: "ProfileControlWidget")

        // Sync session start using CAS (if global sync is enabled)
        if self.shouldSyncSessionChange {
          Task {
            let result = await SessionSyncService.shared.startSession(
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
              if let remoteStartTime = existing.startTime,
                let currentSession = self.activeSession,
                currentSession.startTime != remoteStartTime
              {
                currentSession.startTime = remoteStartTime
                Log.info("Reconciled local startTime to \(remoteStartTime)", category: .strategy)
              }
            case .error(let error):
              Log.info("Failed to sync session start - \(error)", category: .strategy)
            }
          }
        }
      case .ended(let endedProfile):
        self.activeSession = nil
        self.liveActivityManager.endSessionActivity()
        self.scheduleReminder(profile: endedProfile)

        self.stopTimer()
        self.elapsedTime = 0

        // Refresh widgets when session ends
        WidgetCenter.shared.reloadTimelines(ofKind: "ProfileControlWidget")

        // Remove all break timer activities
        DeviceActivityCenterUtil.removeAllBreakTimerActivities()

        // Remove all strategy timer activities
        DeviceActivityCenterUtil.removeAllStrategyTimerActivities()

        // Sync session stop using CAS (if global sync is enabled)
        if self.shouldSyncSessionChange {
          Task {
            let result = await SessionSyncService.shared.stopSession(
              profileId: endedProfile.id
            )

            switch result {
            case .stopped(let seq):
              Log.info("Session stop synced with seq=\(seq)", category: .strategy)
            case .alreadyStopped:
              Log.info("Session was already stopped", category: .strategy)
            case .conflict(let current):
              Log.info("Stop conflict, current seq=\(current.sequenceNumber)", category: .strategy)
              // Retry stop once
              let retryResult = await SessionSyncService.shared.stopSession(
                profileId: endedProfile.id)
              switch retryResult {
              case .stopped(let seq):
                Log.info("Stop retry succeeded with seq=\(seq)", category: .strategy)
              case .alreadyStopped:
                Log.info("Stop retry found session already stopped", category: .strategy)
              case .conflict, .error:
                Log.info("Stop retry failed - \(retryResult)", category: .strategy)
              }
            case .error(let error):
              Log.info("Failed to sync session stop - \(error)", category: .strategy)
            }
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

    if !session.isBreakAvailable {
      Log.info("Breaks is not available", category: .strategy)
      return
    }

    // Start the break timer activity
    DeviceActivityCenterUtil.startBreakTimerActivity(for: session.blockedProfile)

    // Schedule a reminder to get back to the profile after the break
    scheduleBreakReminder(profile: session.blockedProfile)

    // Refresh widgets when break starts
    WidgetCenter.shared.reloadTimelines(ofKind: "ProfileControlWidget")

    // Load the active session since the break start time was set in a different thread
    loadActiveSession(context: context)

    // Update live activity to show break state
    liveActivityManager.updateBreakState(session: session)
  }

  private func stopBreak(context: ModelContext) {
    guard let session = activeSession else {
      Log.info("Breaks only available in active session", category: .strategy)
      return
    }

    if !session.isBreakAvailable {
      Log.info("Breaks is not available", category: .strategy)
      return
    }

    // Remove the break timer activity
    DeviceActivityCenterUtil.removeBreakTimerActivity(for: session.blockedProfile)

    // Cancel all notifications that were scheduled during break
    timersUtil.cancelAllNotifications()

    // Refresh widgets when break ends
    WidgetCenter.shared.reloadTimelines(ofKind: "ProfileControlWidget")

    // Load the active session since the break end time was set in a different thread
    loadActiveSession(context: context)

    // Update live activity to show break has ended
    liveActivityManager.updateBreakState(session: session)
  }

  private func dismissView() {
    showCustomStrategyView = false
    customStrategyView = nil
  }

  private func getActiveSession(context: ModelContext)
    -> BlockedProfileSession?
  {
    // Before fetching the active session, sync any schedule sessions
    syncScheduleSessions(context: context)

    return
      BlockedProfileSession
      .mostRecentActiveSession(in: context)
  }

  private func syncScheduleSessions(context: ModelContext) {
    // Process any active scheduled sessions
    if let activeScheduledSession = SharedData.getActiveSharedSession() {
      BlockedProfileSession.upsertSessionFromSnapshot(
        in: context,
        withSnapshot: activeScheduledSession
      )

      // Sync scheduled session start using CAS (if global sync is enabled)
      // This ensures multi-device coordination for scheduled profile activations
      if profileSyncManager.isEnabled {
        Task {
          let result = await SessionSyncService.shared.startSession(
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
              Log.info("Reconciled scheduled session startTime to \(remoteStartTime)", category: .strategy)
            }
          case .error(let error):
            Log.info("Failed to sync scheduled session - \(error)", category: .strategy)
          }
        }
      }
    }

    // Process any completed scheduled sessions
    let completedScheduleSessions = SharedData.getCompletedSessionsForSchedular()
    for completedScheduleSession in completedScheduleSessions {
      BlockedProfileSession.upsertSessionFromSnapshot(
        in: context,
        withSnapshot: completedScheduleSession
      )

      // Sync scheduled session end using CAS (if global sync is enabled)
      if profileSyncManager.isEnabled, let endTime = completedScheduleSession.endTime {
        Task {
          let result = await SessionSyncService.shared.stopSession(
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

    // Flush completed scheduled sessions
    SharedData.flushCompletedSessionsForSchedular()
  }

  private func resultFromURL(_ url: String) -> NFCResult {
    return NFCResult(id: url, url: url, DateScanned: Date())
  }

  private func startBlocking(
    context: ModelContext,
    activeProfile: BlockedProfiles?
  ) {
    guard let definedProfile = activeProfile else {
      Log.info("No active profile found, calling stop blocking with no session", category: .strategy)
      return
    }

    if let strategyId = definedProfile.blockingStrategyId {
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

  private func stopBlocking(context: ModelContext) {
    guard let session = activeSession else {
      Log.info("No active session found, calling stop blocking with no session", category: .strategy)
      return
    }

    if let strategyId = session.blockedProfile.blockingStrategyId {
      let strategy = getStrategy(id: strategyId)
      let view = strategy.stopBlocking(context: context, session: session)

      if let customView = view {
        showCustomStrategyView = true
        customStrategyView = customView
      }
    }
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
    let profileName = profile.name

    // Schedule a reminder to let the user know that the break is about to end
    let breakNotificationTimeInSeconds = UInt32((profile.breakTimeInMinutes - 1) * 60)
    if breakNotificationTimeInSeconds > 0 {
      timersUtil.scheduleNotification(
        title: "Break almost over!",
        message: "Hope you enjoyed your break, starting " + profileName + " in a 1 minute.",
        seconds: TimeInterval(breakNotificationTimeInSeconds)
      )
    }
  }

  func cleanUpGhostSchedules(context: ModelContext) {
    let allActivities = DeviceActivityCenterUtil.getDeviceActivities()
    let scheduleTimerActivity = ScheduleTimerActivity()
    let scheduleActivities = scheduleTimerActivity.getAllScheduleTimerActivities(
      from: allActivities)

    Log.info("Found \(scheduleActivities.count) schedule timer activities out of \(allActivities.count) total activities", category: .strategy)

    for activity in scheduleActivities {
      let rawValue = activity.rawValue
      guard let profileId = UUID(uuidString: rawValue) else {
        // This shouldn't happen since we filtered above, but print just in case
        Log.info("Unexpected: failed to parse profile id from filtered activity: \(rawValue)", category: .strategy)
        continue
      }

      do {
        if let profile = try BlockedProfiles.findProfile(byID: profileId, in: context) {
          if profile.schedule == nil {
            Log.info("Profile '\(profile.name)' has no schedule but has device activity registered. Removing ghost schedule...", category: .strategy)
            DeviceActivityCenterUtil.removeScheduleTimerActivities(for: profile)
          } else {
            Log.info("Profile '\(profile.name)' has schedule - activity is valid ✅", category: .strategy)
          }
        } else {
          // Profile truly doesn't exist in database
          Log.info("No profile found for activity \(rawValue). Removing orphaned schedule...", category: .strategy)
          DeviceActivityCenterUtil.removeScheduleTimerActivities(for: activity)
        }
      } catch {
        // Database error occurred - do NOT delete the schedule since we don't know the true state
        Log.info("Error fetching profile \(rawValue): \(error.localizedDescription). Skipping cleanup for safety.", category: .strategy)
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

    // Remove all strategy timer activities
    DeviceActivityCenterUtil.removeAllStrategyTimerActivities()

    Log.info("Blocking state reset complete", category: .strategy)
  }

  // MARK: - Remote Session Sync

  /// Set up observers for remote session changes from other devices.
  /// Note: Session sync is now handled directly by SyncCoordinator which calls
  /// startRemoteSession/stopRemoteSession methods. This method is kept for future
  /// extensibility but no longer observes .syncedSessionsReceived.
  func setupRemoteSessionObservers() {
    // SyncCoordinator now handles session sync directly by calling
    // startRemoteSession() and stopRemoteSession() methods.
    // No notification observers needed here.
  }

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
        errorMessage = "Profile '\(profile.name)' is active on another device but needs app selection on this device."
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

      // Set as active session
      self.activeSession = activeSession

      Log.info("Started remote session for profile '\(profile.name)' with synced startTime", category: .strategy)
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

// MARK: - Remote Session Notification Names

extension Notification.Name {
  static let remoteSessionStartRequested = Notification.Name("remoteSessionStartRequested")
  static let remoteSessionStopRequested = Notification.Name("remoteSessionStopRequested")
}
