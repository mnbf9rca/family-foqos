import CloudKit
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
  private let currentDate: () -> Date
  private let calendar: Calendar
  private weak var recoveryContext: ModelContext?
  private weak var pendingRecoverySave: ModelContext?

  /// #201: persisted intents for session-stops dropped by a failed/exhausted CAS write.
  /// Internal (not private) so Phase-E tests can assert routing without a live CloudKit call.
  let sessionStopOutbox: SessionStopOutbox

  @Published var elapsedTime: TimeInterval = 0
  @Published var timerTask: Task<Void, Never>?
  @Published var activeSession: BlockedProfileSession?
  private var remoteSessionGeneration = 0
  private var remoteStopsInFlight: Set<UUID> = []
  @Published private var remoteSessionRecords: [UUID: ProfileSessionRecord]

  var remotelyActiveProfileIds: Set<UUID> {
    Set(
      remoteSessionRecords.values.filter {
        isVisibleRemoteActiveRecord($0)
      }.map(\.profileId))
  }

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
    ratingManager: RatingManager = .shared,
    currentDate: @escaping () -> Date = Date.init,
    calendar: Calendar = .current
  ) {
    self.ratingManager = ratingManager
    self.currentDate = currentDate
    self.calendar = calendar
    self.geofenceEvaluator = geofenceEvaluator
    self.emergencyUnblockManager = emergencyUnblockManager
    self.liveActivityManager = liveActivityManager
    self.profileSyncManager = profileSyncManager
    self.sessionSyncService = sessionSyncService
    self.locationManager = locationManager
    self.remoteActiveDefaults = remoteActiveDefaults
    self.sessionStopOutbox = SessionStopOutbox(defaults: remoteActiveDefaults)
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
    self.remoteSessionRecords = RemotelyActiveStore.load(defaults: remoteActiveDefaults)
  }

  /// A V2 originating start registers its countdown before constructing any session.
  func startOriginatingSession(
    context: ModelContext, profile: BlockedProfiles, origin: SessionOrigin,
    durationOverrideMinutes: Int? = nil, now: Date = Date(), expectedVictimId: String? = nil, allowLinkForTag: Bool = false
  ) throws -> BlockedProfileSession {
    if let current = try controlSession(context: context), current.remote != nil {
      throw NSError(domain: "ProfileStart", code: 1, userInfo: [NSLocalizedDescriptionKey: "A session is already active. Stop it before starting another."])
    }
    let candidate = try prepareOriginatingCandidate(
      context: context, profile: profile, origin: origin, durationOverrideMinutes: durationOverrideMinutes,
      now: now, allowLinkForTag: allowLinkForTag)
    return try publishOriginatingCandidate(candidate, context: context, expectedVictimId: expectedVictimId, now: now, allowLinkForTag: allowLinkForTag)
  }

  private struct PreparedOriginatingSession {
    let profileId: UUID
    let id: String
    let origin: SessionOrigin
    let startTime: Date
    let timerEndTime: Date?
  }

  private func prepareOriginatingCandidate(
    context: ModelContext, profile: BlockedProfiles, origin: SessionOrigin,
    durationOverrideMinutes: Int? = nil, now: Date, allowLinkForTag: Bool
  ) throws -> PreparedOriginatingSession {
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
    return PreparedOriginatingSession(profileId: profile.id, id: candidateId, origin: origin, startTime: now, timerEndTime: deadline)
  }

  private func discardOriginatingCandidate(_ candidate: PreparedOriginatingSession) {
    if candidate.timerEndTime != nil { cancelTimer(candidate.profileId, candidate.id) }
  }

  private func publishOriginatingCandidate(
    _ prepared: PreparedOriginatingSession, context: ModelContext, expectedVictimId: String?, now: Date, allowLinkForTag: Bool
  ) throws -> BlockedProfileSession {
    var published = false
    defer { if !published { discardOriginatingCandidate(prepared) } }
    if let deadline = prepared.timerEndTime, deadline <= now {
      throw NSError(domain: "ProfileStart", code: 1, userInfo: [NSLocalizedDescriptionKey: "This session changed. Please try again."])
    }
    guard let profile = try BlockedProfiles.findProfile(byID: prepared.profileId, in: context) else {
      throw NSError(domain: "ProfileStart", code: 1, userInfo: [NSLocalizedDescriptionKey: "This session changed. Please try again."])
    }
    let origin = prepared.origin
    let candidate = BlockedProfileSession(
      tag: origin.key.map { origin.kind.rawValue + ":" + $0 } ?? origin.kind.rawValue,
      blockedProfile: profile, startTime: prepared.startTime, id: prepared.id, origin: origin)
    candidate.timerEndTime = prepared.timerEndTime
    candidate.sessionStartSyncPending = shouldSyncSessionChange
    context.insert(candidate)
    do {
      try saveSession(context)
      BlockedProfiles.updateSnapshot(for: profile)
      guard
        SharedData.commitOriginatingSession(
          candidate.toSnapshot(), expectedVictimId: expectedVictimId, now: now, allowLinkForTag: allowLinkForTag,
          onCommit: {
            SharedData.applyRestrictionsForCurrentState(process: .mainApp, liveSnapshot: nil, applier: self.appBlocker)
          })
      else { throw NSError(domain: "ProfileStart", code: 1, userInfo: [NSLocalizedDescriptionKey: "This session changed. Please try again."]) }
    } catch {
      profile.sessions.removeAll { $0.id == candidate.id }
      context.delete(candidate)
      do { try saveSession(context) } catch {
        Log.error("Failed to persist originating-session compensation", category: .session)
        throw error
      }
      if (error as NSError).domain == "ProfileStart" { throw error }
      throw NSError(domain: "ProfileStart", code: 1, userInfo: [NSLocalizedDescriptionKey: "Couldn’t start this profile. Please try again."])
    }
    published = true
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

  /// Preserve stopped identities and refuse to replace a newer cache version.
  private func acceptsSessionRecord(_ record: ProfileSessionRecord) -> Bool {
    guard let previous = remoteSessionRecords[record.profileId] else { return true }
    let sameSession = previous.matchesIdentity(of: record)
    if sameSession, !previous.isActive, record.isActive { return false }
    if sameSession, previous.sequenceNumber == record.sequenceNumber,
      previous.serverModificationDate == record.serverModificationDate, previous.isActive == record.isActive
    {
      return true
    }
    if let oldDate = previous.serverModificationDate, let newDate = record.serverModificationDate {
      return newDate > oldDate || (newDate == oldDate && sameSession && record.sequenceNumber > previous.sequenceNumber)
    }
    if previous.serverModificationDate != nil, record.serverModificationDate == nil, !sameSession { return false }
    return record.sequenceNumber > previous.sequenceNumber
  }

  @discardableResult
  func receiveSessionRecord(_ record: ProfileSessionRecord) -> Bool {
    guard acceptsSessionRecord(record) else { return false }
    if remoteSessionRecords[record.profileId] != record {
      remoteSessionRecords[record.profileId] = record
      RemotelyActiveStore.save(remoteSessionRecords, defaults: remoteActiveDefaults)
    }
    return true
  }

  func receiveSessionRecord(_ record: ProfileSessionRecord, context: ModelContext) throws -> Bool {
    let owner = try getActiveSession(context: context)
    guard acceptsSessionRecord(record) else { return false }
    guard record.isActive, let startedAt = record.startTime,
      let profile = try BlockedProfiles.findProfile(byID: record.profileId, in: context)
    else { return receiveSessionRecord(record) }
    if let owner, owner.blockedProfile.id == profile.id,
      record.sessionId == owner.id
        || (record.sessionId == nil && owner.usesCanonicalIdentity != true
          && abs(owner.startTime.timeIntervalSince(startedAt)) < 0.001)
    {
      return receiveSessionRecord(record)
    }
    let now = currentDate()
    switch sessionAdmission(
      profile: profile, sessionId: record.sessionId, startedAt: startedAt, deadline: record.validTimerEndTime,
      origin: record.origin, context: context, now: now)
    {
    case .eligible:
      return receiveSessionRecord(record)
    case .ended:
      guard recordStaleRemoteSession(profileId: profile.id, id: record.sessionId, start: startedAt, now: now) else {
        throw CocoaError(.fileWriteUnknown)
      }
      return false
    case .unavailable:
      throw CocoaError(.fileReadUnknown)
    }
  }

  @discardableResult
  func stopRemoteOnlySession(profileId: UUID, method: StopMethod = .manual, context: ModelContext, emergency: Bool = false) async throws -> Bool {
    _ = try getActiveSession(context: context)
    guard let captured = remoteSessionRecords[profileId], captured.isActive, remoteRecordMayAppear(captured, waitForLock: true),
      let profile = try BlockedProfiles.findProfile(byID: profileId, in: context)
    else { throw EmergencyUnblockError.noActiveSession }
    guard remoteStopsInFlight.insert(profileId).inserted else { throw EmergencyUnblockError.sessionChanged }
    defer { remoteStopsInFlight.remove(profileId) }
    let generation = remoteSessionGeneration
    if emergency {
      try await emergencyUnblockManager.authorizeEmergencyUnblock(profile: profile, context: context)
    } else {
      let validation = StartStopActionResolver.canStop(
        with: method, conditions: profile.stopConditions, sessionTag: nil,
        stopNFCTagIds: profile.stopNFCTagIds, stopQRCodeIds: profile.stopQRCodeIds,
        sessionOrigin: captured.origin, legacySession: profile.profileSchemaVersion < 2)
      guard validation.allowed else {
        throw NSError(domain: "RemoteStop", code: 1, userInfo: [NSLocalizedDescriptionKey: validation.errorMessage ?? "This session changed. Please try again."])
      }
      if let result = await geofenceEvaluator.evaluateGeofenceForStop(profile: profile, context: context), !result.isSatisfied {
        throw NSError(domain: "RemoteStop", code: 2, userInfo: [NSLocalizedDescriptionKey: result.failureMessage ?? "Location restriction not met."])
      }
    }
    _ = try getActiveSession(context: context)
    guard generation == remoteSessionGeneration,
      let current = remoteSessionRecords[profileId], current.isActive, current.matchesIdentity(of: captured), remoteRecordMayAppear(current, waitForLock: true),
      captured.sessionId != nil || captured.startTime != nil
    else { throw EmergencyUnblockError.sessionChanged }
    let result = await sessionSyncService.stopSession(
      profileId: profileId, expectedSessionId: captured.sessionId, expectedStart: captured.startTime,
      reportIdentityMismatch: true, allowRemoteLegacy: true)
    switch result {
    case .stopped:
      break
    case .alreadyStopped:
      _ = await confirmSessionState(profileId: profileId)
      return false
    case .conflict(let record):
      receiveSessionRecord(record)
      throw EmergencyUnblockError.sessionChanged
    case .error(let error):
      guard let cloudError = error as? CKError,
        [.networkUnavailable, .networkFailure, .serviceUnavailable, .zoneBusy, .requestRateLimited].contains(cloudError.code),
        sessionStopOutbox.enqueue(profileId: profileId, expectedStart: captured.startTime, expectedSessionId: captured.sessionId, allowRemoteLegacy: captured.sessionId == nil)
      else { throw error }
    }
    // A successful CAS or durable intent remains accepted if its own stop echo arrives first.
    recordLocalCompletion(profileId: profileId, sessionId: captured.sessionId, startTime: captured.startTime, endTime: Date())
    if emergency { emergencyUnblockManager.recordAndEnqueueUnblock() }
    return true
  }

  static let sessionConfirmationFailureMessage = "iCloud can't be reached, and this profile was last seen active on another device. Stop it from here first (an Emergency Unblock also works), or try again when you're online."
  static let nfcUnavailableStopMessage = "This profile stops with an NFC tag, but this device can't read NFC. Hint: you can use an Emergency Unblock instead if you have any left."

  func confirmSessionState(profileId: UUID) async -> Bool {
    let generation = remoteSessionGeneration
    let previous = remoteSessionRecords[profileId]
    let result = await sessionSyncService.fetchSession(profileId: profileId)
    guard generation == remoteSessionGeneration else { return false }
    switch result {
    case .found(let record):
      guard record.profileId == profileId else { return false }
      if let context = recoveryContext {
        _ = try? receiveSessionRecord(record, context: context)
      } else {
        receiveSessionRecord(record)
      }
      return true
    case .notFound:
      guard remoteSessionRecords[profileId] == previous else { return false }
      clearRemoteSession(profileId: profileId)
      return true
    case .error(let error):
      Log.error("Could not confirm remote session: \(redactedErrorForLog(error))", category: .sync)
      return false
    }
  }

  func clearRemoteSession(profileId: UUID) {
    remoteSessionGeneration += 1
    remoteSessionRecords.removeValue(forKey: profileId)
    RemotelyActiveStore.save(remoteSessionRecords, defaults: remoteActiveDefaults)
  }

  func clearAllRemoteSessionActive() {
    remoteSessionGeneration += 1
    remoteSessionRecords = [:]
    RemotelyActiveStore.save(remoteSessionRecords, defaults: remoteActiveDefaults)
  }

  private func recordLocalCompletion(profileId: UUID, sessionId: String?, startTime: Date?, endTime: Date, requireLegacyIdentity: Bool = false) {
    guard sessionId != nil || startTime != nil,
      var record = remoteSessionRecords[profileId],
      !requireLegacyIdentity || sessionId != nil || record.sessionId == nil,
      record.matchesCompletion(expectedSessionId: sessionId, expectedStart: startTime, deviceId: SharedData.deviceSyncId.uuidString, allowRemoteLegacy: true)
    else { return }
    record.completeLocally(at: endTime)
    remoteSessionRecords[profileId] = record
    RemotelyActiveStore.save(remoteSessionRecords, defaults: remoteActiveDefaults)
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

  private var didCleanOrphanedSessionsAtLaunch = false

  func loadActiveSession(context: ModelContext) throws {
    if !didCleanOrphanedSessionsAtLaunch && !profileSyncManager.isReplacingLocalProfiles {
      do {
        try OrphanedSessionCleanup.run(context: context)
        didCleanOrphanedSessionsAtLaunch = true
      } catch {
        Log.error("Launch orphan cleanup deferred: \(redactedErrorForLog(error))", category: .session)
      }
    }
    activeSession = try getActiveSession(context: context)

    if activeSession?.isActive == true {
      startTimer()
      if let session = activeSession,
        session.blockedProfile.profileSchemaVersion >= 2 || SharedData.getActiveSharedSession()?.id == session.id
      {
        reconcileGrants(context: context)
      }

      // Start live activity for existing session if one exists
      // live activities can only be started when the app is in the foreground
      if let session = activeSession {
        startSessionActivity(session)
        if shouldRetryStart(session) {
          syncSessionStart(session: session, context: context)
        }

        // Re-register stop schedule on app launch
        let failures = DeviceActivityCenterUtil.scheduleStopActivity(for: session.blockedProfile)
        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
      }
    } else {
      reconcileGrants(context: context)
      // Close live activity if no session is active and a scheduled session might have ended
      liveActivityManager.endSessionActivity()
      // Re-attempt migration for profiles deferred due to active sessions
      if ProfileMigrationUtil.migrateProfilesIfNeeded(context: context) > 0 {
        scheduleReconciler(context)
      }
    }
  }

  func discardDeletedProfileSession(profileId: UUID) {
    guard activeSession?.blockedProfile.id == profileId else { return }
    stopTimer()
    activeSession = nil
    elapsedTime = 0
    liveActivityManager.endSessionActivity()
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
    if !isBlocking, let remote = try? controlSession(context: context)?.remote {
      guard activeProfile?.id == remote.profileId else {
        errorMessage = "A session is already active. Stop it before starting another."
        return
      }
      Task {
        do { try await stopRemoteOnlySession(profileId: remote.profileId, context: context) } catch { errorMessage = error.localizedDescription }
      }
      return
    }
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
          guard self.activeSession?.id == session.id else { return }
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

  struct ControlSession {
    let id: String
    let blockedProfile: BlockedProfiles
    let origin: SessionOrigin?
    let tag: String?
    let local: BlockedProfileSession?
    let remote: ProfileSessionRecord?
  }

  func remoteOnlySessionRecord(profileIds: Set<UUID>) -> ProfileSessionRecord? {
    remoteSessionRecords.values.filter {
      profileIds.contains($0.profileId) && isVisibleRemoteActiveRecord($0)
        && !(activeSession?.isActive == true && activeSession?.blockedProfile.id == $0.profileId)
    }.max {
      ProfileStartArbiter.decide(
        incomingStartTime: $1.startTime ?? .distantPast, incomingProfileId: $1.profileId,
        existingStartTime: $0.startTime ?? .distantPast, existingProfileId: $0.profileId) == .adopt
    }
  }

  func controlSession(context: ModelContext) throws -> ControlSession? {
    if let local = try getActiveSession(context: context) {
      return ControlSession(id: local.id, blockedProfile: local.blockedProfile, origin: local.origin, tag: local.tag, local: local, remote: nil)
    }
    guard sessionStopOutbox.intents != nil else { throw CocoaError(.fileReadCorruptFile) }
    let profiles = try BlockedProfiles.fetchProfiles(in: context).valid
    guard let remote = remoteOnlySessionRecord(profileIds: Set(profiles.map(\.id))),
      remoteRecordMayAppear(remote, waitForLock: true),
      let profile = profiles.first(where: { $0.id == remote.profileId }), let start = remote.startTime
    else { return nil }
    return ControlSession(
      id: remote.sessionId ?? "legacy:\(remote.profileId):\(start.timeIntervalSince1970)",
      blockedProfile: profile, origin: remote.origin, tag: nil, local: nil, remote: remote)
  }

  private func controlSessionIsCurrent(_ session: ControlSession, context: ModelContext) -> Bool {
    guard let current = try? controlSession(context: context) else { return false }
    return current.id == session.id && current.blockedProfile.id == session.blockedProfile.id
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
      if let session = try controlSession(context: context) {
        if session.blockedProfile.profileSchemaVersion < 2, session.local != nil {
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
        guard let victim = try controlSession(context: context), victim.id == pending.victimId
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
        await commitTagTransition(pending, context: context, now: now, stopMethod: .tag(event))
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
      if let victim = try controlSession(context: context) {
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
        let stopResult = tagStopResult(event, session: victim)
        if !stopResult.allowed {
          if target == nil { tagScanError = stopResult.errorMessage }
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
    let specific = event.type == .nfc ? profile.startTriggers.specificNFC : profile.startTriggers.specificQR
    let keys = event.type == .nfc ? profile.startNFCTagIds : profile.startQRCodeIds
    if specific, !keys.contains(event.matchingKey ?? ""),
      let matched = keys.first(where: event.matchesStoredKey), let namespace = event.namespace
    {
      return SessionOrigin(kind: event.type == .nfc ? .nfc : .qr, key: matched, namespace: namespace)
    }
    return event.origin
  }

  private func tagStopResult(_ event: TagEvent, session: ControlSession) -> StopValidationResult {
    StartStopActionResolver.canStop(
      with: .tag(event), conditions: session.blockedProfile.stopConditions,
      sessionTag: session.tag, stopNFCTagIds: session.blockedProfile.stopNFCTagIds,
      stopQRCodeIds: session.blockedProfile.stopQRCodeIds, sessionOrigin: session.origin,
      legacySession: session.blockedProfile.profileSchemaVersion < 2)
  }

  private func commitRemoteTagTransition(
    _ pending: PendingTagSwitch, victim: ControlSession, method: StopMethod, context: ModelContext, now: Date
  ) async {
    var candidate: PreparedOriginatingSession?
    do {
      if let target = pending.targetProfileId {
        guard let profile = try BlockedProfiles.findProfile(byID: target, in: context) else { throw ProfileTagLink.Failure.invalidTag }
        candidate = try prepareOriginatingCandidate(
          context: context, profile: profile, origin: admittedTagOrigin(pending.event, profile: profile),
          now: now, allowLinkForTag: true)
      }
      guard tagOperationId == pending.operationId, controlSessionIsCurrent(victim, context: context) else {
        throw EmergencyUnblockError.sessionChanged
      }
      _ = try await stopRemoteOnlySession(profileId: victim.blockedProfile.id, method: method, context: context)
      guard tagOperationId == pending.operationId, try controlSession(context: context) == nil else {
        throw EmergencyUnblockError.sessionChanged
      }
      if let prepared = candidate {
        // publishOriginatingCandidate owns compensation if its final save/publication fails.
        candidate = nil
        _ = try publishOriginatingCandidate(prepared, context: context, expectedVictimId: nil, now: currentDate(), allowLinkForTag: true)
      }
      cancelTagOperation()
    } catch {
      if let candidate { discardOriginatingCandidate(candidate) }
      Log.error("Remote session transition failed: \(redactedErrorForLog(error))", category: .sync)
      cancelTagOperation()
      errorMessage = error.localizedDescription
    }
  }

  private func commitTagTransition(_ pending: PendingTagSwitch, context: ModelContext, now: Date, stopMethod: StopMethod? = nil) async {
    if let victim = try? controlSession(context: context), victim.id == pending.victimId, victim.remote != nil {
      await commitRemoteTagTransition(pending, victim: victim, method: stopMethod ?? .tag(pending.event), context: context, now: now)
      return
    }
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
        if (try? controlSession(context: context)?.remote?.profileId) == profileId {
          guard requiredUnlockAtStart || !requireUnlock() else {
            throw IntentError.unexpected("Device unlock is now required. Retry the action under the new setting.")
          }
          try await stopRemoteOnlySession(profileId: profileId, context: context)
          return
        }
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
  func emergencyUnblock(context: ModelContext) async throws {
    let displayed = activeSession.flatMap { $0.isPersistentModelValid && $0.isActive ? $0 : nil }
    let displayedId = displayed?.id
    if let displayedId, let owner = SharedData.readSessionState()?.active,
      owner.endTime == nil, owner.id != displayedId
    {
      throw EmergencyUnblockError.sessionChanged
    }
    let session: BlockedProfileSession?
    do {
      session = try getActiveSession(context: context)
    } catch let error as CocoaError where error.code == .fileReadCorruptFile {
      guard let displayed, displayed.modelContext === context, displayed.isPersistentModelValid,
        displayed.isActive, displayed.blockedProfile.profileSchemaVersion >= 2
      else { throw error }
      session = displayed
    }
    if let displayedId, let session, session.id != displayedId {
      throw EmergencyUnblockError.sessionChanged
    }
    if displayedId == nil, session == nil, let remote = try controlSession(context: context)?.remote {
      try await stopRemoteOnlySession(profileId: remote.profileId, context: context, emergency: true)
      return
    }
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
  private func shouldRetryStart(_ session: BlockedProfileSession) -> Bool {
    session.tag != "remote-sync"
      && (session.sessionStartSyncPending
        || (session.sessionSequence == nil && (session.origin?.kind == .schedule || session.tag == session.blockedProfile.id.uuidString)))
  }

  private func publicationAdmission(_ candidate: SharedData.SessionSnapshot, context: ModelContext) -> SessionAdmission {
    guard profileSyncManager.isEnabled,
      let state = SharedData.readSessionState(for: candidate.blockedProfileId),
      let profile = try? BlockedProfiles.findProfile(byID: candidate.blockedProfileId, in: context)
    else { return .unavailable }
    guard let owner = state.active, owner.id == candidate.id,
      owner.blockedProfileId == candidate.blockedProfileId, owner.endTime == nil
    else { return .ended }
    guard owner.startTime == candidate.startTime, owner.timerEndTime == candidate.timerEndTime else {
      return .unavailable
    }
    return sessionAdmission(
      profile: profile, sessionId: candidate.id, startedAt: candidate.startTime,
      deadline: candidate.timerEndTime, origin: candidate.origin, context: context, now: currentDate())
  }

  private func syncSessionStart(session: BlockedProfileSession, context: ModelContext, confirmRemoteReplacement: Bool = false) {
    guard shouldSyncSessionChange || (confirmRemoteReplacement && profileSyncManager.isEnabled),
      session.tag != "remote-sync"
    else { return }
    let candidate = session.toSnapshot()
    guard publicationAdmission(candidate, context: context) == .eligible else { return }
    let profileId = candidate.blockedProfileId

    if !session.sessionStartSyncPending {
      session.sessionStartSyncPending = true
      do { try saveSession(context) } catch {
        session.sessionStartSyncPending = false
        Log.error("Failed to save pending session start", category: .sync)
        return
      }
    }
    let previousTask = sessionSyncTask
    sessionSyncTask = Task {
      await previousTask?.value
      guard session.sessionStartSyncPending, publicationAdmission(candidate, context: context) == .eligible,
        let pending = sessionStopOutbox.intents
      else { return }
      for intent in pending
      where intent.profileId == profileId
        && (intent.expectedSessionId != nil || intent.expectedStart != nil)
      {
        guard await retireSession(intent, retryConflict: false) else { return }
      }

      // At most one retry after retiring an independently proven stale winner.
      for attempt in 0..<2 {
        guard publicationAdmission(candidate, context: context) == .eligible else { return }
        let result = await sessionSyncService.startSession(
          profileId: profileId, startTime: candidate.startTime, timerEndTime: candidate.timerEndTime,
          sessionId: candidate.id, origin: candidate.origin,
          validate: { self.publicationAdmission(candidate, context: context) == .eligible })
        switch result {
        case .started(let sequence, let confirmed):
          let admission = publicationAdmission(candidate, context: context)
          guard admission == .eligible else {
            let now = currentDate()
            if admission == .ended, recordStaleRemoteSession(profileId: profileId, id: candidate.id, start: candidate.startTime, now: now) {
              _ = await retireSession(.init(profileId: profileId, expectedSessionId: candidate.id, expectedStart: candidate.startTime))
            }
            return
          }
          var record = ProfileSessionRecord(profileId: profileId, serverModificationDate: confirmed)
          record.applyUpdate(
            isActive: true, sequenceNumber: sequence, deviceId: SharedData.deviceSyncId.uuidString,
            startTime: candidate.startTime, timerEndTime: candidate.timerEndTime, sessionId: candidate.id, origin: candidate.origin)
          guard receiveSessionRecord(record) else { return }
          do { try saveSessionReceipt(session, sequence: sequence, modifiedAt: confirmed, context: context) } catch { Log.error("Failed to save confirmed session start", category: .sync) }
          return

        case .alreadyActive(let existing):
          guard publicationAdmission(candidate, context: context) == .eligible, let startedAt = existing.startTime else { return }
          let now = currentDate()
          if existing.sessionId != candidate.id {
            if let newer = remoteSessionRecords[profileId], newer.isActive, !acceptsSessionRecord(existing) { return }
            switch sessionAdmission(
              profile: session.blockedProfile, sessionId: existing.sessionId, startedAt: startedAt,
              deadline: existing.validTimerEndTime, origin: existing.origin, context: context, now: now)
            {
            case .unavailable: return
            case .eligible: break
            case .ended:
              guard recordStaleRemoteSession(profileId: profileId, id: existing.sessionId, start: startedAt, now: now) else { return }
              let stop = SessionStopOutbox.Intent(
                profileId: profileId, expectedSessionId: existing.sessionId, expectedStart: startedAt,
                allowRemoteLegacy: existing.sessionId == nil ? true : nil)
              guard attempt == 0, await retireSession(stop) else { return }
              continue
            }
          }
          guard receiveSessionRecord(existing) else { return }
          _ = reconcileSessionTiming(
            sessionId: candidate.id, profileId: profileId, startTime: startedAt, timerEndTime: existing.validTimerEndTime,
            originDevice: existing.sessionOriginDevice, context: context, canonicalSessionId: existing.sessionId,
            origin: existing.origin, sequenceNumber: existing.sequenceNumber, serverModificationDate: existing.serverModificationDate)
          return

        case .error(let error):
          Log.info("Failed to sync session start - \(redactedErrorForLog(error))", category: .strategy)
          return
        }
      }
    }
  }

  private func retireSession(_ intent: SessionStopOutbox.Intent, retryConflict: Bool = true) async -> Bool {
    let endTime = intent.endTime ?? currentDate()
    func stop() async -> SessionSyncService.StopResult {
      await sessionSyncService.stopSession(
        profileId: intent.profileId, endTime: endTime, expectedSessionId: intent.expectedSessionId,
        expectedStart: intent.expectedStart, allowRemoteLegacy: intent.allowRemoteLegacy == true)
    }
    var result = await stop()
    if retryConflict, case .conflict = result { result = await stop() }
    switch result {
    case .stopped, .alreadyStopped:
      sessionStopOutbox.resolve(
        profileId: intent.profileId, expectedSessionId: intent.expectedSessionId, expectedStart: intent.expectedStart)
      if let record = await sessionSyncService.cachedSession(profileId: intent.profileId) {
        if let context = recoveryContext {
          _ = try? receiveSessionRecord(record, context: context)
        } else {
          receiveSessionRecord(record)
        }
      } else {
        recordLocalCompletion(
          profileId: intent.profileId, sessionId: intent.expectedSessionId, startTime: intent.expectedStart,
          endTime: endTime, requireLegacyIdentity: intent.expectedSessionId == nil)
      }
      return true
    case .conflict, .error:
      return false
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
    endTime: Date = Date(), expectedSessionId: String? = nil, expectedStart: Date? = nil, allowRemoteLegacy: Bool = false
  ) async {
    switch result {
    case .stopped:
      recordLocalCompletion(profileId: profileId, sessionId: expectedSessionId, startTime: expectedStart, endTime: endTime)
      sessionStopOutbox.resolve(profileId: profileId, expectedSessionId: expectedSessionId, expectedStart: expectedStart)
      Log.info("Session stop synced", category: .strategy)
    case .alreadyStopped:
      sessionStopOutbox.resolve(profileId: profileId, expectedSessionId: expectedSessionId, expectedStart: expectedStart)
      Log.info("Session was already stopped", category: .strategy)
    case .conflict(let current):
      Log.info("Stop conflict, current seq=\(current.sequenceNumber)", category: .strategy)
      // Retry stop once
      let retryResult = await sessionSyncService.stopSession(
        profileId: profileId, endTime: endTime, expectedSessionId: expectedSessionId, expectedStart: expectedStart, allowRemoteLegacy: allowRemoteLegacy)
      switch retryResult {
      case .stopped:
        recordLocalCompletion(profileId: profileId, sessionId: expectedSessionId, startTime: expectedStart, endTime: endTime)
        sessionStopOutbox.resolve(profileId: profileId, expectedSessionId: expectedSessionId, expectedStart: expectedStart)
        Log.info("Stop retry succeeded", category: .strategy)
      case .alreadyStopped:
        sessionStopOutbox.resolve(profileId: profileId, expectedSessionId: expectedSessionId, expectedStart: expectedStart)
        Log.info("Stop retry found session already stopped", category: .strategy)
      case .conflict, .error:
        Log.info("Stop retry failed", category: .strategy)
        // #201: persist the dropped stop intent for foreground re-drive instead of losing it.
        sessionStopOutbox.enqueue(
          profileId: profileId, expectedStart: expectedStart, expectedSessionId: expectedSessionId,
          allowRemoteLegacy: allowRemoteLegacy, endTime: endTime)
      }
    case .error(let error):
      Log.info("Failed to sync session stop - \(redactedErrorForLog(error))", category: .strategy)
      // #201: persist the dropped stop intent for foreground re-drive instead of losing it.
      sessionStopOutbox.enqueue(
        profileId: profileId, expectedStart: expectedStart, expectedSessionId: expectedSessionId,
        allowRemoteLegacy: allowRemoteLegacy, endTime: endTime)
    }
  }

  /// #201: re-drive persisted session-stop intents. Wired to scenePhase `.active` in `FoqosApp`.
  func drainSessionStopOutbox() async {
    if let context = recoveryContext {
      do { _ = try getActiveSession(context: context) } catch { return }
    }
    guard let pending = sessionStopOutbox.intents else { return }
    for intent in pending { _ = await retireSession(intent) }
    guard let context = recoveryContext else { return }
    if let session = try? getActiveSession(context: context),
      shouldRetryStart(session)
    {
      syncSessionStart(session: session, context: context)
      await sessionSyncTask?.value
    }

    // Retain active receipts on transient apply failure so foreground can retry the same delivery.
    guard profileSyncManager.isEnabled else { return }
    for record in Array(remoteSessionRecords.values) where record.isActive && record.lastModifiedBy != SharedData.deviceSyncId.uuidString {
      guard (try? receiveSessionRecord(record, context: context)) == true,
        let startedAt = record.startTime,
        let profile = try? BlockedProfiles.findProfile(byID: record.profileId, in: context),
        !profile.needsAppSelection,
        activeSession?.id != record.sessionId || activeSession?.blockedProfile.id != record.profileId
          || (activeSession?.sessionSequence ?? Int.min) < record.sequenceNumber
      else { continue }
      startRemoteSession(
        context: context, profileId: record.profileId, sessionId: record.sessionId.flatMap(UUID.init(uuidString:)),
        startTime: startedAt, timerEndTime: record.validTimerEndTime, originDevice: record.sessionOriginDevice,
        origin: record.origin, sequenceNumber: record.sequenceNumber, serverModificationDate: record.serverModificationDate)
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
      case .ended(let endedSession):
        let endedProfile = endedSession.blockedProfile
        self.recordDepartingSessionCompletion(endedSession, now: endedSession.endTime ?? self.currentDate())
        let sharedSession = SharedData.getActiveSharedSession()
        let sharedReplacement = sharedSession.map { $0.id != endedSession.id } ?? false
        let sameProfileReplacement =
          (self.activeSession.map { $0.id != endedSession.id && $0.blockedProfile.id == endedProfile.id } ?? false)
          || (sharedSession.map { $0.id != endedSession.id && $0.blockedProfileId == endedProfile.id } ?? false)
        if !sameProfileReplacement && endedProfile.profileSchemaVersion < 2 {
          DeviceActivityCenterUtil.removeStrategyTimerActivity(profileId: endedProfile.id)
        }
        if self.activeSession?.id == endedSession.id { self.activeSession = nil }
        // Delayed outgoing callbacks must not clear the replacement's activity or grants.
        if !sharedReplacement && self.activeSession == nil {
          self.timersUtil.cancelAll()

          self.liveActivityManager.endSessionActivity()
          self.scheduleReminder(profile: endedProfile)

          self.stopTimer()
          self.elapsedTime = 0

          // Refresh widgets when session ends
          WidgetCenter.shared.reloadTimelines(ofKind: "ProfileControlWidget")

          DeviceActivityCenterUtil.removeAllBreakTimerActivities()
        }

        if !sameProfileReplacement {
          DeviceActivityCenterUtil.removeOneMoreMinuteActivity(for: endedProfile)
          self.migrateDepartingProfile(endedProfile)
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

  private enum SessionAdmission: Equatable {
    case eligible, ended, unavailable
  }

  private func sessionAdmission(
    profile: BlockedProfiles, sessionId: String?, startedAt: Date, deadline: Date?,
    origin: SessionOrigin?, context: ModelContext, now: Date, waitForLock: Bool = true
  ) -> SessionAdmission {
    guard let state = SharedData.readSessionState(for: profile.id, waitForLock: waitForLock), let pending = sessionStopOutbox.intents else {
      return .unavailable
    }
    let matches: (String?, Date?) -> Bool = { expectedId, expectedStart in
      if let expectedId { return sessionId == expectedId }
      guard sessionId == nil, let expectedStart else { return false }
      return abs(startedAt.timeIntervalSince(expectedStart)) < 0.001
    }
    if state.completed.contains(where: {
      $0.blockedProfileId == profile.id && $0.endTime != nil
        && matches($0.usesCanonicalIdentity == true ? $0.id : nil, $0.startTime)
    })
      || pending.contains(where: {
        $0.profileId == profile.id && matches($0.expectedSessionId, $0.expectedStart)
      })
    {
      return .ended
    }
    if profile.sessions.valid.contains(where: {
      $0.endTime != nil && matches($0.usesCanonicalIdentity == true || $0.id == sessionId ? $0.id : nil, $0.startTime)
    }) {
      return .ended
    }
    if let sessionId {
      do {
        if let row = try BlockedProfileSession.findSession(byID: sessionId, in: context),
          row.blockedProfile.id != profile.id || row.endTime != nil
        {
          return .ended
        }
      } catch {
        return .unavailable
      }
    }
    var settings = state.profile ?? BlockedProfiles.getSnapshot(for: profile)
    settings.scheduleLastStoppedAt = SharedData.latestScheduleStop(
      now: now, settings.scheduleLastStoppedAt, profile.scheduleLastStoppedAt)
    return SharedData.sessionTimingAllowsAdmission(
      startedAt: startedAt, deadline: deadline, origin: origin, profile: settings, now: now, calendar: calendar
    ) ? .eligible : .ended
  }

  private func isVisibleRemoteActiveRecord(_ record: ProfileSessionRecord) -> Bool {
    record.isActive && (record.sessionOriginDevice ?? record.lastModifiedBy) != SharedData.deviceSyncId.uuidString
      && remoteRecordMayAppear(record)
  }

  private func remoteRecordMayAppear(_ record: ProfileSessionRecord, waitForLock: Bool = false) -> Bool {
    guard let startedAt = record.startTime else { return true }
    let now = currentDate()
    if let context = recoveryContext {
      do {
        if let profile = try BlockedProfiles.findProfile(byID: record.profileId, in: context) {
          return sessionAdmission(
            profile: profile, sessionId: record.sessionId, startedAt: startedAt, deadline: record.validTimerEndTime,
            origin: record.origin, context: context, now: now, waitForLock: waitForLock) == .eligible
        }
      } catch { return false }
    }
    guard let state = SharedData.readSessionState(for: record.profileId, waitForLock: waitForLock) else { return false }
    guard let profile = state.profile else { return true }
    return SharedData.sessionTimingAllowsAdmission(
      startedAt: startedAt, deadline: record.validTimerEndTime, origin: record.origin,
      profile: profile, now: now, calendar: calendar)
  }

  @discardableResult
  private func recordStaleRemoteSession(profileId: UUID, id: String?, start: Date, now: Date) -> Bool {
    if let id, UUID(uuidString: id) == nil { return false }
    guard
      !profileSyncManager.isEnabled
        || sessionStopOutbox.enqueue(
          profileId: profileId, expectedStart: start, expectedSessionId: id, allowRemoteLegacy: id == nil, endTime: now)
    else { return false }
    recordLocalCompletion(
      profileId: profileId, sessionId: id, startTime: start, endTime: now, requireLegacyIdentity: id == nil)
    return true
  }

  private func getActiveSession(context: ModelContext) throws -> BlockedProfileSession? {
    guard !ScreenshotDemoMode.isActive else { return try BlockedProfileSession.mostRecentActiveSession(in: context) }
    recoveryContext = context
    let now = currentDate()
    if profileSyncManager.isReplacingLocalProfiles { throw CocoaError(.fileReadUnknown) }

    // A monitor can commit a new owner while SwiftData saves. Re-read before returning it.
    for _ in 0..<3 {
      guard let state = SharedData.readSessionState() else { throw CocoaError(.fileReadCorruptFile) }
      if let ended = state.active, ended.endTime != nil {
        guard SharedData.recoverEndedSession(ended) || SharedData.readSessionState()?.active != ended else {
          throw CocoaError(.fileWriteUnknown)
        }
        continue
      }
      try importCompletedSessions(state.completed, context: context)
      guard let ready = SharedData.readSessionState() else { throw CocoaError(.fileReadCorruptFile) }
      guard ready.active == state.active, ready.completed.isEmpty else { continue }
      let live = ready.active
      let rows = try context.fetch(FetchDescriptor<BlockedProfileSession>())
      let liveRow = live.flatMap { slot in rows.first { $0.id == slot.id && $0.blockedProfile.id == slot.blockedProfileId } }
      if let live, let liveRow, liveRow.endTime != nil {
        guard
          SharedData.recoverEndedSession(liveRow.toSnapshot(), replacing: live)
            || SharedData.readSessionState()?.active != live
        else { throw CocoaError(.fileWriteUnknown) }
        continue
      }
      var owner = liveRow
      var needsSave = false
      if let live, liveRow?.toSnapshot() != live {
        owner = try BlockedProfileSession.stageSessionSnapshot(live, in: context)
        needsSave = owner != nil
      }
      let displaced = rows.filter { $0.isActive && $0.blockedProfile.profileSchemaVersion >= 2 && $0.id != owner?.id }
      for row in displaced {
        // Bound inferred history by the owner's start or a recorded completion for this profile.
        let latestEnd = row.blockedProfile.sessions.valid.compactMap(\.endTime)
          .filter { $0 >= row.startTime && $0 <= now }.max()
        let firstBound = [live?.startTime, latestEnd].compactMap { $0 }.filter { $0 >= row.startTime }.min()
        row.endTime = min(firstBound ?? row.startTime, max(row.startTime, now))
        row.origin = nil
        row.timerEndTime = nil
        row.sessionStartSyncPending = false
        if row.breakStartTime != nil, row.breakEndTime == nil { row.breakEndTime = row.endTime }
        row.breakEndDeadline = nil
        row.oneMoreMinuteStartTime = nil
        row.oneMoreMinuteDeadline = nil
        row.pinnedProfileConfigData = nil
      }
      if needsSave || !displaced.isEmpty || pendingRecoverySave === context {
        pendingRecoverySave = context
        try saveSession(context)
        pendingRecoverySave = nil
      }
      for row in displaced { cancelTimer(row.blockedProfile.id, row.id) }

      guard let checked = SharedData.readSessionState() else { throw CocoaError(.fileReadCorruptFile) }
      guard checked.active == state.active, checked.completed.isEmpty else { continue }
      let resolved =
        owner
        ?? rows.filter { $0.isActive && $0.blockedProfile.profileSchemaVersion < 2 }
        .max(by: { $0.startTime < $1.startTime })
      if activeSession?.id != resolved?.id {
        activeSession = resolved
        if resolved == nil {
          stopTimer()
          liveActivityManager.endSessionActivity()
          elapsedTime = 0
        } else {
          startTimer()
        }
      } else if activeSession !== resolved {
        activeSession = resolved
      }
      return resolved
    }
    throw CocoaError(.fileReadUnknown)
  }

  private func importCompletedSessions(_ completions: [SharedData.SessionSnapshot], context: ModelContext) throws {
    for completion in completions {
      guard let endedAt = completion.endTime else { throw CocoaError(.fileReadCorruptFile) }
      let id = completion.usesCanonicalIdentity == true ? completion.id : nil
      if let row = try BlockedProfileSession.stageSessionSnapshot(completion, in: context) {
        let profile = row.blockedProfile
        let sharedStamp = SharedData.snapshot(for: profile.id.uuidString)?.scheduleLastStoppedAt
        profile.scheduleLastStoppedAt = SharedData.latestScheduleStop(profile.scheduleLastStoppedAt, sharedStamp)
        try saveSession(context)
      }
      if profileSyncManager.isEnabled {
        guard
          sessionStopOutbox.enqueue(
            profileId: completion.blockedProfileId, expectedStart: completion.startTime, expectedSessionId: id,
            endTime: endedAt)
        else { throw CocoaError(.fileWriteUnknown) }
      }
      recordLocalCompletion(
        profileId: completion.blockedProfileId, sessionId: id, startTime: completion.startTime,
        endTime: endedAt, requireLegacyIdentity: id == nil)
      guard SharedData.acknowledgeCompletedSession(completion) else { throw CocoaError(.fileWriteUnknown) }
      if profileSyncManager.isEnabled {
        let intent = SessionStopOutbox.Intent(
          profileId: completion.blockedProfileId, expectedSessionId: id, expectedStart: completion.startTime, endTime: endedAt)
        let previousTask = sessionSyncTask
        sessionSyncTask = Task {
          await previousTask?.value
          _ = await self.retireSession(intent)
        }
      }
      if SharedData.endedSessionHadOpenGrant(completion) { timersUtil.cancelAllNotifications() }
      if let profile = try BlockedProfiles.findProfile(byID: completion.blockedProfileId, in: context),
        profile.profileSchemaVersion < 2
      {
        DeviceActivityCenterUtil.removeStrategyTimerActivity(profileId: profile.id)
        migrateDepartingProfile(profile)
      }
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
          guard self.activeSession?.id == session.id else { return }
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
          guard self.activeSession?.id == session.id else { return }
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
    if let current = try? controlSession(context: context), current.remote != nil {
      return "A session is already active. Stop it before starting another."
    }
    return rejectionForStart(profile) {
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
    recordDepartingSessionCompletion(session, now: now, syncDisplacedSession: syncDisplacedSession)
    WidgetCenter.shared.reloadTimelines(ofKind: "ProfileControlWidget")
    return saved
  }

  private func recordDepartingSessionCompletion(_ session: BlockedProfileSession, now: Date, syncDisplacedSession: Bool = false) {
    recordLocalCompletion(
      profileId: session.blockedProfile.id, sessionId: session.usesCanonicalIdentity == true ? session.id : nil,
      startTime: session.startTime, endTime: now)
    if shouldSyncSessionChange || (syncDisplacedSession && profileSyncManager.isEnabled) {
      let profileId = session.blockedProfile.id
      let expectedSessionId = session.usesCanonicalIdentity == true ? session.id : nil
      let expectedStart = session.startTime
      sessionStopOutbox.enqueue(profileId: profileId, expectedStart: expectedStart, expectedSessionId: expectedSessionId, allowRemoteLegacy: true)
      let previousTask = sessionSyncTask
      sessionSyncTask = Task {
        await previousTask?.value
        let result = await sessionSyncService.stopSession(profileId: profileId, endTime: now, expectedSessionId: expectedSessionId, expectedStart: expectedStart, allowRemoteLegacy: true)
        await handleStopResult(result, profileId: profileId, endTime: now, expectedSessionId: expectedSessionId, expectedStart: expectedStart, allowRemoteLegacy: true)
      }
    }
  }

  @discardableResult
  private func endV2Session(_ session: BlockedProfileSession, context: ModelContext, now: Date = Date(), emergency: Bool = false, recordSuccessfulUse: Bool = false) -> Bool {
    guard
      SharedData.completeSession(
        expectedSessionId: session.id, now: now, localSession: session.toSnapshot(),
        allowUndecodableStore: emergency, allowLocalFallbackWhenIdle: !emergency,
        onComplete: {
          SharedData.applyRestrictionsForCurrentState(process: .mainApp, liveSnapshot: nil, applier: self.appBlocker)
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

  enum ResetBlockingStateResult: Equatable {
    case completed, activeSession, syncInProgress, failed
  }

  @discardableResult
  func resetBlockingState(context: ModelContext, now: Date = Date(), calendar: Calendar = .current) async -> ResetBlockingStateResult {
    do {
      guard !profileSyncManager.isReplacingLocalProfiles else { return .syncInProgress }
      let ids = try OrphanedSessionCleanup.run(
        context: context, retryLock: true, requireInactive: true,
        publishedSession: activeSession, now: now, calendar: calendar,
        deactivateRestrictions: {},
        onCommit: {
          self.stopTimer()
          self.activeSession = nil
          self.elapsedTime = 0
          self.liveActivityManager.endSessionActivity()
          SharedData.applyRestrictionsForCurrentState(process: .mainApp, liveSnapshot: nil, applier: self.appBlocker)
          if SharedData.readSessionState().map({ $0.active == nil }) == true {
            DeviceActivityCenterUtil.removeAllBreakTimerActivities()
            DeviceActivityCenterUtil.removeAllOneMoreMinuteActivities()
            self.removeAllStrategyTimers()
          }
        })
      cleanUpGhostSchedules(context: context)
      Log.info("Blocking state reset complete", category: .strategy)
      if profileSyncManager.isEnabled {
        for id in ids {
          if !(await confirmSessionState(profileId: id)) {
            Log.warning("Blocking reset kept unconfirmed remote session cache", category: .sync)
          }
        }
      }
      return .completed
    } catch OrphanedSessionCleanup.Failure.activeSession {
      return .activeSession
    } catch {
      Log.error("Blocking state reset failed: \(redactedErrorForLog(error))", category: .strategy)
      return .failed
    }
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
      let slot = SharedData.readSessionState(for: profileId)?.active, slot.id == sessionId
    else { return false }
    if let canonicalSessionId, UUID(uuidString: canonicalSessionId) == nil { return false }
    let changedIdentity =
      canonicalSessionId.map { $0 != sessionId }
      ?? (current.usesCanonicalIdentity == true || abs(slot.startTime.timeIntervalSince(startTime)) >= 0.001)
    let now = currentDate()
    let profile = current.blockedProfile
    if changedIdentity {
      switch sessionAdmission(
        profile: profile, sessionId: canonicalSessionId, startedAt: startTime, deadline: timerEndTime,
        origin: origin, context: context, now: now)
      {
      case .eligible: break
      case .ended:
        recordStaleRemoteSession(profileId: profileId, id: canonicalSessionId, start: startTime, now: now)
        return false
      case .unavailable: return false
      }
    }
    let newId = changedIdentity ? (canonicalSessionId ?? UUID().uuidString) : sessionId
    let ownsCountdown = !changedIdentity && originDevice == SharedData.deviceSyncId.uuidString
    var adopted = slot
    adopted.id = newId
    adopted.startTime = startTime
    adopted.timerEndTime = timerEndTime
    adopted.origin = origin
    adopted.usesCanonicalIdentity = canonicalSessionId != nil ? true : nil
    if changedIdentity {
      adopted.tag = "remote-sync"
      adopted.forceStarted = true
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
        adopted, expectedSessionId: sessionId, now: now, expectedSession: slot,
        admissionProfile: changedIdentity ? BlockedProfiles.getSnapshot(for: profile) : nil, calendar: calendar
      )
    else {
      errorMessage = "The session timing could not be saved."
      return false
    }
    if changedIdentity {
      SharedData.applyRestrictionsForCurrentState(process: .mainApp, liveSnapshot: nil, applier: appBlocker)
    }
    if !ownsCountdown {
      if !changedIdentity, slot.usesCanonicalIdentity == true { self.cancelTimer(profileId, sessionId) } else if slot.usesCanonicalIdentity != true, Self.isCountdownTag(slot.tag) { cancelTimer(profileId) }
    }
    do {
      guard let restored = try getActiveSession(context: context), restored.id == newId else { return false }
      try saveSessionReceipt(restored, sequence: sequenceNumber, modifiedAt: serverModificationDate, context: context)
      if changedIdentity { startSessionActivity(restored) }
      return true
    } catch {
      errorMessage = "The session timing could not be saved."
      Log.error("Failed to save adopted session timing", category: .sync)
      return false
    }
  }

  private func saveSessionReceipt(
    _ session: BlockedProfileSession, sequence: Int?, modifiedAt: Date?, context: ModelContext
  ) throws {
    let oldSequence = session.sessionSequence
    let oldDate = session.sessionServerModificationDate
    let wasPending = session.sessionStartSyncPending
    session.sessionSequence = sequence ?? oldSequence
    session.sessionServerModificationDate = modifiedAt ?? oldDate
    session.sessionStartSyncPending = false
    do { try saveSession(context) } catch {
      session.sessionSequence = oldSequence
      session.sessionServerModificationDate = oldDate
      session.sessionStartSyncPending = wasPending
      throw error
    }
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
      let now = currentDate()
      let incomingId = sessionId?.uuidString
      let continuousOwner =
        existing.map {
          $0.blockedProfile.id == profileId
            && (incomingId == $0.id
              || (incomingId == nil && $0.usesCanonicalIdentity != true && abs($0.startTime.timeIntervalSince(startTime)) < 0.001))
        } == true
      if let cached = remoteSessionRecords[profileId], cached.isActive, cached.sessionId == incomingId {
        if let cachedDate = cached.serverModificationDate, let serverModificationDate, serverModificationDate < cachedDate {
          return
        }
        if cached.serverModificationDate == serverModificationDate, let sequenceNumber, sequenceNumber < cached.sequenceNumber {
          return
        }
      }
      if !continuousOwner {
        switch sessionAdmission(
          profile: profile, sessionId: incomingId, startedAt: startTime, deadline: timerEndTime,
          origin: origin, context: context, now: now)
        {
        case .eligible: break
        case .ended:
          recordStaleRemoteSession(profileId: profileId, id: incomingId, start: startTime, now: now)
          return
        case .unavailable: throw CocoaError(.fileReadUnknown)
        }
      }
      if let existing, existing.blockedProfile.id == profileId,
        SharedData.getActiveSharedSession()?.id == existing.id
      {
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
      guard let state = SharedData.readSessionState(for: profileId),
        state.active == nil || state.active?.id == existing?.id,
        SharedData.adoptAuthoritativeSession(
          candidate, expectedSessionId: state.active?.id, now: now, expectedSession: state.active,
          admissionProfile: BlockedProfiles.getSnapshot(for: profile), calendar: calendar)
      else { throw NSError(domain: "RemoteSession", code: 1) }
      SharedData.applyRestrictionsForCurrentState(process: .mainApp, liveSnapshot: nil, applier: appBlocker)
      if let existing, existing.blockedProfile.profileSchemaVersion < 2, state.active?.id != existing.id {
        finishDepartingSession(existing, context: context, now: now, syncDisplacedSession: true)
      }
      guard let adopted = try getActiveSession(context: context), adopted.id == id else { return }
      try saveSessionReceipt(adopted, sequence: sequenceNumber, modifiedAt: serverModificationDate, context: context)
      activateSession(adopted, context: context)
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

    guard let session = try? getActiveSession(context: context),
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
