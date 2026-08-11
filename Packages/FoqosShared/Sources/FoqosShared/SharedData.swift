import FamilyControls
import Foundation

// MARK: – Break-duration calculation shared by SessionSnapshot, ContentState, and BlockedProfileSession

public protocol BreakDurationCalculable {
  var breakStartTime: Date? { get }
  var breakEndTime: Date? { get }
}

extension BreakDurationCalculable {
  /// Returns the duration of a completed break in seconds. Returns 0 if no break occurred or if the break is still active.
  public func calculateBreakDuration() -> TimeInterval {
    guard let breakStart = breakStartTime else { return 0 }
    guard let breakEnd = breakEndTime else { return 0 }
    return breakEnd.timeIntervalSince(breakStart)
  }
}

public enum SharedData {
  private nonisolated(unsafe) static var _suite: UserDefaults?  // SAFETY: UserDefaults is thread-safe per Apple docs

  private static var suite: UserDefaults {
    precondition(_suite != nil, "SharedData.configure(suite:) must be called before accessing SharedData")
    return _suite!
  }

  /// Configure SharedData with a UserDefaults suite. Must be called before any access.
  /// - Main app: call in FoqosApp.init()
  /// - Extensions: call in extension init()
  /// - Tests: call in setUp() with an ephemeral suite
  public static func configure(suite: UserDefaults) {
    self._suite = suite
  }

  private static let containerURL: URL? = FileManager.default.containerURL(  // SAFETY: same app group as `suite`
    forSecurityApplicationGroupIdentifier: "group.com.cynexia.family-foqos"
  )

  #if DEBUG
    private nonisolated(unsafe) static var _lockPathOverride: String?
    private nonisolated(unsafe) static var _lockPathOverrideSet = false

    /// Override the lock path for testing. Pass `nil` to force the nil-lockPath code path.
    public static func configureLockPath(_ path: String?) {
      _lockPathOverride = path
      _lockPathOverrideSet = true
    }

    /// Reset the lock path override so the default container-based path is used.
    public static func resetLockPath() {
      _lockPathOverride = nil
      _lockPathOverrideSet = false
    }
  #endif

  private static var lockPath: String? {
    #if DEBUG
      if _lockPathOverrideSet { return _lockPathOverride }
    #endif
    return containerURL?.appendingPathComponent(".shared-data.lock").path
  }

  private static let nonblockingLockRetryCount = 50
  private static let nonblockingLockRetrySleepMicroseconds: useconds_t = 10_000

  /// Cross-process file lock for compound UserDefaults operations.
  /// Uses POSIX flock() — works across app and extension processes.
  /// Lock is automatically released if the process crashes.
  /// **Not reentrant** — do not call a withLock-wrapped method from inside
  /// another withLock closure. On BSD/macOS the inner unlock would release
  /// the process-wide lock while the outer critical section is still running.
  /// Public entry point for compound cross-process reads/writes made by callers
  /// outside this file (e.g. SyncEngineStore, §2.1). Same **non-reentrant** contract —
  /// never call a withLock-wrapped method from inside another withLock closure.
  public static func withLock<T>(_ body: () -> T) -> T {
    guard let lockPath else {
      Log.warning("SharedData: no lockPath (test mode?) — proceeding unlocked", category: .app)
      return body()
    }
    let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
    guard fd >= 0 else {
      Log.warning(
        "SharedData: open() failed, errno \(errno) — proceeding unlocked", category: .app)
      return body()
    }
    defer { close(fd) }
    var ret: Int32
    repeat {
      ret = flock(fd, LOCK_EX)
    } while ret == -1 && errno == EINTR
    guard ret == 0 else {
      Log.warning(
        "SharedData: flock() failed, errno \(errno) — proceeding unlocked", category: .app)
      return body()
    }
    defer { flock(fd, LOCK_UN) }
    return body()
  }

  /// Result of a C2 critical-section acquisition. `.degraded` means the body ran unlocked.
  public enum LockOutcome: Equatable {
    case acquired
    case degraded
  }

