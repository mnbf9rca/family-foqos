import XCTest

@testable import FamilyFoqos

final class ScheduleWindowValidationTests: XCTestCase {

  // MARK: - Pure modular window math

  func testGivenSameDayTenMinuteWindow_WhenComputingWindow_ThenReturnsTen() {
    XCTAssertEqual(
      TriggerValidator.scheduleWindowMinutes(
        startHour: 9, startMinute: 0, stopHour: 9, stopMinute: 10), 10)
  }

  func testGivenSameDayFifteenMinuteWindow_WhenComputingWindow_ThenReturnsFifteen() {
    XCTAssertEqual(
      TriggerValidator.scheduleWindowMinutes(
        startHour: 9, startMinute: 0, stopHour: 9, stopMinute: 15), 15)
  }

  func testGivenCrossMidnightNearBoundary_WhenComputingWindow_ThenReturnsSubFifteen() {
    // 23:59 -> 00:00 is a 1-minute window, NOT ~24h.
    XCTAssertEqual(
      TriggerValidator.scheduleWindowMinutes(
        startHour: 23, startMinute: 59, stopHour: 0, stopMinute: 0), 1)
  }

  func testGivenLegitimateOvernightWindow_WhenComputingWindow_ThenReturns480() {
    XCTAssertEqual(
      TriggerValidator.scheduleWindowMinutes(
        startHour: 22, startMinute: 0, stopHour: 6, stopMinute: 0), 480)
  }

  func testGivenIdenticalTimes_WhenComputingWindow_ThenReturnsZero() {
    XCTAssertEqual(
      TriggerValidator.scheduleWindowMinutes(
        startHour: 9, startMinute: 0, stopHour: 9, stopMinute: 0), 0)
  }
}

@MainActor
final class ScheduleWindowValidationIntegrationTests: XCTestCase {

  private func makeModel(
    startHour: Int,
    startMinute: Int,
    stopHour: Int,
    stopMinute: Int,
    days: [Weekday] = [.monday]
  ) -> TriggerConfigurationModel {
    let model = TriggerConfigurationModel()
    model.startTriggers.schedule = true
    model.stopConditions.schedule = true
    model.startSchedule = ProfileScheduleTime(
      days: days, hour: startHour, minute: startMinute, updatedAt: .distantPast)
    model.stopSchedule = ProfileScheduleTime(
      days: days, hour: stopHour, minute: stopMinute, updatedAt: .distantPast)
    return model
  }

  func testGivenSubFifteenSameDayWindow_WhenValidating_ThenAppendsWindowError() {
    let model = makeModel(startHour: 9, startMinute: 0, stopHour: 9, stopMinute: 10)
    model.validate()
    XCTAssertTrue(model.validationErrors.contains { $0.contains("at least 15 minutes") })
  }

  func testGivenCrossMidnightSubFifteenWindow_WhenValidating_ThenAppendsWindowError() {
    let model = makeModel(startHour: 23, startMinute: 55, stopHour: 0, stopMinute: 5)
    model.validate()
    XCTAssertTrue(model.validationErrors.contains { $0.contains("at least 15 minutes") })
  }

  func testGivenFifteenMinuteWindow_WhenValidating_ThenNoWindowError() {
    let model = makeModel(startHour: 9, startMinute: 0, stopHour: 9, stopMinute: 15)
    model.validate()
    XCTAssertFalse(model.validationErrors.contains { $0.contains("at least 15 minutes") })
  }

  func testGivenLegitimateOvernightWindow_WhenValidating_ThenNoWindowError() {
    let model = makeModel(startHour: 22, startMinute: 0, stopHour: 6, stopMinute: 0)
    model.validate()
    XCTAssertFalse(model.validationErrors.contains { $0.contains("at least 15 minutes") })
  }

  func testGivenInactiveMatchingSchedules_WhenValidating_ThenNoSameTimeError() {
    let model = makeModel(startHour: 9, startMinute: 0, stopHour: 9, stopMinute: 0, days: [])
    model.validate()
    XCTAssertFalse(model.validationErrors.contains { $0.contains("can't be the same") })
  }
}
