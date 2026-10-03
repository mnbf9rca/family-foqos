import FoqosShared
import XCTest

@testable import FamilyFoqos

@MainActor
final class ScheduleWindowValidationTests: XCTestCase {
  func testIndependentValidationMatrix() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let cases: [([Weekday], Int, Int, [Weekday], Int, Int, [String])] = [
      ([.monday], 9, 0, [.friday], 9, 0, []),
      ([.monday], 9, 0, [.friday], 9, 10, []),
      ([.monday], 9, 0, [.monday], 9, 1, []),
      ([.sunday], 23, 59, [.monday], 0, 0, []),
      ([.monday], 9, 0, [.monday, .friday], 9, 0, ["Choose different moments for scheduled start and stop."]),
      ([], 9, 0, [.friday], 17, 0, ["Choose the days and time for this schedule."]),
      ([.monday], -1, 0, [.friday], 17, 0, ["Choose the days and time for this schedule."]),
      ([.monday], 9, 60, [.friday], 17, 0, ["Choose the days and time for this schedule."]),
    ]
    for (startDays, startHour, startMinute, stopDays, stopHour, stopMinute, expected) in cases {
      let model = TriggerConfigurationModel()
      model.startTriggers = .init(schedule: true)
      model.stopConditions = .init(manual: true, schedule: true)
      model.startSchedule = .init(days: startDays, hour: startHour, minute: startMinute, updatedAt: now)
      model.stopSchedule = .init(days: stopDays, hour: stopHour, minute: stopMinute, updatedAt: now)
      model.validate()
      XCTAssertEqual(model.validationErrors, expected)
    }
  }

  func testDisabledSchedulesCannotConflictAndTimerLimitsRemainIndependent() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let model = TriggerConfigurationModel()
    model.startTriggers = .init(manual: true)
    model.stopConditions = .init(manual: true, schedule: true)
    model.startSchedule = .init(days: [.monday], hour: 9, minute: 0, updatedAt: now)
    model.stopSchedule = model.startSchedule
    model.validate()
    XCTAssertEqual(model.validationErrors, [])
    model.stopConditions.timer = true
    model.stopConditions.timerDurationMinutes = 1
    model.validate()
    XCTAssertEqual(model.validationErrors, ["Choose a timer from 15 minutes to 23 hours 59 minutes."])
  }

  func testSchedulePickerSavePreservesUnchangedRecurrenceAndStampsOnlyActualChanges() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let stored = ProfileScheduleTime(days: [.friday, .monday], hour: 17, minute: 0, updatedAt: now.addingTimeInterval(-3600))
    let cases: [(Set<Weekday>, Int, Int, Bool)] = [
      ([.monday, .friday], 17, 0, false),
      ([.friday], 17, 0, true),
      ([.monday, .friday], 18, 0, true),
      ([.monday, .friday], 17, 1, true),
    ]
    for (days, hour, minute, changed) in cases {
      let saved = try XCTUnwrap(
        ScheduleTimePicker.scheduleAfterSaving(
          existing: stored, days: days, hour: hour, minute: minute, now: now))
      if changed {
        XCTAssertEqual(Set(saved.days), days)
        XCTAssertEqual(saved.hour, hour)
        XCTAssertEqual(saved.minute, minute)
        XCTAssertEqual(saved.updatedAt, now)
      } else {
        XCTAssertEqual(saved, stored, "An unchanged save preserves the timestamp and stored value")
      }
    }
    var toggled = Set(stored.days)
    toggled.remove(.monday)
    toggled.insert(.monday)
    XCTAssertEqual(
      ScheduleTimePicker.scheduleAfterSaving(
        existing: stored, days: toggled, hour: 17, minute: 0, now: now), stored)
    let created = try XCTUnwrap(
      ScheduleTimePicker.scheduleAfterSaving(
        existing: nil, days: [.friday], hour: 17, minute: 0, now: now))
    XCTAssertEqual(created.updatedAt, now)
    XCTAssertEqual(Set(created.days), [.friday])
    XCTAssertNil(
      ScheduleTimePicker.scheduleAfterSaving(
        existing: stored, days: [], hour: 17, minute: 0, now: now))
  }

}
