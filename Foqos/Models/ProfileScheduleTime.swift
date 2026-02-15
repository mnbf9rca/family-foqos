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
    days.compactDaysText()
  }

  /// Returns the next future occurrence of this schedule after the given date.
  /// Walks up to 7 days forward to find the next scheduled day.
  func nextScheduledStartTime(after date: Date, calendar: Calendar = .current) -> Date? {
    guard isActive else { return nil }

    var components = calendar.dateComponents([.year, .month, .day], from: date)
    components.hour = hour
    components.minute = minute
    components.second = 0
    guard let todayStart = calendar.date(from: components) else { return nil }

    // If we haven't passed today's start yet, today could be the candidate;
    // otherwise start looking from tomorrow's start time.
    var candidate: Date
    if date < todayStart {
      candidate = todayStart
    } else {
      guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: todayStart) else {
        return nil
      }
      candidate = tomorrow
    }

    for _ in 0..<7 {
      let weekdayRaw = calendar.component(.weekday, from: candidate)
      if let weekday = Weekday(rawValue: weekdayRaw), days.contains(weekday) {
        return candidate
      }
      guard let nextDay = calendar.date(byAdding: .day, value: 1, to: candidate) else {
        return nil
      }
      candidate = nextDay
    }
    return nil
  }

  /// Returns this schedule's start time on the given date.
  /// Constructs a Date from the date's year/month/day and this schedule's hour:minute.
  func scheduledStartTime(on date: Date, calendar: Calendar = .current) -> Date? {
    var components = calendar.dateComponents([.year, .month, .day], from: date)
    components.hour = hour
    components.minute = minute
    components.second = 0
    return calendar.date(from: components)
  }

  /// Returns the start Date of the currently active schedule window, or nil
  /// if the current time is not inside any window.
  ///
  /// - Start-only (no stop): in window after today's start time
  /// - Same-day (start < stop): in window when todayStart <= now < todayStop
  /// - Overnight (start >= stop): could be in tonight's window (now >= todayStart)
  ///   or last night's window (now < todayStop, start was yesterday)
  func activeWindowStart(
    on date: Date,
    stopSchedule: ProfileScheduleTime?,
    calendar: Calendar = .current
  ) -> Date? {
    guard let todayStart = scheduledStartTime(on: date, calendar: calendar) else { return nil }

    // Start-only: in window if past today's start
    guard let stopSched = stopSchedule else {
      return date >= todayStart ? todayStart : nil
    }

    guard let todayStop = stopSched.scheduledStartTime(on: date, calendar: calendar) else {
      return nil
    }

    let isOvernight =
      (hour > stopSched.hour)
      || (hour == stopSched.hour && minute >= stopSched.minute)

    if !isOvernight {
      // Same-day (e.g., 10:00-17:00)
      return (date >= todayStart && date < todayStop) ? todayStart : nil
    } else {
      // Overnight (e.g., 22:00-06:00)
      if date >= todayStart {
        return todayStart  // In tonight's window
      } else if date < todayStop {
        // In last night's window — start was yesterday
        return calendar.date(byAdding: .day, value: -1, to: todayStart)
      } else {
        return nil  // Between windows (e.g., 12:00)
      }
    }
  }

  /// Whether this schedule should be actively running right now.
  /// Single source of truth combining: window detection, day check, age check, suppression.
  ///
  /// Used by both the DA extension reader and the foreground catch-up mechanism.
  func shouldBeActiveNow(
    stopSchedule: ProfileScheduleTime?,
    lastStoppedAt: Date?,
    on date: Date = Date(),
    calendar: Calendar = .current
  ) -> Bool {
    // 1. Are we inside a schedule window?
    guard
      let windowStart = activeWindowStart(
        on: date, stopSchedule: stopSchedule, calendar: calendar
      )
    else { return false }

    // 2. Was the window's start day a scheduled day?
    let startWeekdayRaw = calendar.component(.weekday, from: windowStart)
    guard let startWeekday = Weekday(rawValue: startWeekdayRaw),
      days.contains(startWeekday)
    else { return false }

    // 3. Is the schedule old enough? (prevents immediate fire on save)
    guard olderThanOneMinute(now: date) else { return false }

    // 4. Was this window manually stopped?
    if let stoppedAt = lastStoppedAt, windowStart <= stoppedAt {
      return false
    }

    return true
  }

  var scheduleDescription: String {
    let dayNames = days.compactDaysText()
    let time = String(format: "%d:%02d", hour, minute)
    return "\(dayNames) at \(time)"
  }
}
