import FamilyControls
import Foundation
import os

// MARK: – Break-duration calculation shared by SessionSnapshot, ContentState, and BlockedProfileSession

protocol BreakDurationCalculable {
  var breakStartTime: Date? { get }
  var breakEndTime: Date? { get }
}

extension BreakDurationCalculable {
  /// Returns the duration of a completed break in seconds. Returns 0 if no break occurred or if the break is still active.
  func calculateBreakDuration() -> TimeInterval {
    guard let breakStart = breakStartTime else { return 0 }
    guard let breakEnd = breakEndTime else { return 0 }
    return breakEnd.timeIntervalSince(breakStart)
  }
}

enum SharedData {
  private nonisolated(unsafe) static let suite = UserDefaults(  // SAFETY: UserDefaults is thread-safe per Apple docs
    suiteName: "group.com.cynexia.family-foqos"
  )!

  private static let containerURL: URL = FileManager.default.containerURL(  // SAFETY: same app group as `suite`
    forSecurityApplicationGroupIdentifier: "group.com.cynexia.family-foqos"
  )!

  private static let lockPath: String =
    containerURL
    .appendingPathComponent(".shared-data.lock").path

  private static let lockLog = Logger(
    subsystem: "com.cynexia.family-foqos", category: "SharedData"
  )

  /// Cross-process file lock for compound UserDefaults operations.
  /// Uses POSIX flock() — works across app and extension processes.
  /// Lock is automatically released if the process crashes.
  /// **Not reentrant** — do not call a withLock-wrapped method from inside
  /// another withLock closure. On BSD/macOS the inner unlock would release
  /// the process-wide lock while the outer critical section is still running.
  private static func withLock<T>(_ body: () -> T) -> T {
    let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
    guard fd >= 0 else {
      lockLog.warning("SharedData: open() failed, errno \(errno) — proceeding unlocked")
      return body()
    }
    defer { close(fd) }
    var ret: Int32
    repeat {
      ret = flock(fd, LOCK_EX)
    } while ret == -1 && errno == EINTR
    guard ret == 0 else {
      lockLog.warning("SharedData: flock() failed, errno \(errno) — proceeding unlocked")
      return body()
    }
    defer { flock(fd, LOCK_UN) }
    return body()
  }

  // MARK: – Keys

  private enum Key: String {
    case profileSnapshots
    case activeScheduleSession
    case completedScheduleSessions
    case deviceSyncId
    case deviceSyncEnabled
  }

  // MARK: – Serializable snapshot of a profile (no sessions)

  struct ProfileSnapshot: Codable, Equatable {
    var id: UUID
    var name: String
    var selectedActivity: FamilyActivitySelection
    var createdAt: Date
    var updatedAt: Date
    var blockingStrategyId: String?
    var strategyData: Data?
    var order: Int

    var enableLiveActivity: Bool
    var reminderTimeInSeconds: UInt32?
    var customReminderMessage: String?
    var enableBreaks: Bool
    var breakTimeInMinutes: Int = 15
    var enableStrictMode: Bool
    var enableAllowMode: Bool
    var enableAllowModeDomains: Bool
    var enableSafariBlocking: Bool

    var preActivationReminderTimes: [UInt8]?

    var domains: [String]?
    var physicalUnblockNFCTagId: String?
    var physicalUnblockQRCodeId: String?

    var schedule: BlockedProfileSchedule?

    // V2 trigger system
    var startSchedule: ProfileScheduleTime?
    var stopSchedule: ProfileScheduleTime?
    var startTriggersSchedule: Bool?
    var stopConditionsSchedule: Bool?

    var geofenceRule: ProfileGeofenceRule?

    var disableBackgroundStops: Bool?

    // Managed profile fields
    var isManaged: Bool?
    var managedByChildId: String?

    // Device sync fields
    var syncVersion: Int?
    var needsAppSelection: Bool?

    var scheduleLastStoppedAt: Date?
  }

  // MARK: – Serializable snapshot of a session (no profile object)

  struct SessionSnapshot: Codable, Equatable, BreakDurationCalculable {
    var id: String
    var tag: String
    var blockedProfileId: UUID

    var startTime: Date
    var endTime: Date?

    var breakStartTime: Date?
    var breakEndTime: Date?

    var forceStarted: Bool

    var oneMoreMinuteUsed: Bool = false
    var oneMoreMinuteStartTime: Date?
  }

  // MARK: – Persisted snapshots keyed by profile ID (UUID string)

  static var profileSnapshots: [String: ProfileSnapshot] {
    get {
      guard let data = suite.data(forKey: Key.profileSnapshots.rawValue) else { return [:] }
      return (try? JSONDecoder().decode([String: ProfileSnapshot].self, from: data)) ?? [:]
    }
    set {
      if let data = try? JSONEncoder().encode(newValue) {
        suite.set(data, forKey: Key.profileSnapshots.rawValue)
      } else {
        suite.removeObject(forKey: Key.profileSnapshots.rawValue)
      }
    }
  }

  static func snapshot(for profileID: String) -> ProfileSnapshot? {
    withLock { profileSnapshots[profileID] }
  }

