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

  func olderThan15Minutes(now: Date = Date()) -> Bool {
    return now.timeIntervalSince(updatedAt) > 15 * 60
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

  var scheduleDescription: String {
    let dayNames = days.map { $0.shortLabel }.joined(separator: " ")
    let time = String(format: "%d:%02d", hour, minute)
    return "\(dayNames) at \(time)"
  }
}
