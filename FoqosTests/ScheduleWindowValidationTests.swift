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
}