  /// Like `withLock`, but reports whether a real flock was acquired. Non-blocking mode uses a
  /// bounded retry so extension wakes do not wedge behind a suspended lock holder.
  public static func withLockStatus<T>(blocking: Bool, _ body: (LockOutcome) -> T) -> T {
    guard let lockPath else {
      Log.warning("SharedData: no lockPath (test mode?) — proceeding unlocked", category: .app)
      return body(.degraded)
    }
    let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
    guard fd >= 0 else {
      Log.warning(
        "SharedData: open() failed, errno \(errno) — proceeding unlocked", category: .app)
      return body(.degraded)
    }
    defer { close(fd) }

    if blocking {
      var ret: Int32
      repeat {
        ret = flock(fd, LOCK_EX)
      } while ret != 0 && errno == EINTR
      guard ret == 0 else {
        Log.warning(
          "SharedData: flock(LOCK_EX) failed, errno \(errno) — proceeding unlocked",
          category: .app)
        return body(.degraded)
      }
    } else {
      var acquired = false
      for _ in 0..<nonblockingLockRetryCount {
        let ret = flock(fd, LOCK_NB | LOCK_EX)
        if ret == 0 {
          acquired = true
          break
        }
        if errno != EWOULDBLOCK && errno != EINTR { break }
        usleep(nonblockingLockRetrySleepMicroseconds)
      }
      guard acquired else {
        Log.warning("SharedData: LOCK_NB timed out — proceeding unlocked", category: .app)
        return body(.degraded)
      }
    }
    defer { flock(fd, LOCK_UN) }
    return body(.acquired)
  }

  /// Raw active-session read for use inside an existing critical section.
  internal static var rawActiveSession: SessionSnapshot? {
    activeSharedSession
  }

  /// Encode-then-commit raw active-session write. On encode failure, storage is left untouched.
  @discardableResult
  internal static func rawCommitActiveSession(
    _ snapshot: SessionSnapshot?,
    encode: (SessionSnapshot) throws -> Data = { try JSONEncoder().encode($0) }
  ) -> Bool {
    guard let snapshot else {
      suite.removeObject(forKey: Key.activeScheduleSession.rawValue)
      clearLegacy(.activeScheduleSession)
      return true
    }
    guard let data = try? encode(snapshot) else {
      Log.error(
        "rawCommitActiveSession: encode failed — leaving stored session untouched",
        category: .session)
      return false
    }
    suite.set(data, forKey: Key.activeScheduleSession.rawValue)
    clearLegacy(.activeScheduleSession)
    return true
  }

  // MARK: – Keys

  private enum Key: String {
    case profileSnapshots = "family_foqos_profile_snapshots"
    case activeScheduleSession = "family_foqos_active_schedule_session"
    case completedScheduleSessions = "family_foqos_completed_schedule_sessions"
    case deviceSyncId = "family_foqos_device_sync_id"
    case deviceSyncEnabled = "family_foqos_device_sync_enabled"
  }

  /// Old key names used before migration. Must match the `old` column in
  /// `UserDefaultsMigration.appGroupKeyMapping`. Extensions may read these
  /// if they run before the main app has migrated post-update.
  private enum LegacyKey: String {
    case profileSnapshots = "profileSnapshots"
    case activeScheduleSession = "activeScheduleSession"
    case completedScheduleSessions = "completedScheduleSessions"
    case deviceSyncId = "deviceSyncId"
    case deviceSyncEnabled = "deviceSyncEnabled"
  }

  /// Read from suite with fallback to legacy key name (for pre-migration extension reads).
  private static func data(forKey key: Key, legacyKey: LegacyKey) -> Data? {
    suite.data(forKey: key.rawValue) ?? suite.data(forKey: legacyKey.rawValue)
  }

  private static func string(forKey key: Key, legacyKey: LegacyKey) -> String? {
    suite.string(forKey: key.rawValue) ?? suite.string(forKey: legacyKey.rawValue)
  }

