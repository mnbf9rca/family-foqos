import Foundation

public enum Weekday: Int, CaseIterable, Codable, Equatable {
  case sunday = 1
  case monday
  case tuesday
  case wednesday
  case thursday
  case friday
  case saturday

  public var name: String {
    switch self {
    case .sunday: return "Sunday"
    case .monday: return "Monday"
    case .tuesday: return "Tuesday"
    case .wednesday: return "Wednesday"
    case .thursday: return "Thursday"
    case .friday: return "Friday"
    case .saturday: return "Saturday"
    }
  }

  public var shortLabel: String {
    switch self {
    case .sunday: return "Su"
    case .monday: return "Mo"
    case .tuesday: return "Tu"
    case .wednesday: return "We"
    case .thursday: return "Th"
    case .friday: return "Fr"
    case .saturday: return "Sa"
    }
  }

  /// Returns all weekdays ordered by the locale's first day of week.
  public static func localeOrdered(calendar: Calendar = .current) -> [Weekday] {
    let first = calendar.firstWeekday  // 1=Sunday, 2=Monday, etc.
    return (0..<7).compactMap { offset in
      Weekday(rawValue: ((first - 1 + offset) % 7) + 1)
    }
  }
}

extension Array where Element == Weekday {
  /// Sorts weekdays by locale order (e.g., Monday-first in EU locales).
  public func localeSorted(calendar: Calendar = .current) -> [Weekday] {
    let order = Weekday.localeOrdered(calendar: calendar)
    return self.sorted { a, b in
      (order.firstIndex(of: a) ?? 0) < (order.firstIndex(of: b) ?? 0)
    }
  }

  /// Compact display text: "Every day", "Weekdays", "Weekends", or short labels.
  public func compactDaysText(calendar: Calendar = .current) -> String {
    let daySet = Set(self)
    if daySet.count == 7 { return "Every day" }
    let weekdays: Set<Weekday> = [.monday, .tuesday, .wednesday, .thursday, .friday]
    if daySet == weekdays { return "Weekdays" }
    let weekends: Set<Weekday> = [.saturday, .sunday]
    if daySet == weekends { return "Weekends" }
    return self.localeSorted(calendar: calendar)
      .map { $0.shortLabel }
      .joined(separator: " ")
  }
}

public struct BlockedProfileSchedule: Codable, Equatable {
  public var days: [Weekday]

  public var startHour: Int
  public var startMinute: Int
  public var endHour: Int
  public var endMinute: Int

  public var updatedAt: Date = Date()

  public init(
    days: [Weekday],
    startHour: Int,
    startMinute: Int,
    endHour: Int,
    endMinute: Int,
    updatedAt: Date = Date()
  ) {
    self.days = days
    self.startHour = startHour
    self.startMinute = startMinute
    self.endHour = endHour
    self.endMinute = endMinute
    self.updatedAt = updatedAt
  }

  public var isActive: Bool {
    return !days.isEmpty
  }

  public var totalDurationInSeconds: Int {
    let secondsPerDay = 24 * 60 * 60
    let raw = (endHour - startHour) * 3600 + (endMinute - startMinute) * 60
    return raw >= 0 ? raw : raw + secondsPerDay
  }

  public var summaryText: String {
    guard isActive else { return "No Schedule Set" }

    let daysSummary = days.compactDaysText()

    let start = formattedTimeString(hour24: startHour, minute: startMinute)
    let end = formattedTimeString(hour24: endHour, minute: endMinute)

    return "\(daysSummary) · \(start) - \(end)"
  }

  public func isTodayScheduled(now: Date = Date(), calendar: Calendar = .current) -> Bool {
    guard isActive else { return false }
    let currentWeekdayRaw = calendar.component(.weekday, from: now)
    guard let today = Weekday(rawValue: currentWeekdayRaw) else { return false }
    return days.contains(today)
  }

  public func olderThanOneMinute(now: Date = Date()) -> Bool {
    return now.timeIntervalSince(updatedAt) > 1 * 60
  }

  private func formattedTimeString(hour24: Int, minute: Int) -> String {
    var hour = hour24 % 12
    if hour == 0 { hour = 12 }
    let isPM = hour24 >= 12
    return "\(hour):\(String(format: "%02d", minute)) \(isPM ? "PM" : "AM")"
  }
}
