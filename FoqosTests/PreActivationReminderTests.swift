import XCTest

@testable import FamilyFoqos

final class PreActivationReminderTests: XCTestCase {
  // MARK: - Identifier Tests

  func testPreActivationReminderIdentifier_includesMinutes() {
    let profileId = UUID()
    let identifier = TimersUtil.preActivationReminderIdentifier(for: profileId, minutes: 3)

    XCTAssertEqual(identifier, "pre-activation-reminder-\(profileId.uuidString)-3")
  }

  func testPreActivationReminderIdentifier_uniquePerMinuteValue() {
    let profileId = UUID()
    let id1 = TimersUtil.preActivationReminderIdentifier(for: profileId, minutes: 1)
    let id2 = TimersUtil.preActivationReminderIdentifier(for: profileId, minutes: 5)

    XCTAssertNotEqual(id1, id2)
  }

  func testPreActivationReminderIdentifier_hasCorrectPrefix() {
    let profileId = UUID()
    let identifier = TimersUtil.preActivationReminderIdentifier(for: profileId, minutes: 2)

    XCTAssertTrue(identifier.hasPrefix(TimersUtil.preActivationReminderPrefix))
  }

  func testAllPreActivationReminderIdentifiers_returns5Ids() {
    let profileId = UUID()
    let ids = TimersUtil.allPreActivationReminderIdentifiers(for: profileId)

    XCTAssertEqual(ids.count, 5)
    for minutes in 1...5 {
      let expected = "pre-activation-reminder-\(profileId.uuidString)-\(minutes)"
      XCTAssertTrue(ids.contains(expected), "Missing identifier for \(minutes) minutes")
    }
  }

  func testReminderTimeCalculation() {
    let calendar = Calendar.current
    let now = Date()

    guard
      let scheduledStart = calendar.date(
        bySettingHour: 10, minute: 0, second: 0, of: now
      )
    else {
      XCTFail("Could not create scheduled start time")
      return
    }

    let reminderMinutes = 5
    guard
      let reminderTime = calendar.date(
        byAdding: .minute, value: -reminderMinutes, to: scheduledStart
      )
    else {
      XCTFail("Could not calculate reminder time")
      return
    }

    let reminderHour = calendar.component(.hour, from: reminderTime)
    let reminderMinute = calendar.component(.minute, from: reminderTime)

    XCTAssertEqual(reminderHour, 9)
    XCTAssertEqual(reminderMinute, 55)
  }
}
