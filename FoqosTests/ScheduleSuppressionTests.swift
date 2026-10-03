import FoqosShared
import XCTest

@testable import FamilyFoqos

final class ScheduleSuppressionTests: XCTestCase {
  func testStoppedOccurrenceSuppressionAcrossEditsAndOvernight() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = calendar.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 12))!
    func date(_ hour: Int, _ minute: Int = 0, day: Int = 0) -> Date {
      let localDay = calendar.date(byAdding: .day, value: day, to: now)!
      return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: localDay)!
    }
    let cases: [(Int, Int, Date, Date?, Bool)] = [
      (10, 0, date(10, 6), date(10, 5), false),
      (10, 0, date(10), date(10, 5, day: -1), true),
      (9, 50, date(9, 51), date(10, 5), false),
      (14, 0, date(14), date(10, 5), true),
      (10, 0, date(10), nil, true),
      (10, 0, date(10, 1), date(10), false),
      (22, 0, date(3), date(22, 30, day: -1), false),
      (22, 0, date(3), nil, true),
    ]
    let suiteName = "ScheduleSuppression-\(UUID())"
    let defaults = UserDefaults(suiteName: suiteName)!
    SharedData.configure(suite: defaults)
    defer { defaults.removePersistentDomain(forName: suiteName) }
    for (hour, minute, delivery, stopped, eligible) in cases {
      let model = BlockedProfiles(name: "Suppression")
      model.startTriggers = .init(schedule: true)
      model.startSchedule = .init(days: Weekday.allCases, hour: hour, minute: minute, updatedAt: .distantPast)
      model.stopConditions = .init(manual: true)
      if hour == 22 {
        model.stopConditions.schedule = true
        model.stopSchedule = .init(days: Weekday.allCases, hour: 6, minute: 0, updatedAt: .distantPast)
      }
      model.scheduleLastStoppedAt = stopped
      XCTAssertEqual(SharedData.scheduledStartOccurrence(for: BlockedProfiles.getSnapshot(for: model), now: delivery, calendar: calendar) != nil, eligible)
    }
  }
}