  private static func bool(forKey key: Key, legacyKey: LegacyKey) -> Bool {
    if suite.object(forKey: key.rawValue) != nil {
      return suite.bool(forKey: key.rawValue)
    }
    return suite.bool(forKey: legacyKey.rawValue)
  }

  /// Removes the pre-migration (legacy) key on every write, so a stale legacy value can never
  /// shadow or resurrect state after the main-app app-group migration runs (#217). Pairs with
  /// `UserDefaultsMigration`'s copy-only-when-new-absent guard.
  /// MUST NOT take `withLock` because the lock is non-reentrant. Callers that need cross-process
  /// synchronization must hold the relevant outer `withLock` around their whole write.
  private static func clearLegacy(_ legacyKey: LegacyKey) {
    suite.removeObject(forKey: legacyKey.rawValue)
  }

  // MARK: – Serializable snapshot of a profile (no sessions)

  public struct ProfileSnapshot: Codable, Equatable {
    public var id: UUID
    public var name: String
    public var selectedActivity: FamilyActivitySelection
    public var createdAt: Date
    public var updatedAt: Date
    public var blockingStrategyId: String?
    public var strategyData: Data?
    public var order: Int

    public var enableLiveActivity: Bool
    public var reminderTimeInSeconds: UInt32?
    public var customReminderMessage: String?
    public var enableBreaks: Bool
    public var breakTimeInMinutes: Int = 15
    public var enableStrictMode: Bool
    public var enableAllowMode: Bool
    public var enableAllowModeDomains: Bool
    public var enableSafariBlocking: Bool

    public var preActivationReminderTimes: [UInt8]?

    public var domains: [String]?
    public var physicalUnblockNFCTagId: String?
    public var physicalUnblockQRCodeId: String?

    public var schedule: BlockedProfileSchedule?

    // V2 trigger system
    public var startSchedule: ProfileScheduleTime?
    public var stopSchedule: ProfileScheduleTime?
    public var startTriggersSchedule: Bool?
    public var stopConditionsSchedule: Bool?

    public var geofenceRule: ProfileGeofenceRule?

    public var disableBackgroundStops: Bool?
    public var stopConditions: ProfileStopConditions?

    // Managed profile fields
    public var isManaged: Bool?
    public var managedByChildId: String?

    // Device sync fields
    public var syncVersion: Int?
    public var needsAppSelection: Bool?

    public var scheduleLastStoppedAt: Date?

    public init(
      id: UUID,
      name: String,
      selectedActivity: FamilyActivitySelection,
      createdAt: Date,
      updatedAt: Date,
      blockingStrategyId: String? = nil,
      strategyData: Data? = nil,
      order: Int,
      enableLiveActivity: Bool,
      reminderTimeInSeconds: UInt32? = nil,
      customReminderMessage: String? = nil,
      enableBreaks: Bool,
      breakTimeInMinutes: Int = 15,
      enableStrictMode: Bool,
      enableAllowMode: Bool,
      enableAllowModeDomains: Bool,
      enableSafariBlocking: Bool,
      preActivationReminderTimes: [UInt8]? = nil,
      domains: [String]? = nil,
      physicalUnblockNFCTagId: String? = nil,
      physicalUnblockQRCodeId: String? = nil,
      schedule: BlockedProfileSchedule? = nil,
      startSchedule: ProfileScheduleTime? = nil,
      stopSchedule: ProfileScheduleTime? = nil,
      startTriggersSchedule: Bool? = nil,
      stopConditionsSchedule: Bool? = nil,
      geofenceRule: ProfileGeofenceRule? = nil,
      disableBackgroundStops: Bool? = nil,
      stopConditions: ProfileStopConditions? = nil,
      isManaged: Bool? = nil,
      managedByChildId: String? = nil,
      syncVersion: Int? = nil,
      needsAppSelection: Bool? = nil,
      scheduleLastStoppedAt: Date? = nil
    ) {
      self.id = id
      self.name = name
      self.selectedActivity = selectedActivity
      self.createdAt = createdAt
      self.updatedAt = updatedAt
      self.blockingStrategyId = blockingStrategyId
      self.strategyData = strategyData
      self.order = order
      self.enableLiveActivity = enableLiveActivity
      self.reminderTimeInSeconds = reminderTimeInSeconds
      self.customReminderMessage = customReminderMessage
      self.enableBreaks = enableBreaks
      self.breakTimeInMinutes = breakTimeInMinutes
      self.enableStrictMode = enableStrictMode
      self.enableAllowMode = enableAllowMode
      self.enableAllowModeDomains = enableAllowModeDomains
      self.enableSafariBlocking = enableSafariBlocking
      self.preActivationReminderTimes = preActivationReminderTimes
      self.domains = domains
      self.physicalUnblockNFCTagId = physicalUnblockNFCTagId
      self.physicalUnblockQRCodeId = physicalUnblockQRCodeId
      self.schedule = schedule
      self.startSchedule = startSchedule
      self.stopSchedule = stopSchedule
      self.startTriggersSchedule = startTriggersSchedule
      self.stopConditionsSchedule = stopConditionsSchedule
      self.geofenceRule = geofenceRule
      self.disableBackgroundStops = disableBackgroundStops
      self.stopConditions = stopConditions
      self.isManaged = isManaged
      self.managedByChildId = managedByChildId
      self.syncVersion = syncVersion
      self.needsAppSelection = needsAppSelection
      self.scheduleLastStoppedAt = scheduleLastStoppedAt
    }
  }

