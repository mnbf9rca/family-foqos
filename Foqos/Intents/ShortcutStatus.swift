import Foundation
import SwiftData

@MainActor
enum ShortcutStatus {
  static func read(
    manager: StrategyManager, context: ModelContext, askedProfileId: UUID? = nil
  ) throws -> (isActive: Bool, dialog: String) {
    do {
      let asked: BlockedProfiles?
      if let askedProfileId {
        guard let profile = try BlockedProfiles.findProfile(byID: askedProfileId, in: context) else {
          throw IntentError.profileNotFound
        }
        asked = profile
      } else {
        asked = nil
      }
      try manager.loadActiveSession(context: context)
      let now = Date()
      return answer(
        session: manager.activeSession, asked: asked,
        grantRemaining: manager.grantCountdownRemaining(now: now), now: now)
    } catch let error as IntentError { throw error } catch { throw IntentError.unexpected("Failed to load session data. Open Family Foqos and try again.") }
  }

  static func answer(
    session: BlockedProfileSession?, asked: BlockedProfiles?, grantRemaining: TimeInterval?,
    now: Date, calendar: Calendar = .current
  ) -> (isActive: Bool, dialog: String) {
    guard let session, session.isActive else {
      guard let asked else { return (false, "No session is active.") }
      if asked.profileSchemaVersion == 1, asked.schedule?.isActive == true {
        return (false, "No session is active, and \(asked.name)'s legacy schedule timing is unavailable.")
      }
      if asked.startTriggers.schedule, let schedule = asked.startSchedule,
        let next = schedule.nextScheduledStartTime(after: now, calendar: calendar)
      {
        return (false, "No session is active, and \(asked.name) is next scheduled to start \(dateText(next, now: now, calendar: calendar)).")
      }
      return (false, "No session is active, and \(asked.name) has no scheduled start.")
    }
    let profile = session.blockedProfile
    let matches = asked == nil || asked?.id == profile.id
    let prefix = matches ? "" : "\(asked!.name) is not active; "
    var clauses: [String] = []
    if let remaining = grantRemaining, remaining > 0 {
      if session.breakStartTime != nil && session.breakEndTime == nil {
        clauses.append("\(durationText(remaining)) left in its break")
      } else if session.oneMoreMinuteStartTime != nil {
        clauses.append("\(durationText(remaining)) left in its one-more-minute grant")
      }
    }
    if let deadline = session.timerEndTime {
      let remaining = max(0, deadline.timeIntervalSince(now))
      if remaining == 0 {
        let grant = clauses.isEmpty ? "" : ", with " + clauses.joined(separator: " and ")
        return (matches, "\(prefix)\(profile.name) is still active\(grant), though its timer time has elapsed.")
      }
      clauses.append("\(durationText(remaining)) left on its timer")
    } else if profile.profileSchemaVersion == 1, profile.schedule?.isActive == true {
      let grant = clauses.isEmpty ? "" : ", with " + clauses.joined(separator: " and ")
      return (matches, "\(prefix)\(profile.name) is active\(grant), but its legacy schedule timing is unavailable.")
    } else if profile.stopConditions.schedule && !profile.disableBackgroundStops,
      let schedule = profile.stopSchedule,
      let next = schedule.nextScheduledStartTime(after: now, calendar: calendar)
    {
      clauses.append("its next scheduled stop \(dateText(next, now: now, calendar: calendar))")
    } else {
      clauses.append("no end time available")
    }
    return (matches, "\(prefix)\(profile.name) is active, with \(clauses.joined(separator: " and ")).")
  }

  private static func durationText(_ seconds: TimeInterval) -> String {
    if seconds < 60 { return "less than a minute" }
    let minutes = Int(ceil(seconds / 60))
    return minutes == 1 ? "1 minute" : "\(minutes) minutes"
  }

  private static func dateText(_ date: Date, now: Date, calendar: Calendar) -> String {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.timeStyle = .short
    let time = formatter.string(from: date)
    if calendar.isDate(date, inSameDayAs: now) { return "today at \(time)" }
    formatter.timeStyle = .none
    formatter.dateStyle = .medium
    return "\(formatter.string(from: date)) at \(time)"
  }
}
