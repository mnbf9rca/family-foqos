import FoqosShared
import Foundation
@preconcurrency import SwiftData  // ReferenceWritableKeyPath in SortDescriptor lacks Sendable conformance

@Model
class BlockedProfileSession: BreakDurationCalculable {
  @Attribute(.unique) var id: String
  var tag: String

  @Relationship var blockedProfile: BlockedProfiles

  var startTime: Date
  var endTime: Date?
  var timerEndTime: Date?
  var usesCanonicalIdentity: Bool?
  var sessionSequence: Int?
  var sessionServerModificationDate: Date?
  var sessionStartSyncPending: Bool = false
  var sessionOriginData: Data?
  var origin: SessionOrigin? {
    get { sessionOriginData.flatMap { try? JSONDecoder().decode(SessionOrigin.self, from: $0) } }
    set {
      sessionOriginData = newValue.flatMap { try? JSONEncoder().encode($0) }
    }
  }

  var breakStartTime: Date?
  var breakEndTime: Date?
  var breakEndDeadline: Date?

  var oneMoreMinuteUsed: Bool = false
  var oneMoreMinuteStartTime: Date?
  var oneMoreMinuteDeadline: Date?
  var pinnedProfileConfigData: Data?

  var forceStarted: Bool = false

  var isActive: Bool {
    return endTime == nil
  }

  var isBreakAvailable: Bool {
    return blockedProfile.enableBreaks == true
      && breakEndTime == nil
  }

  var isBreakActive: Bool {
    return blockedProfile.enableBreaks == true
      && breakStartTime != nil
      && breakEndTime == nil
  }

  var isBreakOpenRawFields: Bool {
    return breakStartTime != nil && breakEndTime == nil
  }

  func isOneMoreMinuteActive(now: Date = Date()) -> Bool {
    guard let startTime = oneMoreMinuteStartTime else { return false }
    return now.timeIntervalSince(startTime) < 60
  }

  var isOneMoreMinuteAvailable: Bool {
    return !oneMoreMinuteUsed && !isBreakOpenRawFields
  }

  func duration(now: Date = Date()) -> TimeInterval {
    let end = endTime ?? now
    return end.timeIntervalSince(startTime)
  }

  init(
    tag: String,
    blockedProfile: BlockedProfiles,
    forceStarted: Bool = false,
    startTime: Date = Date(),
    id: String = UUID().uuidString,
    origin: SessionOrigin? = nil
  ) {
    self.id = id
    self.tag = tag
    self.blockedProfile = blockedProfile
    self.startTime = startTime
    self.forceStarted = forceStarted
    self.usesCanonicalIdentity = origin != nil ? true : nil
    self.origin = origin

    // Add this session to the profile's sessions array
    blockedProfile.sessions.append(self)
  }

  func startBreak(now: Date = Date()) {
    SharedData.setBreakStartTime(date: now, expectedSessionId: id)
    self.breakStartTime = now
  }

  func startOneMoreMinute(now: Date = Date()) {
    oneMoreMinuteUsed = true
    oneMoreMinuteStartTime = now

    // Sync to SharedData for background/foreground transitions
    SharedData.setOneMoreMinuteStartTime(date: now, expectedSessionId: id)
  }

  func endSession(now: Date = Date()) {
    SharedData.closeGrantsForSessionEnd(expectedSessionId: id, now: now)
    if breakStartTime != nil && breakEndTime == nil {
      breakEndTime = now
    }
    oneMoreMinuteStartTime = nil
    oneMoreMinuteDeadline = nil

    // Set the end time in shared data in case its being saved
    SharedData.setEndTime(date: now, expectedSessionId: id)
    let wasScheduleOrigin = origin?.kind == .schedule
    self.endTime = now
    origin = nil
    timerEndTime = nil

    // If this was a schedule-started session, record when it stopped.
    // The reader in ScheduleTimerActivity compares this against today's start time.
    // Schedule-started sessions have tag == profile UUID (set by createSessionForScheduler).
    let isScheduleStarted = wasScheduleOrigin || (blockedProfile.profileSchemaVersion < 2 && tag == blockedProfile.id.uuidString)
    if isScheduleStarted, modelContext != nil {
      blockedProfile.scheduleLastStoppedAt = max(blockedProfile.scheduleLastStoppedAt ?? .distantPast, now)
      BlockedProfiles.updateSnapshot(for: blockedProfile)
    }

    SharedData.flushActiveSession(expectedSessionId: id)
  }