  // MARK: – Serializable snapshot of a session (no profile object)

  public struct SessionSnapshot: Codable, Equatable, BreakDurationCalculable {
    public var id: String
    public var tag: String
    public var blockedProfileId: UUID

    public var startTime: Date
    public var endTime: Date?

    public var breakStartTime: Date?
    public var breakEndTime: Date?

    public var forceStarted: Bool

    public var oneMoreMinuteUsed: Bool = false
    public var oneMoreMinuteStartTime: Date?
    /// C2 (D-C2-1): absolute wall-clock deadline for an open break grant.
    public var breakEndDeadline: Date?
    /// C2 (D-C2-1): absolute wall-clock deadline for an open one-more-minute grant.
    public var oneMoreMinuteDeadline: Date?
    /// C2 (§6.1a): re-block config pinned at grant-open for post-close wakes.
    public var pinnedProfileConfig: ProfileSnapshot?

    public init(
      id: String,
      tag: String,
      blockedProfileId: UUID,
      startTime: Date,
      endTime: Date? = nil,
      breakStartTime: Date? = nil,
      breakEndTime: Date? = nil,
      forceStarted: Bool,
      oneMoreMinuteUsed: Bool = false,
      oneMoreMinuteStartTime: Date? = nil,
      breakEndDeadline: Date? = nil,
      oneMoreMinuteDeadline: Date? = nil,
      pinnedProfileConfig: ProfileSnapshot? = nil
    ) {
      self.id = id
      self.tag = tag
      self.blockedProfileId = blockedProfileId
      self.startTime = startTime
      self.endTime = endTime
      self.breakStartTime = breakStartTime
      self.breakEndTime = breakEndTime
      self.forceStarted = forceStarted
      self.oneMoreMinuteUsed = oneMoreMinuteUsed
      self.oneMoreMinuteStartTime = oneMoreMinuteStartTime
      self.breakEndDeadline = breakEndDeadline
      self.oneMoreMinuteDeadline = oneMoreMinuteDeadline
      self.pinnedProfileConfig = pinnedProfileConfig
    }
  }

  // MARK: – Persisted snapshots keyed by profile ID (UUID string)

  public static var profileSnapshots: [String: ProfileSnapshot] {
    get {
      guard let data = data(forKey: .profileSnapshots, legacyKey: .profileSnapshots) else { return [:] }
      return (try? JSONDecoder().decode([String: ProfileSnapshot].self, from: data)) ?? [:]
    }
    set {
      if let data = try? JSONEncoder().encode(newValue) {
        suite.set(data, forKey: Key.profileSnapshots.rawValue)
      } else {
        suite.removeObject(forKey: Key.profileSnapshots.rawValue)
      }
      clearLegacy(.profileSnapshots)
    }
  }

