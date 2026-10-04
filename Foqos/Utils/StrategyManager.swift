import DeviceActivity
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
  private let remoteActiveDefaults: UserDefaults
  private let ratingManager: RatingManager

  /// #201: persisted intents for session-stops dropped by a failed/exhausted CAS write.
  /// Internal (not private) so Phase-E tests can assert routing without a live CloudKit call.
  let sessionStopOutbox = SessionStopOutbox()

  @Published var elapsedTime: TimeInterval = 0
  @Published var timerTask: Task<Void, Never>?
  @Published var activeSession: BlockedProfileSession?
  @Published private(set) var remotelyActiveProfileIds: Set<UUID>

  @Published var showCustomStrategyView: Bool = false
  @Published var customStrategyView: (any View)? = nil

  @Published var errorMessage: String?

  private let timersUtil: TimersUtilScheduling
  private let appBlocker: RestrictionApplying
  private let backstopRegistrar: BackstopRegistering
  private let registerTimer: (UUID, String, Int, Date) throws -> Date
  private let startSessionActivity: (BlockedProfileSession) -> Void
  private let cancelPreActivationReminders: (UUID) -> Void
  private let removeAllStrategyTimers: () -> Void
  private let cancelTimer: (UUID, String) -> Void
  private let saveSession: (ModelContext) throws -> Void
  private let scheduleReconciler: @MainActor (ModelContext) -> Void

  init(
    geofenceEvaluator: GeofenceEvaluator = .shared,
    emergencyUnblockManager: EmergencyUnblockManager = .shared,
    liveActivityManager: LiveActivityManager = .shared,
    profileSyncManager: ProfileSyncManager = .shared,
    sessionSyncService: SessionSyncService = .shared,
    locationManager: LocationManager = .shared,
    appBlocker: RestrictionApplying = AppBlockerUtil(),
    backstopRegistrar: BackstopRegistering = DeviceActivityBackstopRegistrar(),
    timersUtil: TimersUtilScheduling = TimersUtil(),
    remoteActiveDefaults: UserDefaults = .standard,
    registerTimer: @escaping (UUID, String, Int, Date) throws -> Date = DeviceActivityCenterUtil.registerStrategyTimer,
    cancelTimer: @escaping (UUID, String) -> Void = DeviceActivityCenterUtil.removeStrategyTimerActivity,
    startSessionActivity: ((BlockedProfileSession) -> Void)? = nil,
    cancelPreActivationReminders: @escaping (UUID) -> Void = TimersUtil.cancelAllPreActivationReminders,
    removeAllStrategyTimers: @escaping () -> Void = DeviceActivityCenterUtil.removeAllStrategyTimerActivities,
    saveSession: @escaping (ModelContext) throws -> Void = { try $0.save() },
    scheduleReconciler: @escaping @MainActor (ModelContext) -> Void = {
      PreActivationReminderScheduler.reconcileScheduleRegistrations(context: $0)
    },
    ratingManager: RatingManager = .shared
  ) {
    self.ratingManager = ratingManager
    self.geofenceEvaluator = geofenceEvaluator
    self.emergencyUnblockManager = emergencyUnblockManager
    self.liveActivityManager = liveActivityManager
    self.profileSyncManager = profileSyncManager
    self.sessionSyncService = sessionSyncService
    self.locationManager = locationManager
    self.remoteActiveDefaults = remoteActiveDefaults
    self.appBlocker = appBlocker
    self.backstopRegistrar = backstopRegistrar
    self.timersUtil = timersUtil
    self.registerTimer = registerTimer
    self.cancelTimer = cancelTimer
    self.startSessionActivity = startSessionActivity ?? { liveActivityManager.startSessionActivity(session: $0) }
    self.cancelPreActivationReminders = cancelPreActivationReminders
    self.removeAllStrategyTimers = removeAllStrategyTimers
    self.saveSession = saveSession
    self.scheduleReconciler = scheduleReconciler
    self.remotelyActiveProfileIds = RemotelyActiveStore.load(defaults: remoteActiveDefaults)
  }

  /// A V2 originating start registers its countdown before constructing any session.
  func startOriginatingSession(
    context: ModelContext, profile: BlockedProfiles, origin: SessionOrigin,
    durationOverrideMinutes: Int? = nil, now: Date = Date(), expectedVictimId: String? = nil, allowLinkForTag: Bool = false
  ) throws -> BlockedProfileSession {
    try prepareProfileForStart(profile, context: context)
    let snapshot = BlockedProfiles.getSnapshot(for: profile)
    func refusal(_ message: String) -> NSError {
      NSError(domain: "ProfileStart", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    if let message = ProfileConditionValidation.startRejection(for: snapshot, origin: origin, allowLinkForTag: allowLinkForTag) {
      throw refusal(message)
    }
    guard !profile.needsAppSelection else { throw refusal(needsAppSelectionMessage(for: profile)) }
    if let durationOverrideMinutes {
      guard origin.kind == .manual, snapshot.stopConditions?.allowChangingTimerBeforeStart == true,
        snapshot.stopConditions?.timer == true, snapshot.stopConditions?.timerDurationMinutes != nil,
        (DeviceActivityLimits.minimumIntervalMinutes...DeviceActivityLimits.maximumTimerMinutes).contains(durationOverrideMinutes)
      else { throw refusal("Choose a timer from 15 minutes to 23 hours 59 minutes.") }
    }
    let candidateId = UUID().uuidString
    let minutes = snapshot.stopConditions?.timer == true ? (durationOverrideMinutes ?? snapshot.stopConditions?.timerDurationMinutes) : nil
    var deadline: Date?
    if let minutes {
      do { deadline = try registerTimer(profile.id, candidateId, minutes, now) } catch {
        cancelTimer(profile.id, candidateId)
        throw refusal("This profile couldn’t start because its timer couldn’t be set. Please try again.")
      }
    }
    let candidate = BlockedProfileSession(
      tag: origin.key.map { origin.kind.rawValue + ":" + $0 } ?? origin.kind.rawValue,
      blockedProfile: profile, startTime: now, id: candidateId, origin: origin)
    candidate.timerEndTime = deadline
    context.insert(candidate)
    do {
      try saveSession(context)
      BlockedProfiles.updateSnapshot(for: profile)
      guard
        SharedData.commitOriginatingSession(
          candidate.toSnapshot(), expectedVictimId: expectedVictimId, now: now, allowLinkForTag: allowLinkForTag,
          onCommit: {
            self.appBlocker.activateRestrictions(for: snapshot)
          })
      else { throw refusal("Couldn’t start this profile. Please try again.") }
    } catch {
      profile.sessions.removeAll { $0.id == candidateId }
      context.delete(candidate)
      if minutes != nil { cancelTimer(profile.id, candidateId) }
      do { try saveSession(context) } catch {
        Log.error("Failed to persist originating-session compensation: \(error.localizedDescription)", category: .session)
        throw refusal("Couldn’t start this profile. Please try again.")
      }
      throw refusal("Couldn’t start this profile. Please try again.")
    }
    activateSession(candidate, context: context)
    return candidate
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

  func setRemoteSessionActive(_ isActive: Bool, profileId: UUID) {
    if isActive {
      remotelyActiveProfileIds.insert(profileId)
    } else {
      remotelyActiveProfileIds.remove(profileId)
    }
    RemotelyActiveStore.save(remotelyActiveProfileIds, defaults: remoteActiveDefaults)
  }

  func clearAllRemoteSessionActive() {
    // Event-scoped to account transitions and synced-data wipes. Do not clear on relaunch:
    // remote-active locks must survive until sync provides a newer session state.
    remotelyActiveProfileIds = []
    RemotelyActiveStore.clear(defaults: remoteActiveDefaults)
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
      reconcileGrants(context: context)

      // Start live activity for existing session if one exists
      // live activities can only be started when the app is in the foreground
      if let session = activeSession {
        startSessionActivity(session)

        // Re-register stop schedule on app launch
        let failures = DeviceActivityCenterUtil.scheduleStopActivity(for: session.blockedProfile)
        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
      }
    } else {
      // Close live activity if no session is active and a scheduled session might have ended
      liveActivityManager.endSessionActivity()
      // Re-attempt migration for profiles deferred due to active sessions
      if ProfileMigrationUtil.migrateProfilesIfNeeded(context: context) > 0 {
        scheduleReconciler(context)
      }
    }
  }

  #if DEBUG
    func loadScreenshotDemoSession(context: ModelContext) throws {
      activeSession = try BlockedProfileSession.mostRecentActiveSession(in: context)
      if activeSession?.isActive == true {
        startTimer()
      }
    }
  #endif

  func toggleBlocking(context: ModelContext, activeProfile: BlockedProfiles?) {
    guard !ScreenshotDemoMode.isActive else { return }
    if isBlocking {
      guard activeProfile?.id == activeSession?.blockedProfile.id else {
        errorMessage = "A session is already active. Stop it before starting another."
        return
      }
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
          self.stopBlocking(context: context)
        }
        return
      }

      stopBlocking(context: context)
    } else {
      if geofenceEvaluator.isCheckingGeofence,
        !geofenceEvaluator.recoverStaleGeofenceCheck()
      {
        errorMessage = "Still checking your location. Try again in a moment."
        Log.info("Start tap ignored: geofence check already in flight", category: .strategy)
        return
      }

      geofenceEvaluator.checkGeofenceAndStart(context: context, activeProfile: activeProfile) {
        ctx, profile in
        self.startBlocking(context: ctx, activeProfile: profile)
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
    timerTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled else { break }
        guard let self, let session = self.activeSession else { break }

        let now = Date()
        self.evaluateGrantExpiry(now: now)
        if let remaining = self.grantCountdownRemaining(now: now) {
          self.elapsedTime = remaining
        } else {
          let rawElapsedTime = now.timeIntervalSince(session.startTime)
          let breakDuration = session.calculateBreakDuration()
          self.elapsedTime = rawElapsedTime - breakDuration
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

  func evaluateGrantExpiry(now: Date = Date()) {
    guard !ScreenshotDemoMode.isActive else { return }
    guard let session = activeSession else { return }
    let profile = session.blockedProfile
    let live = BlockedProfiles.getSnapshot(for: profile)
    if session.oneMoreMinuteStartTime != nil {
      let closed = SharedData.closeOneMoreMinuteGrantIfExpired(
        expectedSessionId: session.id,
        now: now,
        process: .mainApp,
        liveSnapshot: live,
        applier: appBlocker)
      if closed {
        backstopRegistrar.removeOneMoreMinuteBackstop(profileId: profile.id)
        mirrorGrantFieldsFromShared(session)
      }
    }
    if session.breakStartTime != nil && session.breakEndTime == nil {
      let closed = SharedData.closeBreakGrantIfExpiredOrExplicit(
        expectedSessionId: session.id,
        explicit: false,
        now: now,
        process: .mainApp,
        durationMinutes: profile.breakTimeInMinutes,
        liveSnapshot: live,
        applier: appBlocker)
      if closed {
        backstopRegistrar.removeBreakBackstop(profileId: profile.id)
        mirrorGrantFieldsFromShared(session)
      }
    }
  }

  func grantCountdownRemaining(now: Date = Date()) -> TimeInterval? {
    guard let session = activeSession else { return nil }
    if session.breakStartTime != nil && session.breakEndTime == nil,
      let deadline = session.breakEndDeadline
    {
      return max(0, deadline.timeIntervalSince(now))
    }
    if session.oneMoreMinuteStartTime != nil, let deadline = session.oneMoreMinuteDeadline {
      return max(0, deadline.timeIntervalSince(now))
    }
    return nil
  }

  func reconcileGrants(context: ModelContext, now: Date = Date()) {
    guard !ScreenshotDemoMode.isActive else { return }
    guard let session = activeSession else {
      SharedData.applyRestrictionsForCurrentState(
        process: .mainApp,
        liveSnapshot: nil,
        applier: appBlocker)
      return
    }

    let profile = session.blockedProfile
    BlockedProfiles.updateSnapshot(for: profile)
    let live = BlockedProfiles.getSnapshot(for: profile)

    SharedData.reconcileExpiredGrants(
      process: .mainApp,
      now: now,
      liveSnapshot: live,
      breakDurationMinutes: profile.breakTimeInMinutes,
      applier: appBlocker)
    mirrorGrantFieldsFromShared(session)

    if let shared = SharedData.getActiveSharedSession(), shared.id == session.id,
      shared.endTime == nil, SharedData.hasOpenGrant(shared)
    {
      SharedData.completeGrantMigration(
        expectedSessionId: session.id,
        breakDurationMinutes: profile.breakTimeInMinutes,
        pinned: live,
        now: now)
      mirrorGrantFieldsFromShared(session)
      rearmBackstopsIfNeeded(profileId: profile.id, now: now)
    }

    DeviceActivityCenterUtil.removeC2BackstopsExcept(profileId: profile.id)
  }

  private func rearmBackstopsIfNeeded(profileId: UUID, now: Date) {
    guard let shared = SharedData.getActiveSharedSession() else { return }
    if shared.breakStartTime != nil, shared.breakEndTime == nil,
      let deadline = shared.breakEndDeadline, now < deadline
    {
      do {
        _ = try backstopRegistrar.registerBreakBackstopIfAbsent(
          profileId: profileId,
          deadline: deadline,
          now: now)
      } catch {
        failClosedCloseBreak(profileId: profileId, now: now)
      }
    }
    if shared.oneMoreMinuteStartTime != nil,
      let deadline = shared.oneMoreMinuteDeadline, now < deadline
    {
      do {
        _ = try backstopRegistrar.registerOneMoreMinuteBackstopIfAbsent(
          profileId: profileId,
          deadline: deadline,
          now: now)
      } catch {
        failClosedCloseOMM(profileId: profileId, now: now)
      }
    }
  }

  private func failClosedCloseBreak(profileId: UUID, now: Date) {
    guard let session = activeSession else { return }
    let live = BlockedProfiles.getSnapshot(for: session.blockedProfile)
    _ = SharedData.closeBreakGrantIfExpiredOrExplicit(
      expectedSessionId: session.id,
      explicit: true,
      now: now,
      process: .mainApp,
      durationMinutes: session.blockedProfile.breakTimeInMinutes,
      liveSnapshot: live,
      applier: appBlocker)
    mirrorGrantFieldsFromShared(session)
    backstopRegistrar.removeBreakBackstop(profileId: profileId)
    timersUtil.cancelAllNotifications()
    errorMessage = "Your break ended early — it couldn't be scheduled in the background."
  }

  private func failClosedCloseOMM(profileId: UUID, now: Date) {
    guard let session = activeSession else { return }
    let live = BlockedProfiles.getSnapshot(for: session.blockedProfile)
    _ = SharedData.closeOneMoreMinuteGrantIfExpired(
      expectedSessionId: session.id,
      now: now,
      process: .mainApp,
      liveSnapshot: live,
      force: true,
      applier: appBlocker)
    mirrorGrantFieldsFromShared(session)
    backstopRegistrar.removeOneMoreMinuteBackstop(profileId: profileId)
    timersUtil.cancelAllNotifications()
    errorMessage = "One more minute ended early — it couldn't be scheduled in the background."
  }

  enum TagOperation {
    case scan
    case explicitStart(UUID)
    case confirmSwitch
  }
  struct PendingTagSwitch: Equatable {
    let operationId: UUID
    let victimId: String
    let targetProfileId: UUID?
    let event: TagEvent
    let requiredType: TagType
    let recordSuccessfulUse: Bool
  }
  @Published private(set) var pendingTagSwitch: PendingTagSwitch?
  @Published var showTagConfirmation = false
  @Published private(set) var tagScanError: String?
  private var tagOperationId: UUID?

  func cancelTagOperation() {
    tagOperationId = nil
    pendingTagSwitch = nil
    showTagConfirmation = false
    tagScanError = nil
  }

  func handleDelivery(_ delivery: ProfileTagLink.Delivery, context: ModelContext, now: Date = Date()) async {
    switch delivery {
    case .tag(let event):
      do {
        if let session = try getActiveSession(context: context), session.blockedProfile.profileSchemaVersion < 2,
          let target = event.targetProfileId
        {
          cancelTagOperation()
          await handleLegacyLink(profileId: target, sessionId: session.id, context: context)
        } else {
          await handleTagEvent(event, operation: .scan, context: context, now: now, recordSuccessfulUse: false)
        }
      } catch { errorMessage = error.localizedDescription }
    case .link(let id):
      await toggleSessionFromDeeplink(id.uuidString, url: URL(string: "https://family-foqos.app/profile/\(id.uuidString)")!, context: context)
    }
  }

  func toggleSessionFromDeeplink(_ profileId: String, url: URL, context: ModelContext) async {
    cancelTagOperation()
    let parsed: ParsedProfileLink
    do { parsed = try ProfileTagLink.parse(url) } catch {
      errorMessage = ProfileTagLink.Failure.invalidLink.localizedDescription
      return
    }
    guard UUID(uuidString: profileId) == parsed.profileId else {
      errorMessage = ProfileTagLink.Failure.invalidLink.localizedDescription
      return
    }
    do {
      guard let profile = try BlockedProfiles.findProfile(byID: parsed.profileId, in: context) else {
        errorMessage = "No matching profile found on this device. The profile may have been deleted or this tag belongs to a different device."
        return
      }
      if let session = try getActiveSession(context: context) {
        if session.blockedProfile.profileSchemaVersion < 2 {
          await handleLegacyLink(profileId: profile.id, sessionId: session.id, context: context)
        } else if session.blockedProfile.id != profile.id {
          errorMessage = "Stop \(session.blockedProfile.name) before starting \(profile.name) from this link."
        } else {
          errorMessage = nil
        }
        return
      }
      _ = try startOriginatingSession(context: context, profile: profile, origin: .init(kind: .link))
    } catch { errorMessage = error.localizedDescription }
  }

  private func handleLegacyLink(profileId: UUID, sessionId: String, context: ModelContext) async {
    guard let session = try? BlockedProfileSession.findSession(byID: sessionId, in: context),
      session.isActive, session.blockedProfile.profileSchemaVersion < 2
    else { return }
    guard !session.blockedProfile.disableBackgroundStops else {
      errorMessage = "profile: \(session.blockedProfile.name) has disable background stops enabled, not stopping it"
      return
    }
    guard await tagStopGeofenceAllowed(sessionId: sessionId, context: context),
      let current = try? BlockedProfileSession.findSession(byID: sessionId, in: context), current.isActive,
      activeSession?.id == sessionId, SharedData.getActiveSharedSession()?.id == sessionId
    else { return }
    do {
      if current.blockedProfile.id == profileId {
        stopBlocking(context: context, bypassStrategy: true)
      } else if let profile = try BlockedProfiles.findProfile(byID: profileId, in: context) {
        _ = try startOriginatingSession(context: context, profile: profile, origin: .init(kind: .link), expectedVictimId: sessionId)
        finishDepartingSession(current, context: context)
      }
    } catch { errorMessage = error.localizedDescription }
  }

  func handleTagEvent(_ event: TagEvent, operation: TagOperation, context: ModelContext, now: Date = Date(), recordSuccessfulUse: Bool = true) async {
    do {
      if case .confirmSwitch = operation {
        guard let pending = pendingTagSwitch else { return }
        guard activeSession?.id == pending.victimId,
          let victim = try BlockedProfileSession.findSession(byID: pending.victimId, in: context), victim.isActive,
          SharedData.getActiveSharedSession()?.id == victim.id
        else {
          cancelTagOperation()
          return
        }
        guard event.type == pending.requiredType,
          tagStopResult(event, session: victim).allowed
        else {
          tagScanError = event.type == .nfc ? "That NFC tag doesn’t match. Scan the required tag." : "That QR code doesn’t match. Scan the required code."
          return
        }
        await commitTagTransition(pending, context: context, now: now)
        return
      }
      cancelTagOperation()
      let operationId = UUID()
      tagOperationId = operationId
      if case .explicitStart(let id) = operation {
        guard let profile = try BlockedProfiles.findProfile(byID: id, in: context) else { throw ProfileTagLink.Failure.invalidTag }
        guard let rejection = rejectionForStart(profile, context: context) else {
          try prepareProfileForStart(profile, context: context)
          let origin = admittedTagOrigin(event, profile: profile)
          _ = try startOriginatingSession(context: context, profile: profile, origin: origin, now: now)
          tagOperationId = nil
          return
        }
        errorMessage = rejection
        tagOperationId = nil
        return
      }
      if let victim = try getActiveSession(context: context) {
        let target = event.targetProfileId == victim.blockedProfile.id ? nil : event.targetProfileId
        let kind = event.type == .nfc ? victim.blockedProfile.stopConditions.nfc : victim.blockedProfile.stopConditions.qr
        guard kind != .none else {
          if let target, let profile = try BlockedProfiles.findProfile(byID: target, in: context) {
            errorMessage = "\(victim.blockedProfile.name) can’t stop with this tag or code. Stop it another way before starting \(profile.name)."
          } else {
            errorMessage = tagStopResult(event, session: victim).errorMessage
          }
          tagOperationId = nil
          return
        }
        if let target {
          guard let profile = try BlockedProfiles.findProfile(byID: target, in: context) else { throw ProfileTagLink.Failure.invalidTag }
          try prepareProfileForStart(profile, context: context)
          if let rejection = ProfileConditionValidation.startRejection(
            for: BlockedProfiles.getSnapshot(for: profile), origin: admittedTagOrigin(event, profile: profile), allowLinkForTag: true)
          {
            throw NSError(domain: "ProfileStart", code: 1, userInfo: [NSLocalizedDescriptionKey: rejection])
          }
          guard !profile.needsAppSelection else {
            throw NSError(domain: "ProfileStart", code: 1, userInfo: [NSLocalizedDescriptionKey: needsAppSelectionMessage(for: profile)])
          }
        }
        let pending = PendingTagSwitch(operationId: operationId, victimId: victim.id, targetProfileId: target, event: event, requiredType: event.type, recordSuccessfulUse: recordSuccessfulUse)
        if !tagStopResult(event, session: victim).allowed {
          pendingTagSwitch = pending
          showTagConfirmation = true
          return
        }
        await commitTagTransition(pending, context: context, now: now)
      } else if let target = event.targetProfileId {
        guard let profile = try BlockedProfiles.findProfile(byID: target, in: context) else { throw ProfileTagLink.Failure.invalidTag }
        try prepareProfileForStart(profile, context: context)
        _ = try startOriginatingSession(context: context, profile: profile, origin: admittedTagOrigin(event, profile: profile), now: now, allowLinkForTag: true)
        tagOperationId = nil
      } else {
        tagOperationId = nil
      }
    } catch {
      cancelTagOperation()
      errorMessage = error.localizedDescription
    }
  }

  private func admittedTagOrigin(_ event: TagEvent, profile: BlockedProfiles) -> SessionOrigin {
    if event.namespace == .qrDigest, profile.startTriggers.specificQR,
      let raw = event.rawKey, profile.startQRCodeIds.contains(raw),
      !profile.startQRCodeIds.contains(event.key ?? "")
    {
      return SessionOrigin(kind: .qr, key: raw, namespace: .qrDigest)
    }
    return event.origin
  }

  private func tagStopResult(_ event: TagEvent, session: BlockedProfileSession) -> StopValidationResult {
    StartStopActionResolver.canStop(
      with: .tag(event), conditions: session.blockedProfile.stopConditions,
      sessionTag: session.tag, stopNFCTagIds: session.blockedProfile.stopNFCTagIds,
      stopQRCodeIds: session.blockedProfile.stopQRCodeIds, sessionOrigin: session.origin,
      legacySession: session.blockedProfile.profileSchemaVersion < 2)
  }

  private func commitTagTransition(_ pending: PendingTagSwitch, context: ModelContext, now: Date) async {
    guard await tagStopGeofenceAllowed(sessionId: pending.victimId, context: context),
      tagOperationId == pending.operationId
    else {
      if tagOperationId == pending.operationId { cancelTagOperation() }
      return
    }
    do {
      guard let victim = try BlockedProfileSession.findSession(byID: pending.victimId, in: context),
        victim.isActive, activeSession?.id == victim.id, SharedData.getActiveSharedSession()?.id == victim.id
      else {
        cancelTagOperation()
        return
      }
      if let target = pending.targetProfileId {
        guard let profile = try BlockedProfiles.findProfile(byID: target, in: context) else { throw ProfileTagLink.Failure.invalidTag }
        _ = try startOriginatingSession(
          context: context, profile: profile,
          origin: admittedTagOrigin(pending.event, profile: profile), now: now,
          expectedVictimId: victim.id, allowLinkForTag: true)
        finishDepartingSession(victim, context: context, now: now)
      } else if victim.blockedProfile.profileSchemaVersion >= 2 {
        endV2Session(victim, context: context, now: now, recordSuccessfulUse: pending.recordSuccessfulUse)
      } else {
        stopBlocking(context: context, bypassStrategy: true)
      }
      cancelTagOperation()
    } catch {
      cancelTagOperation()
      errorMessage = error.localizedDescription
    }
  }

  private func tagStopGeofenceAllowed(sessionId: String, context: ModelContext) async -> Bool {
    guard let session = try? BlockedProfileSession.findSession(byID: sessionId, in: context), session.isActive else { return false }
    if let rule = session.blockedProfile.geofenceRule, rule.hasLocations {
      if locationManager.isNotDetermined {
        locationManager.requestAuthorization()
        errorMessage = "Please allow location access to stop this profile, then try again."
        return false
      }
      if locationManager.isDenied {
        errorMessage = "Location access is denied. Enable location services in Settings to use location-based restrictions."
        return false
      }
    }
    let result = await geofenceEvaluator.evaluateGeofenceForStop(profile: session.blockedProfile, context: context)
    if let result, !result.isSatisfied {
      errorMessage = result.failureMessage ?? "Location restriction not met."
      return false
    }
    return true
  }

  @discardableResult
  func startSessionFromBackground(
    _ profileId: UUID,
    context: ModelContext,
    durationInMinutes: Int? = nil,
    authorization: AuthorizationRequesting = AuthorizationCenterRequester.shared,
    mode: AppMode = AppModeManager.shared.currentMode,
    isUnlocked: (UUID) -> Bool = { LockCodeManager.shared.isUnlocked($0) },
    canVerifyCode: Bool = LockCodeManager.shared.canVerifyCode
  ) throws -> String {
    do {
      guard durationInMinutes == nil else {
        throw IntentError.unexpected("This start uses the profile’s saved timer. Remove Duration from the Shortcut or edit the profile’s timer.")
      }
      guard let profile = try BlockedProfiles.findProfile(byID: profileId, in: context) else { throw IntentError.profileNotFound }
      guard try getActiveSession(context: context) == nil else { throw IntentError.sessionAlreadyActive }
      guard !profile.needsAppSelection else { throw IntentError.needsAppSelection(profileName: profile.name) }
      switch authorization.authorizationStatus {
      case .approved, .approvedWithDataAccess: break
      default: throw IntentError.unexpected("Open Family Foqos and authorize Screen Time before starting this profile.")
      }
      _ = try startOriginatingSession(context: context, profile: profile, origin: .init(kind: .shortcut))
      return profile.name
    } catch let error as IntentError {
      self.errorMessage = String(localized: error.localizedStringResource)
      throw error
    } catch {
      self.errorMessage = error.localizedDescription
      throw IntentError.unexpected(error.localizedDescription)
    }
  }

  func stopSessionFromBackground(
    _ profileId: UUID,
    context: ModelContext,
    requireUnlock: () -> Bool = { ShortcutsSettings.requiresDeviceUnlock() }
  ) async throws {
    let requiredUnlockAtStart = requireUnlock()
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

      if profile.profileSchemaVersion < 2, profile.disableBackgroundStops {
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

      guard requiredUnlockAtStart || !requireUnlock() else {
        throw IntentError.unexpected("Device unlock is now required. Retry the action under the new setting.")
      }
      guard let currentSession = try getActiveSession(context: context),
        currentSession.id == localActiveSession.id, currentSession.isActive,
        let currentProfile = try BlockedProfiles.findProfile(byID: profileId, in: context)
      else { throw IntentError.noActiveSession(profileName: profile.name) }

      // Only deferred active V1 profiles retain the shipped safeguard.
      if currentProfile.profileSchemaVersion < 2, currentProfile.disableBackgroundStops {
        throw IntentError.backgroundStopsDisabled(profileName: currentProfile.name)
      }

      let decision = BackgroundStopPolicy.evaluate(
        channel: .shortcut,
        sessionMatchesProfile: currentSession.blockedProfile.id == profileId,
        geofence: geofenceState,
        // V1 Shortcuts could stop unless disableBackgroundStops vetoed above.
        stopConditions: currentProfile.profileSchemaVersion == 1 ? .init(manual: true) : currentProfile.stopConditions
      )

      switch decision {
      case .allowed:
        break
      case .denied(.geofenceNotSatisfied(let reason)):
        Log.info("Geofence blocked background stop", category: .strategy)
        geofenceEvaluator.postGeofenceBlockedNotification(
          profileId: profile.id, profileName: profile.name, reason: reason)
        self.errorMessage = "Cannot stop — \(reason)"
        throw IntentError.geofenceBlocked(reason: reason)
      case .denied(.geofenceUnavailable):
        let reason = "Your location can't be confirmed right now."
        Log.info("Geofence blocked background stop: location unavailable", category: .strategy)
        geofenceEvaluator.postGeofenceBlockedNotification(
          profileId: profile.id, profileName: profile.name, reason: reason)
        self.errorMessage = "Cannot stop — \(reason)"
        throw IntentError.geofenceBlocked(reason: reason)
      case .denied(.stopConditionNotMet(let reason)):
        Log.info("Background stop refused: stop conditions not met", category: .strategy)
        self.errorMessage = reason
        throw IntentError.stopConditionsNotMet(reason: reason)
      case .denied(.noMatchingSession):
        throw IntentError.noActiveSession(profileName: profile.name)
      }

      if currentSession.blockedProfile.profileSchemaVersion >= 2 { endV2Session(currentSession, context: context) } else { _ = manualStrategy.stopBlocking(context: context, session: currentSession) }
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
      guard let self else { return false }
      if sess.blockedProfile.profileSchemaVersion >= 2 {
        return self.endV2Session(sess, context: ctx, emergency: true)
      }
      _ = self.getStrategy(id: ManualBlockingStrategy.id).stopBlocking(context: ctx, session: sess)
      return !sess.isActive
    }
  }

  /// Sync a session start to CloudKit via CAS. Uses passed context for persistence.
  private func syncSessionStart(session: BlockedProfileSession, context: ModelContext, confirmRemoteReplacement: Bool = false) {
    guard shouldSyncSessionChange || (confirmRemoteReplacement && profileSyncManager.isEnabled) else { return }

    session.sessionStartSyncPending = true
    do { try context.save() } catch { Log.error("Failed to save pending session start", category: .sync) }
    let candidateId = session.id
    let candidateStart = session.startTime
    let candidateDeadline = session.timerEndTime
    let candidateOrigin = session.origin
    let previousTask = sessionSyncTask
    sessionSyncTask = Task {
      await previousTask?.value
      let profileId = session.blockedProfile.id
      guard let pending = sessionStopOutbox.intents else { return }
      for intent in pending where intent.profileId == profileId && intent.expectedSessionId != nil {
        let stop = await sessionSyncService.stopSession(
          profileId: profileId, expectedSessionId: intent.expectedSessionId, expectedStart: intent.expectedStart)
        switch stop {
        case .stopped, .alreadyStopped:
          sessionStopOutbox.resolve(profileId: profileId, expectedSessionId: intent.expectedSessionId, expectedStart: intent.expectedStart)
        case .conflict, .error:
          Log.info("Deferred start sync until the previous exact session stop succeeds", category: .sync)
          return
        }
      }
      guard self.activeSession?.id == candidateId, session.isActive else { return }
      let result = await sessionSyncService.startSession(
        profileId: profileId,
        startTime: candidateStart,
        timerEndTime: candidateDeadline, sessionId: candidateId, origin: candidateOrigin
      )

      switch result {
      case .started(let sequence, let confirmed):
        if self.activeSession?.id == candidateId {
          session.sessionSequence = sequence
          session.sessionServerModificationDate = confirmed ?? session.sessionServerModificationDate
          session.sessionStartSyncPending = false
          do { try context.save() } catch { Log.error("Failed to save confirmed session start", category: .sync) }
        }
        Log.info("Session synced", category: .strategy)
      case .alreadyActive(let existing):
        if sessionStopOutbox.intents?.contains(where: { $0.profileId == profileId && $0.expectedSessionId != nil && $0.expectedSessionId == existing.sessionId }) == true {
          Log.info("Deferred joining a session with a pending exact stop", category: .sync)
          return
        }
        Log.info(
          "Joined existing session from \(existing.sessionOriginDevice ?? "unknown")",
          category: .strategy
        )
        if reconcileSessionTiming(
          sessionId: candidateId, profileId: existing.profileId,
          startTime: existing.startTime, timerEndTime: existing.validTimerEndTime,
          originDevice: existing.sessionOriginDevice, context: context, canonicalSessionId: existing.sessionId, origin: existing.origin, sequenceNumber: existing.sequenceNumber, serverModificationDate: existing.serverModificationDate)
        {
          session.sessionStartSyncPending = false
          do { try context.save() } catch { Log.error("Failed to save joined session start", category: .sync) }
        }
      case .error(let error):
        Log.info("Failed to sync session start - \(redactedErrorForLog(error))", category: .strategy)
      }
    }
  }

  /// #201: resolve only the attempted persisted stop on success. On the terminal
  /// outcomes (an immediate `.error`, or `.conflict`/`.error` after one retry), the dropped stop
  /// intent is persisted to the outbox for re-drive on foreground (`drainSessionStopOutbox()` is
  /// wired to scenePhase `.active` in `FoqosApp`).
  /// Extracted from the CAS Task closure so Phase-E tests can exercise the routing without a
  /// live CloudKit round trip.
  func handleStopResult(
    _ result: SessionSyncService.StopResult, profileId: UUID,
    endTime: Date = Date(), expectedSessionId: String? = nil, expectedStart: Date? = nil
  ) async {
    switch result {
    case .stopped:
      sessionStopOutbox.resolve(profileId: profileId, expectedSessionId: expectedSessionId, expectedStart: expectedStart)
      Log.info("Session stop synced", category: .strategy)
    case .alreadyStopped:
      sessionStopOutbox.resolve(profileId: profileId, expectedSessionId: expectedSessionId, expectedStart: expectedStart)
      Log.info("Session was already stopped", category: .strategy)
    case .conflict(let current):
      Log.info("Stop conflict, current seq=\(current.sequenceNumber)", category: .strategy)
      // Retry stop once
      let retryResult = await sessionSyncService.stopSession(
        profileId: profileId, endTime: endTime, expectedSessionId: expectedSessionId, expectedStart: expectedStart)
      switch retryResult {
      case .stopped:
        sessionStopOutbox.resolve(profileId: profileId, expectedSessionId: expectedSessionId, expectedStart: expectedStart)
        Log.info("Stop retry succeeded", category: .strategy)
      case .alreadyStopped:
        sessionStopOutbox.resolve(profileId: profileId, expectedSessionId: expectedSessionId, expectedStart: expectedStart)
        Log.info("Stop retry found session already stopped", category: .strategy)
      case .conflict, .error:
        Log.info("Stop retry failed", category: .strategy)
        // #201: persist the dropped stop intent for foreground re-drive instead of losing it.
        sessionStopOutbox.enqueue(profileId: profileId, expectedStart: expectedStart, expectedSessionId: expectedSessionId)
      }
    case .error(let error):
      Log.info("Failed to sync session stop - \(redactedErrorForLog(error))", category: .strategy)
      // #201: persist the dropped stop intent for foreground re-drive instead of losing it.
      sessionStopOutbox.enqueue(profileId: profileId, expectedStart: expectedStart, expectedSessionId: expectedSessionId)
    }
  }

  /// #201: re-drive persisted session-stop intents. Wired to scenePhase `.active` in `FoqosApp`.
  func drainSessionStopOutbox() async {
    await sessionStopOutbox.drain { [weak self] profileId, expectedSessionId, expectedStart in
      guard let self else { return true }
      let result = await self.sessionSyncService.stopSession(profileId: profileId, expectedSessionId: expectedSessionId, expectedStart: expectedStart)
      switch result {
      case .stopped, .alreadyStopped:
        return true
      case .conflict, .error:
        return false
      }
    }
    if let session = activeSession, session.isActive, session.sessionStartSyncPending,
      let context = session.modelContext, let pending = sessionStopOutbox.intents,
      !pending.contains(where: { $0.profileId == session.blockedProfile.id && $0.expectedSessionId != nil })
    {
      syncSessionStart(session: session, context: context)
      await sessionSyncTask?.value
    }
  }

  /// Single source of truth for session activation — all start paths converge here.
  /// Handles state updates, timer, live activity, stop scheduling, widget refresh, and CAS sync.
  private func activateSession(
    _ session: BlockedProfileSession,
    context: ModelContext? = nil
  ) {
    // Keep exact-ID stops: they must retire the previous server session before this start.
    // A profile-only legacy stop could instead stop this replacement and is superseded.
    sessionStopOutbox.removeLegacyIntents(profileId: session.blockedProfile.id)

    // Cancel stale reminders/notifications from previous sessions
    timersUtil.cancelAll()

    // Update profile snapshot in case settings changed
    BlockedProfiles.updateSnapshot(for: session.blockedProfile)

    errorMessage = nil
    activeSession = session
    startTimer()
    startSessionActivity(session)

    // Schedule stop activity if configured
    let failures = DeviceActivityCenterUtil.scheduleStopActivity(for: session.blockedProfile)
    if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }

    // Cancel pre-activation reminders now that profile is active
    cancelPreActivationReminders(session.blockedProfile.id)

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
        if endedProfile.profileSchemaVersion < 2 {
          DeviceActivityCenterUtil.removeStrategyTimerActivity(profileId: endedProfile.id)
        }
        // Delayed outgoing callbacks must not clear the replacement's activity or grants.
        if self.activeSession == nil || self.activeSession?.blockedProfile.id == endedProfile.id {
          self.timersUtil.cancelAll()

          self.activeSession = nil
          self.liveActivityManager.endSessionActivity()
          self.scheduleReminder(profile: endedProfile)

          self.stopTimer()
          self.elapsedTime = 0

          // Refresh widgets when session ends
          WidgetCenter.shared.reloadTimelines(ofKind: "ProfileControlWidget")

          DeviceActivityCenterUtil.removeAllBreakTimerActivities()
        }

        // Remove one more minute activity for the ended profile
        DeviceActivityCenterUtil.removeOneMoreMinuteActivity(for: endedProfile)

        self.migrateDepartingProfile(endedProfile)

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

      self.errorMessage = [self.errorMessage, message].compactMap { $0 }.joined(separator: "\n")
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
    guard !ScreenshotDemoMode.isActive else { return }
    var hadDanglingGrant = false

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
      if let profile = try? BlockedProfiles.findProfile(byID: completedScheduleSession.blockedProfileId, in: context),
        profile.profileSchemaVersion < 2
      {
        DeviceActivityCenterUtil.removeStrategyTimerActivity(profileId: profile.id)
        migrateDepartingProfile(profile)
      }

      // Sync scheduled session end using CAS (if global sync is enabled)
      if profileSyncManager.isEnabled, let endTime = completedScheduleSession.endTime {
        sessionStopOutbox.enqueue(
          profileId: completedScheduleSession.blockedProfileId, expectedStart: completedScheduleSession.startTime,
          expectedSessionId: completedScheduleSession.usesCanonicalIdentity == true ? completedScheduleSession.id : nil)
        let previousTask = sessionSyncTask
        sessionSyncTask = Task {
          await previousTask?.value
          let expectedStart = completedScheduleSession.startTime
          let result = await sessionSyncService.stopSession(
            profileId: completedScheduleSession.blockedProfileId,
            endTime: endTime,
            expectedSessionId: completedScheduleSession.usesCanonicalIdentity == true ? completedScheduleSession.id : nil,
            expectedStart: expectedStart
          )

          await handleStopResult(
            result, profileId: completedScheduleSession.blockedProfileId,
            endTime: endTime, expectedSessionId: completedScheduleSession.usesCanonicalIdentity == true ? completedScheduleSession.id : nil, expectedStart: expectedStart)
        }
      }
    }

    // Process any active scheduled sessions
    if let activeScheduledSession = SharedData.getActiveSharedSession() {
      if SharedData.endedSessionHadOpenGrant(activeScheduledSession) {
        hadDanglingGrant = true
      }
      BlockedProfileSession.upsertSessionFromSnapshot(
        in: context,
        withSnapshot: activeScheduledSession
      )

      // Foreground and extension starts share the same exact-stop-before-start ordering.
      if let profile = try? BlockedProfiles.findProfile(byID: activeScheduledSession.blockedProfileId, in: context),
        let session = profile.sessions.valid.first(where: { $0.id == activeScheduledSession.id })
      {
        syncSessionStart(session: session, context: context)
      }
    }

    if hadDanglingGrant {
      timersUtil.cancelAllNotifications()
    }
  }

  /// Starts only after inactive V1 data has crossed the conversion boundary.
  private func startBlocking(context: ModelContext, activeProfile: BlockedProfiles?) {
    guard let definedProfile = activeProfile else {
      Log.info(
        "No active profile found, calling stop blocking with no session", category: .strategy)
      return
    }

    if let rejection = rejectionForStart(definedProfile, context: context) {
      errorMessage = rejection
      Log.info("Refusing manual start", category: .strategy)
      return
    }

    do { try prepareProfileForStart(definedProfile, context: context) } catch {
      errorMessage = error.localizedDescription
      return
    }
    if definedProfile.profileSchemaVersion >= 2 {
      let snapshot = BlockedProfiles.getSnapshot(for: definedProfile)
      if let rejection = ProfileConditionValidation.startRejection(for: snapshot, origin: .init(kind: .manual)) {
        errorMessage = rejection
        return
      }
      if definedProfile.stopConditions.timer,
        definedProfile.stopConditions.allowChangingTimerBeforeStart,
        let saved = definedProfile.stopConditions.timerDurationMinutes
      {
        customStrategyView = TimerDurationView(
          profileName: definedProfile.name, initialDurationMinutes: saved,
          adjustmentNote: "This session only; the saved duration stays unchanged."
        ) { duration in
          self.dismissView()
          do {
            _ = try self.startOriginatingSession(
              context: context, profile: definedProfile,
              origin: .init(kind: .manual), durationOverrideMinutes: duration.durationInMinutes)
          } catch { self.errorMessage = error.localizedDescription }
        }
        showCustomStrategyView = true
      } else {
        do { _ = try startOriginatingSession(context: context, profile: definedProfile, origin: .init(kind: .manual)) } catch { errorMessage = error.localizedDescription }
      }
      return
    }
  }

  /// Start blocking with a pre-scanned NFC tag (for trigger-based start)
  func startWithNFCTag(context: ModelContext, profile: BlockedProfiles, tagId: String) {
    // Validate specific NFC tag if required
    if profile.startTriggers.specificNFC {
      guard profile.startNFCTagIds.contains(tagId) else {
        errorMessage = "This NFC tag doesn't match the one configured for this profile"
        return
      }
    }
    startWithTag(context: context, profile: profile, origin: .init(kind: .nfc, key: tagId, namespace: .nfcUID))
  }

  /// Start blocking with a pre-scanned QR code (for trigger-based start)
  func startWithQRCode(context: ModelContext, profile: BlockedProfiles, codeValue: String, rawHash: String? = nil) {
    // Validate specific QR code if required
    if profile.startTriggers.specificQR {
      guard profile.startQRCodeIds.contains(where: { $0 == codeValue || $0 == rawHash }) else {
        errorMessage = "This QR code doesn't match the one configured for this profile"
        return
      }
    }
    let matchedKey =
      profile.startTriggers.specificQR
      ? (profile.startQRCodeIds.first { $0 == codeValue || $0 == rawHash } ?? codeValue) : codeValue
    startWithTag(context: context, profile: profile, origin: .init(kind: .qr, key: matchedKey, namespace: .qrDigest))
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
      stopNFCTagIds: session.blockedProfile.stopNFCTagIds,
      stopQRCodeIds: session.blockedProfile.stopQRCodeIds, sessionOrigin: session.origin, legacySession: session.blockedProfile.profileSchemaVersion < 2
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
  func stopWithQRCode(context: ModelContext, codeValue: String, rawHash: String? = nil) {
    guard let session = activeSession else {
      errorMessage = "No active session to stop"
      return
    }

    let validation = StartStopActionResolver.canStop(
      with: .qr(code: codeValue, rawHash: rawHash),
      conditions: session.blockedProfile.stopConditions,
      sessionTag: session.tag,
      stopNFCTagIds: session.blockedProfile.stopNFCTagIds,
      stopQRCodeIds: session.blockedProfile.stopQRCodeIds, sessionOrigin: session.origin, legacySession: session.blockedProfile.profileSchemaVersion < 2
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
  private func startWithTag(context: ModelContext, profile: BlockedProfiles, origin: SessionOrigin) {
    if let rejection = rejectionForStart(profile, context: context) {
      errorMessage = rejection
      Log.info("Refusing tag start", category: .strategy)
      return
    }

    do { _ = try startOriginatingSession(context: context, profile: profile, origin: origin) } catch { errorMessage = error.localizedDescription }
  }

  func rejectionForStart(_ profile: BlockedProfiles, context: ModelContext) -> String? {
    rejectionForStart(profile) {
      try getActiveSession(context: context)
    }
  }

  func rejectionForStart(
    _ profile: BlockedProfiles,
    activeSessionProvider: () throws -> BlockedProfileSession?
  ) -> String? {
    do {
      if try activeSessionProvider() != nil {
        return "A session is already active. Stop it before starting another."
      }
    } catch {
      Log.error(
        "Failed to verify active session before start: \(error.localizedDescription)",
        category: .strategy)
      return "Couldn't verify whether a session is already active. Try again."
    }

    if profile.needsAppSelection {
      return needsAppSelectionMessage(for: profile)
    }

    return nil
  }

  private func needsAppSelectionMessage(for profile: BlockedProfiles) -> String {
    IntentError.needsAppSelectionMessage(profileName: profile.name)
  }

  /// New sessions always use V2 rules; an active V1 profile must remain untouched.
  func prepareProfileForStart(_ profile: BlockedProfiles, context: ModelContext) throws {
    guard profile.profileSchemaVersion == 1 else { return }
    guard try getActiveSession(context: context)?.blockedProfile.id != profile.id else {
      throw NSError(domain: "ProfileStart", code: 1, userInfo: [NSLocalizedDescriptionKey: "A session is already active. Stop it before starting another."])
    }
    try migrateInactiveProfile(profile)
    guard profile.profileSchemaVersion >= 2 else {
      throw NSError(domain: "ProfileStart", code: 1, userInfo: [NSLocalizedDescriptionKey: "Please edit this profile before starting. Its start and stop settings need updating."])
    }
  }

  private func migrateInactiveProfile(_ profile: BlockedProfiles) throws {
    if try ProfileMigrationUtil.migrate(profile, hasActiveSession: false) {
      BlockedProfiles.updateSnapshot(for: profile)
      let failures = DeviceActivityCenterUtil.scheduleTimerActivity(for: profile)
      if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
    }
  }

  /// Retry deferred V1 migration after its session ends.
  private func migrateDepartingProfile(_ profile: BlockedProfiles) {
    do { try migrateInactiveProfile(profile) } catch {
      errorMessage = "Couldn’t update this profile after its session ended. Please try again."
      Log.error("Failed to migrate deferred profile: \(error.localizedDescription)", category: .strategy)
    }
  }

  @discardableResult
  private func finishDepartingSession(_ session: BlockedProfileSession, context: ModelContext, now: Date = Date(), syncDisplacedSession: Bool = false) -> Bool {
    if session.blockedProfile.profileSchemaVersion < 2 {
      DeviceActivityCenterUtil.removeStrategyTimerActivity(profileId: session.blockedProfile.id)
    } else {
      cancelTimer(session.blockedProfile.id, session.id)
    }
    session.endSession(now: now)
    var saved = false
    do {
      try saveSession(context)
      saved = true
    } catch {
      Log.error("Failed to save completed local session: \(error.localizedDescription)", category: .session)
    }
    if activeSession?.id == session.id {
      activeSession = nil
      stopTimer()
      liveActivityManager.endSessionActivity()
      timersUtil.cancelAll()
      elapsedTime = 0
    }
    migrateDepartingProfile(session.blockedProfile)
    scheduleReminder(profile: session.blockedProfile)
    DeviceActivityCenterUtil.removeStopScheduleActivity(for: session.blockedProfile)
    DeviceActivityCenterUtil.removeOneMoreMinuteActivity(for: session.blockedProfile)
    if shouldSyncSessionChange || (syncDisplacedSession && profileSyncManager.isEnabled) {
      let profileId = session.blockedProfile.id
      let expectedSessionId = session.usesCanonicalIdentity == true ? session.id : nil
      let expectedStart = session.startTime
      sessionStopOutbox.enqueue(profileId: profileId, expectedStart: expectedStart, expectedSessionId: expectedSessionId)
      let previousTask = sessionSyncTask
      sessionSyncTask = Task {
        await previousTask?.value
        let result = await sessionSyncService.stopSession(profileId: profileId, endTime: now, expectedSessionId: expectedSessionId, expectedStart: expectedStart)
        await handleStopResult(result, profileId: profileId, endTime: now, expectedSessionId: expectedSessionId, expectedStart: expectedStart)
      }
    }
    WidgetCenter.shared.reloadTimelines(ofKind: "ProfileControlWidget")
    return saved
  }

  @discardableResult
  private func endV2Session(_ session: BlockedProfileSession, context: ModelContext, now: Date = Date(), emergency: Bool = false, recordSuccessfulUse: Bool = false) -> Bool {
    guard
      SharedData.completeSession(
        expectedSessionId: session.id, now: now, localSession: session.toSnapshot(),
        allowUndecodableStore: emergency,
        onComplete: {
          self.appBlocker.deactivateRestrictions()
        })
    else {
      errorMessage = "This session changed. Please try again."
      return false
    }
    let saved = finishDepartingSession(session, context: context, now: now)
    if recordSuccessfulUse, saved, !emergency, !processingRemoteChange, activeSession == nil, errorMessage == nil {
      ratingManager.recordSuccessfulSessionEnd(now: now)
    }
    return true
  }

  private func stopBlocking(context: ModelContext, bypassStrategy: Bool = false) {
    guard let session = activeSession else {
      Log.info(
        "No active session found, calling stop blocking with no session", category: .strategy)
      return
    }

    if session.blockedProfile.profileSchemaVersion >= 2 {
      endV2Session(session, context: context, recordSuccessfulUse: true)
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
        seconds: TimeInterval(reminderTimeInSeconds),
        identifier: TimersUtil.sessionReminderIdentifier(for: profile.id)
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
      seconds: TimeInterval(breakNotificationTimeInSeconds),
      identifier: TimersUtil.breakReminderIdentifier(for: profile.id)
    )
  }

  func cleanUpGhostSchedules(
    context: ModelContext,
    activities: [DeviceActivityName]? = nil,
    remove: (DeviceActivityName) -> Void = { DeviceActivityCenterUtil.removeScheduleTimerActivities(for: $0) }
  ) {
    guard !ScreenshotDemoMode.isActive else { return }
    let allActivities = activities ?? DeviceActivityCenterUtil.getDeviceActivities()
    let stopPrefix = StopScheduleTimerActivity.id + ":"
    let scheduleActivities = allActivities.filter {
      UUID(uuidString: $0.rawValue) != nil || $0.rawValue.hasPrefix(stopPrefix)
    }

    Log.info(
      "Found \(scheduleActivities.count) schedule timer activities out of \(allActivities.count) total activities",
      category: .strategy)

    for activity in scheduleActivities {
      let rawValue = activity.rawValue
      let id = rawValue.hasPrefix(stopPrefix) ? String(rawValue.dropFirst(stopPrefix.count)) : rawValue
      guard let profileId = UUID(uuidString: id) else {
        // This shouldn't happen since we filtered above, but print just in case
        Log.info(
          "Unexpected: failed to parse profile id from filtered activity: \(rawValue)",
          category: .strategy)
        continue
      }

      do {
        if let profile = try BlockedProfiles.findProfile(byID: profileId, in: context) {
          // Unknown schema is read-only; a failed fetch also leaves monitoring untouched.
          guard !profile.isNewerSchemaVersion else { continue }
          if !DeviceActivityCenterUtil.requiredActivities(for: profile).contains(activity) {
            Log.info("Removing obsolete profile schedule activity", category: .strategy)
            remove(activity)
          } else {
            Log.info(
              "Profile '\(profile.name)' has schedule - activity is valid", category: .strategy)
          }
        } else {
          // Profile truly doesn't exist in database
          Log.info(
            "No profile found for activity \(rawValue). Removing orphaned schedule...",
            category: .strategy)
          remove(activity)
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

    clearBlockingArtifacts(context: context)

    Log.info("Blocking state reset complete", category: .strategy)
  }

  func forceClearEnforcementForSyncedDataWipe(context: ModelContext) {
    Log.info("Force-clearing blocking state for synced-data wipe...", category: .strategy)

    stopTimer()
    activeSession = nil
    elapsedTime = 0
    showCustomStrategyView = false
    customStrategyView = nil
    clearAllRemoteSessionActive()
    timersUtil.cancelAll()

    clearBlockingArtifacts(context: context)

    Log.info("Blocking state force-cleared for synced-data wipe", category: .strategy)
  }

  private func clearBlockingArtifacts(context: ModelContext) {
    // Clean up ghost schedules
    cleanUpGhostSchedules(context: context)

    // Clear all restrictions
    appBlocker.deactivateRestrictions()

    // Remove all break timer activities
    DeviceActivityCenterUtil.removeAllBreakTimerActivities()

    // Remove all one more minute activities
    DeviceActivityCenterUtil.removeAllOneMoreMinuteActivities()

    // Remove all strategy timer activities
    removeAllStrategyTimers()
  }

  // MARK: - Remote Session Sync

  static func isCountdownTag(_ tag: String) -> Bool {
    [ShortcutTimerBlockingStrategy.id, NFCTimerBlockingStrategy.id, QRTimerBlockingStrategy.id].contains(tag)
  }

  /// CAS joins and remote updates adopt the same canonical timing without registering a timer.
  @discardableResult
  func reconcileSessionTiming(
    sessionId: String, profileId: UUID, startTime: Date?, timerEndTime: Date?,
    originDevice: String?, context: ModelContext, canonicalSessionId: String? = nil, origin: SessionOrigin? = nil, sequenceNumber: Int? = nil, serverModificationDate: Date? = nil,
    cancelTimer: (UUID) -> Void = DeviceActivityCenterUtil.removeStrategyTimerActivity
  ) -> Bool {
    guard let startTime,
      let current = activeSession, current.isActive, current.id == sessionId,
      current.blockedProfile.id == profileId,
      SharedData.getActiveSharedSession()?.id == sessionId
    else { return false }
    let newId = canonicalSessionId ?? sessionId
    if let canonicalSessionId, UUID(uuidString: canonicalSessionId) == nil { return false }
    let ownsCountdown = newId == sessionId && originDevice == SharedData.deviceSyncId.uuidString
    var adopted = current.toSnapshot()
    adopted.id = newId
    adopted.startTime = startTime
    adopted.timerEndTime = timerEndTime
    adopted.origin = origin
    adopted.usesCanonicalIdentity = canonicalSessionId != nil ? true : nil
    if newId != sessionId {
      adopted.breakStartTime = nil
      adopted.breakEndTime = nil
      adopted.breakEndDeadline = nil
      adopted.oneMoreMinuteStartTime = nil
      adopted.oneMoreMinuteDeadline = nil
      adopted.oneMoreMinuteUsed = false
      adopted.pinnedProfileConfig = nil
    }
    guard
      SharedData.adoptAuthoritativeSession(
        adopted, expectedSessionId: sessionId, now: startTime,
        onAdopt: {
          if newId != sessionId { self.appBlocker.activateRestrictions(for: BlockedProfiles.getSnapshot(for: current.blockedProfile)) }
        })
    else {
      errorMessage = "The session timing could not be saved."
      return false
    }
    if current.usesCanonicalIdentity == true && !ownsCountdown { self.cancelTimer(profileId, sessionId) } else if Self.isCountdownTag(current.tag) && !ownsCountdown { cancelTimer(profileId) }
    current.sessionServerModificationDate = newId == sessionId ? (serverModificationDate ?? current.sessionServerModificationDate) : serverModificationDate
    current.id = newId
    current.origin = origin
    current.sessionSequence = sequenceNumber ?? current.sessionSequence
    current.breakStartTime = adopted.breakStartTime
    current.breakEndTime = adopted.breakEndTime
    current.breakEndDeadline = adopted.breakEndDeadline
    current.oneMoreMinuteStartTime = adopted.oneMoreMinuteStartTime
    current.oneMoreMinuteDeadline = adopted.oneMoreMinuteDeadline
    current.oneMoreMinuteUsed = adopted.oneMoreMinuteUsed
    current.pinnedProfileConfigData = adopted.pinnedProfileConfig.flatMap { try? JSONEncoder().encode($0) }
    current.usesCanonicalIdentity = adopted.usesCanonicalIdentity
    current.startTime = startTime
    current.timerEndTime = timerEndTime
    do { try context.save() } catch {
      errorMessage = "The session timing could not be saved."
      Log.error("Failed to save adopted session timing", category: .sync)
      return false
    }
    return true
  }

  /// Start a session triggered by remote device
  func startRemoteSession(
    context: ModelContext,
    profileId: UUID,
    sessionId: UUID?,
    startTime: Date,
    timerEndTime: Date? = nil,
    originDevice: String? = nil,
    origin: SessionOrigin? = nil, sequenceNumber: Int? = nil, serverModificationDate: Date? = nil
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

      let existing = try getActiveSession(context: context)
      if let existing, existing.blockedProfile.id == profileId {
        activeSession = existing
        if sessionId?.uuidString != existing.id,
          existing.usesCanonicalIdentity == true || existing.sessionServerModificationDate != nil
        {
          guard let confirmed = existing.sessionServerModificationDate,
            let incoming = serverModificationDate, incoming > confirmed
          else {
            // An unconfirmed originating identity must join through CAS, including after restart.
            if existing.sessionServerModificationDate == nil, serverModificationDate != nil,
              !existing.sessionStartSyncPending
            {
              syncSessionStart(session: existing, context: context, confirmRemoteReplacement: true)
            }
            Log.info("Deferred remote replacement without newer server confirmation", category: .sync)
            return
          }
        }
        guard
          reconcileSessionTiming(
            sessionId: existing.id, profileId: profileId, startTime: startTime,
            timerEndTime: timerEndTime, originDevice: originDevice, context: context,
            canonicalSessionId: sessionId?.uuidString, origin: origin, sequenceNumber: sequenceNumber, serverModificationDate: serverModificationDate)
        else { throw NSError(domain: "RemoteSession", code: 2) }
        if let sequenceNumber {
          existing.sessionSequence = sequenceNumber
          try context.save()
        }
        return
      }
      if let existing,
        ProfileStartArbiter.decide(
          incomingStartTime: startTime, incomingProfileId: profileId,
          existingStartTime: existing.startTime, existingProfileId: existing.blockedProfile.id) == .reject
      {
        return
      }
      let id = sessionId?.uuidString ?? UUID().uuidString
      let candidate = SharedData.SessionSnapshot(
        id: id, tag: "remote-sync", blockedProfileId: profileId,
        startTime: startTime, timerEndTime: timerEndTime, forceStarted: true, origin: origin,
        usesCanonicalIdentity: sessionId != nil ? true : nil)
      let previousSharedId = SharedData.getActiveSharedSession()?.id
      guard
        SharedData.adoptAuthoritativeSession(
          candidate, expectedSessionId: previousSharedId, now: startTime,
          onAdopt: {
            self.appBlocker.activateRestrictions(for: BlockedProfiles.getSnapshot(for: profile))
          })
      else { throw NSError(domain: "RemoteSession", code: 1) }
      if let existing {
        finishDepartingSession(existing, context: context, syncDisplacedSession: true)
      }
      let adopted = BlockedProfileSession(
        tag: "remote-sync", blockedProfile: profile, forceStarted: true,
        startTime: startTime, id: id, origin: origin)
      adopted.usesCanonicalIdentity = candidate.usesCanonicalIdentity
      adopted.sessionSequence = sequenceNumber
      adopted.sessionServerModificationDate = serverModificationDate
      adopted.timerEndTime = timerEndTime
      context.insert(adopted)
      try context.save()
      activateSession(adopted, context: context)
      Log.info(
        "Started remote session for profile '\(profile.name)' with synced startTime",
        category: .strategy)
    } catch {
      errorMessage = [errorMessage, "The remote session could not be fully loaded or its timing saved. Open the app and check its state."]
        .compactMap { $0 }.joined(separator: "\n")
      Log.info("Error starting remote session - \(redactedErrorForLog(error))", category: .strategy)
    }
  }

  /// Stop a session triggered by remote device
  func stopRemoteSession(context: ModelContext, profileId: UUID, expectedSessionId: String? = nil, sequenceNumber: Int? = nil) {
    guard !processingRemoteChange else { return }
    processingRemoteChange = true

    defer { processingRemoteChange = false }

    guard let session = activeSession,
      session.blockedProfile.id == profileId
    else {
      Log.info("No matching active session to stop", category: .strategy)
      return
    }

    if let expectedSessionId, session.id != expectedSessionId { return }
    if sequenceNumber != nil, session.usesCanonicalIdentity == true && expectedSessionId == nil { return }
    if session.blockedProfile.profileSchemaVersion >= 2 {
      guard endV2Session(session, context: context) else { return }
    } else {
      _ = getStrategy(id: ManualBlockingStrategy.id).stopBlocking(context: context, session: session)
    }
    if let sequenceNumber {
      session.sessionSequence = sequenceNumber
      do { try context.save() } catch { Log.error("Failed to save remote completion sequence", category: .sync) }
    }

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
