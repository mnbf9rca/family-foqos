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
    for minutes in TimersUtil.supportedReminderRange {
      let expected = "pre-activation-reminder-\(profileId.uuidString)-\(minutes)"
      XCTAssertTrue(ids.contains(expected), "Missing identifier for \(minutes) minutes")
    }
  }

  // MARK: - Model Behavior Tests

  func testPreActivationReminderTimes_roundTrip() {
    let profile = BlockedProfiles(name: "Test")
    profile.preActivationReminderTimes = [1, 3, 5]

    XCTAssertEqual(profile.preActivationReminderTimes, [1, 3, 5])
  }

  func testPreActivationReminderTimes_deduplicatesAndSorts() {
    let profile = BlockedProfiles(name: "Test")
    profile.preActivationReminderTimes = [3, 1, 3, 2]

    XCTAssertEqual(profile.preActivationReminderTimes, [1, 2, 3])
  }

  func testPreActivationReminderTimes_filtersOutOfRangeValues() {
    let profile = BlockedProfiles(name: "Test")
    profile.preActivationReminderTimes = [0, 1, 3, 6, 255]

    XCTAssertEqual(profile.preActivationReminderTimes, [1, 3])
  }

  func testPreActivationReminderEnabled_emptyMeansDisabled() {
    let profile = BlockedProfiles(name: "Test")
    profile.preActivationReminderTimes = []

    XCTAssertFalse(profile.preActivationReminderEnabled)
  }

  func testPreActivationReminderEnabled_nonEmptyMeansEnabled() {
    let profile = BlockedProfiles(name: "Test")
    profile.preActivationReminderTimes = [2]

    XCTAssertTrue(profile.preActivationReminderEnabled)
  }

  // MARK: - Time Calculation Tests

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