  public static func snapshot(for profileID: String) -> ProfileSnapshot? {
    withLock { profileSnapshots[profileID] }
  }

  public static func setSnapshot(_ snapshot: ProfileSnapshot, for profileID: String) {
    withLock {
      var all = profileSnapshots
      all[profileID] = snapshot
      profileSnapshots = all
    }
  }

  public static func removeSnapshot(for profileID: String) {
    withLock {
      var all = profileSnapshots
      all.removeValue(forKey: profileID)
      profileSnapshots = all
    }
  }

  // MARK: – Persisted array of scheduled sessions

  public static var completedSessionsInScheduler: [SessionSnapshot] {
    get {
      guard let data = data(forKey: .completedScheduleSessions, legacyKey: .completedScheduleSessions) else { return [] }
      return (try? JSONDecoder().decode([SessionSnapshot].self, from: data)) ?? []
    }
    set {
      if let data = try? JSONEncoder().encode(newValue) {
        suite.set(data, forKey: Key.completedScheduleSessions.rawValue)
      } else {
        suite.removeObject(forKey: Key.completedScheduleSessions.rawValue)
      }
      clearLegacy(.completedScheduleSessions)
    }
  }

  // MARK: – Persisted array of scheduled sessions

  public static var activeSharedSession: SessionSnapshot? {
    get {
      guard let data = data(forKey: .activeScheduleSession, legacyKey: .activeScheduleSession) else { return nil }
      return (try? JSONDecoder().decode(SessionSnapshot.self, from: data)) ?? nil
    }
    set {
      if let data = try? JSONEncoder().encode(newValue) {
        suite.set(data, forKey: Key.activeScheduleSession.rawValue)
      } else {
        suite.removeObject(forKey: Key.activeScheduleSession.rawValue)
      }
      clearLegacy(.activeScheduleSession)
    }
  }

  public static func createSessionForScheduler(for profileID: UUID) {
    withLock {
      activeSharedSession = SessionSnapshot(
        id: UUID().uuidString,
        tag: profileID.uuidString,
        blockedProfileId: profileID,
        startTime: Date(),
        forceStarted: true
      )
    }
  }

  public static func createActiveSharedSession(for session: SessionSnapshot) {
    withLock {
      activeSharedSession = session
    }
  }

  public static func getActiveSharedSession() -> SessionSnapshot? {
    withLock { activeSharedSession }
  }

  public static func endActiveSharedSession() {
    withLock {
      guard var existingScheduledSession = activeSharedSession else { return }

      existingScheduledSession.endTime = Date()
      completedSessionsInScheduler.append(existingScheduledSession)

      activeSharedSession = nil
    }
  }

  @discardableResult
  public static func endActiveSharedSession(expectedSessionId: String) -> Bool {
    withLock {
      guard var existingScheduledSession = activeSharedSession,
        existingScheduledSession.id == expectedSessionId
      else { return false }

      existingScheduledSession.endTime = Date()
      completedSessionsInScheduler.append(existingScheduledSession)

      activeSharedSession = nil
      return true
    }
  }

  @discardableResult
  public static func startSchedulerSessionTakingOver(
    profileId: UUID,
    expectedVictimId: String?
  ) -> Bool {
    withLock {
      if let current = activeSharedSession {
        if current.blockedProfileId == profileId {
          return true
        }

        guard let victimId = expectedVictimId, current.id == victimId else {
          return false
        }

        var victim = current
        victim.endTime = Date()
        completedSessionsInScheduler.append(victim)
      }

      activeSharedSession = SessionSnapshot(
        id: UUID().uuidString,
        tag: profileId.uuidString,
        blockedProfileId: profileId,
        startTime: Date(),
        forceStarted: true
      )
      return true
    }
  }