  static func setSnapshot(_ snapshot: ProfileSnapshot, for profileID: String) {
    withLock {
      var all = profileSnapshots
      all[profileID] = snapshot
      profileSnapshots = all
    }
  }

  static func removeSnapshot(for profileID: String) {
    withLock {
      var all = profileSnapshots
      all.removeValue(forKey: profileID)
      profileSnapshots = all
    }
  }

  // MARK: – Persisted array of scheduled sessions

  static var completedSessionsInSchedular: [SessionSnapshot] {
    get {
      guard let data = suite.data(forKey: Key.completedScheduleSessions.rawValue) else { return [] }
      return (try? JSONDecoder().decode([SessionSnapshot].self, from: data)) ?? []
    }
    set {
      if let data = try? JSONEncoder().encode(newValue) {
        suite.set(data, forKey: Key.completedScheduleSessions.rawValue)
      } else {
        suite.removeObject(forKey: Key.completedScheduleSessions.rawValue)
      }
    }
  }

  // MARK: – Persisted array of scheduled sessions

  static var activeSharedSession: SessionSnapshot? {
    get {
      guard let data = suite.data(forKey: Key.activeScheduleSession.rawValue) else { return nil }
      return (try? JSONDecoder().decode(SessionSnapshot.self, from: data)) ?? nil
    }
    set {
      if let data = try? JSONEncoder().encode(newValue) {
        suite.set(data, forKey: Key.activeScheduleSession.rawValue)
      } else {
        suite.removeObject(forKey: Key.activeScheduleSession.rawValue)
      }
    }
  }

  static func createSessionForSchedular(for profileID: UUID) {
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

  static func createActiveSharedSession(for session: SessionSnapshot) {
    withLock {
      activeSharedSession = session
    }
  }

  static func getActiveSharedSession() -> SessionSnapshot? {
    withLock { activeSharedSession }
  }

  static func endActiveSharedSession() {
    withLock {
      guard var existingScheduledSession = activeSharedSession else { return }

      existingScheduledSession.endTime = Date()
      completedSessionsInSchedular.append(existingScheduledSession)

      activeSharedSession = nil
    }
  }

  /// Sets scheduleLastStoppedAt on the profile snapshot in SharedData.
  /// Called from extension processes that cannot access SwiftData.
  static func setLastStoppedAt(for profileID: String, at date: Date) {
    withLock {
      var all = profileSnapshots
      guard var snapshot = all[profileID] else { return }
      snapshot.scheduleLastStoppedAt = date
      all[profileID] = snapshot
      profileSnapshots = all
    }
  }

  static func flushActiveSession() {
    withLock {
      activeSharedSession = nil
    }
  }

  static func getCompletedSessionsForSchedular() -> [SessionSnapshot] {
    withLock { completedSessionsInSchedular }
  }

  /// Atomically reads and clears completed scheduled sessions.
  /// Use this in production instead of separate get + flush calls
  /// to prevent TOCTOU races with concurrent endActiveSharedSession() writes.
  static func getAndFlushCompletedSessionsForSchedular() -> [SessionSnapshot] {
    withLock {
      let sessions = completedSessionsInSchedular
      completedSessionsInSchedular = []
      return sessions
    }
  }

  static func flushCompletedSessionsForSchedular() {
    withLock {
      completedSessionsInSchedular = []
    }
  }

  static func setBreakStartTime(date: Date) {
    withLock {
      activeSharedSession?.breakStartTime = date
    }
  }

  static func setBreakEndTime(date: Date) {
    withLock {
      activeSharedSession?.breakEndTime = date
    }
  }

  static func setEndTime(date: Date) {
    withLock {
      activeSharedSession?.endTime = date
    }
  }

  static func setOneMoreMinuteStartTime(date: Date) {
    withLock {
      guard var session = activeSharedSession else { return }
      session.oneMoreMinuteStartTime = date
      session.oneMoreMinuteUsed = true
      activeSharedSession = session
    }
  }

  static func clearOneMoreMinuteStartTime() {
    withLock {
      guard var session = activeSharedSession else { return }
      session.oneMoreMinuteStartTime = nil
      activeSharedSession = session
    }
  }

  // MARK: - Device Sync Settings

  /// Unique identifier for this device in sync operations.
  /// Generated once and persisted across app launches.
  static var deviceSyncId: UUID {
    get {
      withLock {
        if let idString = suite.string(forKey: Key.deviceSyncId.rawValue),
          let uuid = UUID(uuidString: idString)
        {
          return uuid
        }
        // Generate new ID if none exists
        let newId = UUID()
        suite.set(newId.uuidString, forKey: Key.deviceSyncId.rawValue)
        return newId
      }
    }
    set {
      withLock {
        suite.set(newValue.uuidString, forKey: Key.deviceSyncId.rawValue)
      }
    }
  }

  /// Whether device sync is enabled for this device.
  static var deviceSyncEnabled: Bool {
    get {
      return suite.bool(forKey: Key.deviceSyncEnabled.rawValue)
    }
    set {
      suite.set(newValue, forKey: Key.deviceSyncEnabled.rawValue)
    }
  }
}
