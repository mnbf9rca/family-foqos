// Foqos/Models/ProfileScheduleTime.swift
import Foundation

/// A time-of-day schedule for starting or stopping a profile.
/// Independent from the existing BlockedProfileSchedule which combines start and stop.
struct ProfileScheduleTime: Codable, Equatable {
  var days: [Weekday]
  var hour: Int
  var minute: Int
  var updatedAt: Date

  var isActive: Bool { !days.isEmpty }

  func isTodayScheduled(now: Date = Date(), calendar: Calendar = .current) -> Bool {
    guard isActive else { return false }
    let currentWeekdayRaw = calendar.component(.weekday, from: now)
    guard let today = Weekday(rawValue: currentWeekdayRaw) else { return false }
    return days.contains(today)
  }

  func olderThanOneMinute(now: Date = Date()) -> Bool {
    return now.timeIntervalSince(updatedAt) > 1 * 60
  }

  var formattedTime: String {
    var h = hour % 12
    if h == 0 { h = 12 }
    let isPM = hour >= 12
    return "\(h):\(String(format: "%02d", minute)) \(isPM ? "PM" : "AM")"
  }

  var daysText: String {
    days.sorted { $0.rawValue < $1.rawValue }
      .map { $0.shortLabel }
      .joined(separator: " ")
  }

  /// Returns the next future occurrence of this schedule after the given date.
  /// Walks up to 7 days forward to find the next scheduled day.
  func nextScheduledStartTime(after date: Date, calendar: Calendar = .current) -> Date? {
    guard isActive else { return nil }

    var components = calendar.dateComponents([.year, .month, .day], from: date)
    components.hour = hour
    components.minute = minute
    components.second = 0
    let todayStart = calendar.date(from: components)!

    // If we haven't passed today's start yet, today could be the candidate;
    // otherwise start looking from tomorrow's start time.
    var candidate =
      date < todayStart
      ? todayStart
      : calendar.date(byAdding: .day, value: 1, to: todayStart)!

    for _ in 0..<7 {
      let weekdayRaw = calendar.component(.weekday, from: candidate)
      if let weekday = Weekday(rawValue: weekdayRaw), days.contains(weekday) {
        return candidate
      }
      candidate = calendar.date(byAdding: .day, value: 1, to: candidate)!
    }
    return nil
  }

  var scheduleDescription: String {
    let dayNames = days.map { $0.shortLabel }.joined(separator: " ")
    let time = String(format: "%d:%02d", hour, minute)
    return "\(dayNames) at \(time)"
  }
}
