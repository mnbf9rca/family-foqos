import Foundation

/// A time-of-day schedule for starting or stopping a profile.
/// Independent from the existing BlockedProfileSchedule which combines start and stop.
public struct ProfileScheduleTime: Codable, Equatable {
  public var days: [Weekday]
  public var hour: Int
  public var minute: Int
  public var updatedAt: Date

  public init(
    days: [Weekday],
    hour: Int,
    minute: Int,
    updatedAt: Date
  ) {
    self.days = days
    self.hour = hour
    self.minute = minute
    self.updatedAt = updatedAt
  }

  public var isActive: Bool { !days.isEmpty }

  public func isTodayScheduled(now: Date = Date(), calendar: Calendar = .current) -> Bool {
    guard isActive else { return false }
    let currentWeekdayRaw = calendar.component(.weekday, from: now)
    guard let today = Weekday(rawValue: currentWeekdayRaw) else { return false }
    return days.contains(today)
  }

  public func olderThanOneMinute(now: Date = Date()) -> Bool {
    return now.timeIntervalSince(updatedAt) > 1 * 60
  }

  public var isValid: Bool {
    isActive && (0...23).contains(hour) && (0...59).contains(minute)
  }

  public func conflicts(with other: ProfileScheduleTime) -> Bool {
    isValid && other.isValid && hour == other.hour && minute == other.minute
      && days.contains(where: other.days.contains)
  }

  /// The latest daily OS start, before checking whether its weekday is enabled.
  public func previousDailyClockOccurrence(atOrBefore date: Date, calendar: Calendar = .current) -> Date? {
    guard isValid, let today = scheduledStartTime(on: date, calendar: calendar) else { return nil }
    if today <= date { return today }
    guard let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: date)) else { return nil }
    return scheduledStartTime(on: yesterday, calendar: calendar)
  }

  /// The latest enabled stop, including a missed occurrence on an earlier weekday.
  public func previousOccurrence(atOrBefore date: Date, calendar: Calendar = .current) -> Date? {
    guard isValid else { return nil }
    for offset in 0...7 {
      guard let day = calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: date)),
        let occurrence = scheduledStartTime(on: day, calendar: calendar)
      else { return nil }
      if occurrence <= date && isTodayScheduled(now: occurrence, calendar: calendar) { return occurrence }
    }
    return nil
  }

  public func hasOccurrence(from start: Date, through end: Date, calendar: Calendar = .current) -> Bool {
    guard start <= end, let occurrence = previousOccurrence(atOrBefore: end, calendar: calendar) else { return false }
    return occurrence >= start
  }

  public var formattedTime: String {
    var h = hour % 12
    if h == 0 { h = 12 }
    let isPM = hour >= 12
    return "\(h):\(String(format: "%02d", minute)) \(isPM ? "PM" : "AM")"
  }

  public var daysText: String {
    days.compactDaysText()
  }

  /// Returns the next future occurrence of this schedule after the given date.
  /// Walks up to 7 days forward to find the next scheduled day.
  public func nextScheduledStartTime(after date: Date, calendar: Calendar = .current) -> Date? {
    guard isValid else { return nil }
    for offset in 0...7 {
      guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: date)),
        let occurrence = scheduledStartTime(on: day, calendar: calendar)
      else { return nil }
      if occurrence > date && isTodayScheduled(now: occurrence, calendar: calendar) { return occurrence }
    }
    return nil
  }

  /// Returns this schedule's start time on the given date.
  /// Constructs a Date from the date's year/month/day and this schedule's hour:minute.
  /// Does not check whether `date` falls on a scheduled day — callers are responsible for day checks.
  public func scheduledStartTime(on date: Date, calendar: Calendar = .current) -> Date? {
    guard isValid else { return nil }
    var components = calendar.dateComponents([.year, .month, .day], from: date)
    components.hour = hour
    components.minute = minute
    components.second = 0
    return calendar.date(from: components)
  }

  public var scheduleDescription: String {
    let dayNames = days.compactDaysText()
    let time = String(format: "%d:%02d", hour, minute)
    return "\(dayNames) at \(time)"
  }
}
