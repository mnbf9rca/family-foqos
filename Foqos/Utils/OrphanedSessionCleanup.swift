import FoqosShared
import Foundation
import SwiftData

@MainActor
enum OrphanedSessionCleanup {
  enum Failure: Error { case activeSession }

  @discardableResult
  static func run(
    context: ModelContext,
    retryLock: Bool = false,
    requireInactive: Bool = false,
    publishedSession: BlockedProfileSession? = nil,
    now: Date = Date(), calendar: Calendar = .current,
    save: (ModelContext) throws -> Void = { try $0.save() },
    removeActivities: (UUID) -> Void = { DeviceActivityCenterUtil.removeActivities(for: $0) },
    deactivateRestrictions: () -> Void = { AppBlockerUtil().deactivateRestrictions() },
    refreshShortcuts: () -> Void = { FamilyFoqosShortcuts.updateAppShortcutParameters() },
    onCommit: () -> Void = {}
  ) throws -> Set<UUID> {
    let profiles = try context.fetch(FetchDescriptor<BlockedProfiles>())
    let sessions = try context.fetch(FetchDescriptor<BlockedProfileSession>())
    let profileIds = Set(profiles.map(\.id))
    // Use the surviving owners, never fault a deleted session's nonoptional relationship.
    let ownedSessionIds = Set(profiles.flatMap { $0.sessions.valid.map(\.id) })
    var localSessions = profiles.flatMap { $0.sessions.valid }
    if let publishedSession, publishedSession.isPersistentModelValid { localSessions.append(publishedSession) }
    let owners = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
    var rebuiltProfiles = false
    var refusedActiveSession = false
    guard
      let removed = SharedData.removeProfileSessions(
        where: { !profileIds.contains($0) }, retryLock: retryLock, discardUnreadableSessions: requireInactive,
        rebuildUnreadableProfiles: requireInactive
          ? {
            rebuiltProfiles = true
            return Dictionary(uniqueKeysWithValues: profiles.map { ($0.id.uuidString, BlockedProfiles.getSnapshot(for: $0)) })
          } : nil,
        allowRemoval: { shared in
          guard requireInactive else { return true }
          @MainActor func isLive(_ session: SharedData.SessionSnapshot) -> Bool {
            guard let owner = owners[session.blockedProfileId] else { return false }
            return genuinelyActive(session, currentProfile: BlockedProfiles.getSnapshot(for: owner), now: now, calendar: calendar)
          }
          refusedActiveSession =
            shared.map(isLive) == true
            || localSessions.contains { local in
              let snapshot = local.toSnapshot()
              // Shared timing wins over an older app copy of the same session.
              if let shared, shared.id == snapshot.id, shared.blockedProfileId == snapshot.blockedProfileId { return false }
              return isLive(snapshot)
            }
          return !refusedActiveSession
        }, onRemoveActive: deactivateRestrictions,
        onCommit: {
          if requireInactive {
            for session in localSessions where session.isActive {
              session.endTime = now
              session.timerEndTime = nil
              session.origin = nil
              if session.breakStartTime != nil && session.breakEndTime == nil { session.breakEndTime = now }
              session.breakEndDeadline = nil
              session.oneMoreMinuteStartTime = nil
              session.oneMoreMinuteDeadline = nil
            }
          }
          onCommit()
        })
    else {
      if refusedActiveSession { throw Failure.activeSession }
      throw CocoaError(.fileWriteUnknown)
    }
    for id in removed {
      removeActivities(id)
      TimersUtil.cancelAllPreActivationReminders(for: id)
      TimersUtil.cancelOwnedReminders(for: id)
    }
    for session in sessions where !ownedSessionIds.contains(session.id) {
      context.delete(session)
    }
    if !removed.isEmpty || rebuiltProfiles { refreshShortcuts() }
    try save(context)
    return profileIds
  }
  private static func genuinelyActive(
    _ session: SharedData.SessionSnapshot, currentProfile: SharedData.ProfileSnapshot, now: Date, calendar: Calendar
  ) -> Bool {
    guard session.endTime == nil else { return false }
    guard !session.id.isEmpty, session.startTime.timeIntervalSinceReferenceDate.isFinite, session.startTime <= now.addingTimeInterval(5 * 60) else {
      Log.error("Reset found session with invalid identity or start time", category: .session)
      return false
    }
    let profile = session.pinnedProfileConfig ?? currentProfile
    guard profile.id == currentProfile.id else {
      Log.error("Reset found session with inconsistent pinned owner", category: .session)
      return false
    }
    let legacy = (profile.profileSchemaVersion ?? 1) < 2
    let legacyTimer = legacy && StrategyManager.isCountdownTag(session.tag)
    var deadline = session.timerEndTime
    if deadline == nil && legacyTimer {
      guard let data = profile.strategyData,
        let timer = try? JSONDecoder().decode(StrategyTimerData.self, from: data), timer.durationInMinutes > 0
      else {
        Log.error("Reset found legacy timer with unreadable duration", category: .session)
        return false
      }
      deadline = session.startTime.addingTimeInterval(Double(timer.durationInMinutes) * 60)
    }
    if let deadline {
      guard deadline.timeIntervalSinceReferenceDate.isFinite, deadline > session.startTime else {
        Log.error("Reset found session with invalid timer deadline", category: .session)
        return false
      }
      if deadline <= now {
        Log.error("Reset found session past its timer deadline", category: .session)
        return false
      }
    } else if !legacy && profile.stopConditions?.timer == true {
      Log.error("Reset found required timer without a deadline", category: .session)
      return false
    }
    let stopSchedule: ProfileScheduleTime?
    if !legacy {
      stopSchedule = profile.stopConditions?.schedule == true ? profile.stopSchedule : nil
      if profile.stopConditions?.schedule == true && stopSchedule?.isValid != true {
        Log.error("Reset found session with malformed enabled stop schedule", category: .session)
        return false
      }
    } else if profile.disableBackgroundStops != true {
      if let independentStop = profile.stopSchedule {
        stopSchedule = independentStop
      } else if session.tag == profile.id.uuidString, let combined = profile.schedule {
        let overnight = combined.endHour * 60 + combined.endMinute < combined.startHour * 60 + combined.startMinute
        let days = overnight ? combined.days.compactMap { Weekday(rawValue: $0.rawValue % 7 + 1) } : combined.days
        stopSchedule = .init(days: days, hour: combined.endHour, minute: combined.endMinute, updatedAt: combined.updatedAt)
      } else {
        stopSchedule = nil
      }
      if let stopSchedule, !stopSchedule.isValid {
        Log.error("Reset found legacy session with malformed stop schedule", category: .session)
        return false
      }
    } else {
      stopSchedule = nil
    }
    if let stopSchedule, let occurrence = stopSchedule.previousOccurrence(atOrBefore: now, calendar: calendar),
      occurrence >= stopSchedule.updatedAt, occurrence >= session.startTime
    {
      Log.error("Reset found session past its scheduled stop", category: .session)
      return false
    }
    return true
  }

}