  /// Sets scheduleLastStoppedAt on the profile snapshot in SharedData.
  /// Called from extension processes that cannot access SwiftData.
  public static func setLastStoppedAt(for profileID: String, at date: Date) {
    withLock {
      var all = profileSnapshots
      guard var snapshot = all[profileID] else { return }
      snapshot.scheduleLastStoppedAt = date
      all[profileID] = snapshot
      profileSnapshots = all
    }
  }

  private static func activeSharedSessionMatchesExpected(
    _ expectedSessionId: String, operation _: String
  ) -> Bool {
    guard activeSharedSession?.id == expectedSessionId else {
      Log.debug(
        "SharedData session operation skipped: active session did not match expectation",
        category: .session
      )
      return false
    }

    return true
  }

  public static func flushActiveSession(expectedSessionId: String) {
    withLock {
      guard activeSharedSessionMatchesExpected(expectedSessionId, operation: "flushActiveSession")
      else { return }
      activeSharedSession = nil
    }
  }

  /// Atomically reads and clears completed scheduled sessions.
  /// Use this in production instead of separate get + flush calls
  /// to prevent TOCTOU races with concurrent endActiveSharedSession() writes.
  public static func getAndFlushCompletedSessionsForScheduler() -> [SessionSnapshot] {
    withLock {
      let sessions = completedSessionsInScheduler
      completedSessionsInScheduler = []
      return sessions
    }
  }

  public static func setBreakStartTime(date: Date, expectedSessionId: String) {
    withLock {
      guard activeSharedSessionMatchesExpected(expectedSessionId, operation: "setBreakStartTime")
      else { return }
      activeSharedSession?.breakStartTime = date
    }
  }

  public static func setBreakEndTime(date: Date, expectedSessionId: String) {
    withLock {
      guard activeSharedSessionMatchesExpected(expectedSessionId, operation: "setBreakEndTime")
      else { return }
      activeSharedSession?.breakEndTime = date
    }
  }

  public static func setEndTime(date: Date, expectedSessionId: String) {
    withLock {
      guard activeSharedSessionMatchesExpected(expectedSessionId, operation: "setEndTime")
      else { return }
      activeSharedSession?.endTime = date
    }
  }

  public static func setOneMoreMinuteStartTime(date: Date, expectedSessionId: String) {
    withLock {
      guard activeSharedSessionMatchesExpected(expectedSessionId, operation: "setOneMoreMinuteStartTime"),
        var session = activeSharedSession
      else { return }
      session.oneMoreMinuteStartTime = date
      session.oneMoreMinuteUsed = true
      activeSharedSession = session
    }
  }

  public static func clearOneMoreMinuteStartTime(expectedSessionId: String) {
    withLock {
      guard activeSharedSessionMatchesExpected(expectedSessionId, operation: "clearOneMoreMinuteStartTime"),
        var session = activeSharedSession
      else { return }
      session.oneMoreMinuteStartTime = nil
      activeSharedSession = session
    }
  }

  // MARK: - Device Sync Settings

  /// Unique identifier for this device in sync operations.
  /// Generated once and persisted across app launches.
  public static var deviceSyncId: UUID {
    get {
      withLock {
        if let idString = string(forKey: .deviceSyncId, legacyKey: .deviceSyncId),
          let uuid = UUID(uuidString: idString)
        {
          return uuid
        }
        // Generate new ID if none exists
        let newId = UUID()
        suite.set(newId.uuidString, forKey: Key.deviceSyncId.rawValue)
        clearLegacy(.deviceSyncId)
        return newId
      }
    }
    set {
      withLock {
        suite.set(newValue.uuidString, forKey: Key.deviceSyncId.rawValue)
        clearLegacy(.deviceSyncId)
      }
    }
  }

  /// Whether device sync is enabled for this device.
  public static var deviceSyncEnabled: Bool {
    get {
      withLock {
        return bool(forKey: .deviceSyncEnabled, legacyKey: .deviceSyncEnabled)
      }
    }
    set {
      withLock {
        suite.set(newValue, forKey: Key.deviceSyncEnabled.rawValue)
        clearLegacy(.deviceSyncEnabled)
      }
    }
  }
}