  func toSnapshot() -> SharedData.SessionSnapshot {
    return SharedData.SessionSnapshot(
      id: id,
      tag: tag,
      blockedProfileId: blockedProfile.id,
      startTime: startTime,
      endTime: endTime,
      timerEndTime: timerEndTime,
      breakStartTime: breakStartTime,
      breakEndTime: breakEndTime,
      forceStarted: forceStarted,
      oneMoreMinuteUsed: oneMoreMinuteUsed,
      oneMoreMinuteStartTime: oneMoreMinuteStartTime,
      breakEndDeadline: breakEndDeadline,
      oneMoreMinuteDeadline: oneMoreMinuteDeadline,
      pinnedProfileConfig: pinnedProfileConfigData.flatMap {
        try? JSONDecoder().decode(SharedData.ProfileSnapshot.self, from: $0)
      },
      origin: endTime == nil ? origin : nil, usesCanonicalIdentity: usesCanonicalIdentity
    )
  }

  static func mostRecentActiveSession(in context: ModelContext) throws
    -> BlockedProfileSession?
  {
    var descriptor = FetchDescriptor<BlockedProfileSession>(
      predicate: #Predicate { $0.endTime == nil },
      sortBy: [SortDescriptor(\.startTime, order: .reverse)]
    )
    descriptor.fetchLimit = 1

    return try context.fetch(descriptor).first
  }

  static func createSession(
    in context: ModelContext,
    withTag tag: String,
    withProfile profile: BlockedProfiles,
    forceStart: Bool = false,
    startTime: Date = Date(),
    timerEndTime: Date? = nil
  ) -> BlockedProfileSession {
    let newSession = BlockedProfileSession(
      tag: tag,
      blockedProfile: profile,
      forceStarted: forceStart,
      startTime: startTime
    )

    newSession.timerEndTime = timerEndTime
    SharedData.createActiveSharedSession(for: newSession.toSnapshot())

    context.insert(newSession)
    return newSession
  }

  static func upsertSessionFromSnapshot(
    in context: ModelContext,
    withSnapshot snapshot: SharedData.SessionSnapshot
  ) {
    do {
      if try stageSessionSnapshot(snapshot, in: context) != nil { try context.save() }
    } catch {
      Log.error("Failed to save session snapshot: \(redactedErrorForLog(error))", category: .session)
    }
  }

  /// Stage changes so callers can save history and ownership repair together.
  static func stageSessionSnapshot(
    _ rawSnapshot: SharedData.SessionSnapshot, in context: ModelContext
  ) throws -> BlockedProfileSession? {
    let snapshot = rawSnapshot.endTime == nil ? rawSnapshot : SharedData.normalizedForEnd(rawSnapshot)
    guard let profile = try BlockedProfiles.findProfile(byID: snapshot.blockedProfileId, in: context) else { return nil }

    let session: BlockedProfileSession
    if let existing = try findSession(byID: snapshot.id, in: context) {
      guard existing.blockedProfile.id == snapshot.blockedProfileId else {
        throw CocoaError(.validationMultipleErrors)
      }
      // Replay can update a completion but can never turn history back into an active row.
      if existing.endTime != nil, snapshot.endTime == nil { return nil }
      session = existing
    } else {
      session = BlockedProfileSession(tag: snapshot.tag, blockedProfile: profile, id: snapshot.id)
      context.insert(session)
    }

    session.usesCanonicalIdentity = snapshot.usesCanonicalIdentity
    session.origin = snapshot.origin
    session.tag = snapshot.tag
    session.startTime = snapshot.startTime
    session.endTime = snapshot.endTime
    session.timerEndTime = snapshot.timerEndTime
    session.breakStartTime = snapshot.breakStartTime
    session.breakEndTime = snapshot.breakEndTime
    session.forceStarted = snapshot.forceStarted
    session.oneMoreMinuteUsed = snapshot.oneMoreMinuteUsed
    session.oneMoreMinuteStartTime = snapshot.oneMoreMinuteStartTime
    session.breakEndDeadline = snapshot.breakEndDeadline
    session.oneMoreMinuteDeadline = snapshot.oneMoreMinuteDeadline
    session.pinnedProfileConfigData = try snapshot.pinnedProfileConfig.map { try JSONEncoder().encode($0) }
    if snapshot.endTime != nil { session.sessionStartSyncPending = false }
    return session
  }

  static func findSession(
    byID id: String,
    in context: ModelContext
  ) throws -> BlockedProfileSession? {
    let descriptor = FetchDescriptor<BlockedProfileSession>(
      predicate: #Predicate { $0.id == id }
    )
    return try context.fetch(descriptor).first
  }

  static func recentInactiveSessions(
    in context: ModelContext,
    limit: Int = 50
  ) -> [BlockedProfileSession] {
    var descriptor = FetchDescriptor<BlockedProfileSession>(
      predicate: #Predicate { $0.endTime != nil },
      sortBy: [SortDescriptor(\.endTime, order: .reverse)]
    )
    descriptor.fetchLimit = limit

    return (try? context.fetch(descriptor)) ?? []
  }
}
