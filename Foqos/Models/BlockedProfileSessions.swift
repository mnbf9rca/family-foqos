import Foundation
@preconcurrency import SwiftData  // ReferenceWritableKeyPath in SortDescriptor lacks Sendable conformance

@Model
class BlockedProfileSession: BreakDurationCalculable {
  @Attribute(.unique) var id: String
  var tag: String

  @Relationship var blockedProfile: BlockedProfiles

  var startTime: Date
  var endTime: Date?

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
    startTime: Date = Date()
  ) {
    self.id = UUID().uuidString
    self.tag = tag
    self.blockedProfile = blockedProfile
    self.startTime = startTime
    self.forceStarted = forceStarted

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
    self.endTime = now

    // If this was a schedule-started session, record when it stopped.
    // The reader in ScheduleTimerActivity compares this against today's start time.
    // Schedule-started sessions have tag == profile UUID (set by createSessionForScheduler).
    let isScheduleStarted = (tag == blockedProfile.id.uuidString)
    if isScheduleStarted, modelContext != nil {
      blockedProfile.scheduleLastStoppedAt = now
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
      breakStartTime: breakStartTime,
      breakEndTime: breakEndTime,
      forceStarted: forceStarted,
      oneMoreMinuteUsed: oneMoreMinuteUsed,
      oneMoreMinuteStartTime: oneMoreMinuteStartTime,
      breakEndDeadline: breakEndDeadline,
      oneMoreMinuteDeadline: oneMoreMinuteDeadline,
      pinnedProfileConfig: pinnedProfileConfigData.flatMap {
        try? JSONDecoder().decode(SharedData.ProfileSnapshot.self, from: $0)
      }
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
    startTime: Date = Date()
  ) -> BlockedProfileSession {
    let newSession = BlockedProfileSession(
      tag: tag,
      blockedProfile: profile,
      forceStarted: forceStart,
      startTime: startTime
    )

    SharedData.createActiveSharedSession(for: newSession.toSnapshot())

    context.insert(newSession)
    return newSession
  }

  static func upsertSessionFromSnapshot(
    in context: ModelContext,
    withSnapshot rawSnapshot: SharedData.SessionSnapshot
  ) {
    let snapshot =
      rawSnapshot.endTime != nil ? SharedData.normalizedForEnd(rawSnapshot) : rawSnapshot
    let profileID = snapshot.blockedProfileId

    guard let existingProfile = try? BlockedProfiles.findProfile(byID: profileID, in: context)
    else {
      Log.warning("Profile not found when creating session from snapshot", category: .session)
      return
    }

    // Try to find an existing session by id
    if let existingSession = try? findSession(byID: snapshot.id, in: context) {
      existingSession.tag = snapshot.tag
      existingSession.startTime = snapshot.startTime
      existingSession.endTime = snapshot.endTime
      existingSession.breakStartTime = snapshot.breakStartTime
      existingSession.breakEndTime = snapshot.breakEndTime
      existingSession.forceStarted = snapshot.forceStarted
      existingSession.oneMoreMinuteUsed = snapshot.oneMoreMinuteUsed
      existingSession.oneMoreMinuteStartTime = snapshot.oneMoreMinuteStartTime
      existingSession.breakEndDeadline = snapshot.breakEndDeadline
      existingSession.oneMoreMinuteDeadline = snapshot.oneMoreMinuteDeadline
      existingSession.pinnedProfileConfigData = snapshot.pinnedProfileConfig.flatMap {
        try? JSONEncoder().encode($0)
      }

      // manually save to ensure changes are persisted
      do {
        try context.save()
      } catch {
        Log.error(
          "Failed to save session snapshot update: \(error.localizedDescription)",
          category: .session)
      }
      return
    }

    // Create new session from snapshot
    let newSession = BlockedProfileSession(
      tag: snapshot.tag,
      blockedProfile: existingProfile,
      forceStarted: snapshot.forceStarted
    )
    // Override auto-generated values with snapshot-provided ones
    newSession.id = snapshot.id
    newSession.startTime = snapshot.startTime
    newSession.endTime = snapshot.endTime
    newSession.breakStartTime = snapshot.breakStartTime
    newSession.breakEndTime = snapshot.breakEndTime
    newSession.oneMoreMinuteUsed = snapshot.oneMoreMinuteUsed
    newSession.oneMoreMinuteStartTime = snapshot.oneMoreMinuteStartTime
    newSession.breakEndDeadline = snapshot.breakEndDeadline
    newSession.oneMoreMinuteDeadline = snapshot.oneMoreMinuteDeadline
    newSession.pinnedProfileConfigData = snapshot.pinnedProfileConfig.flatMap {
      try? JSONEncoder().encode($0)
    }

    // Let auto-save handle inserts
    context.insert(newSession)
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
