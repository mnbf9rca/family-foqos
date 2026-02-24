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
    for minutes in TimersUtil.allReminderCleanupRange {
      let expected = "pre-activation-reminder-\(profileId.uuidString)-\(minutes)"
      XCTAssertTrue(ids.contains(expected), "Missing identifier for \(minutes) minutes")
    }
  }

  // MARK: - Profile ID Extraction Tests

  func testProfileIdFromReminderIdentifier_extractsCorrectUUID() {
    let profileId = UUID()
    let identifier = TimersUtil.preActivationReminderIdentifier(for: profileId, minutes: 3)

    XCTAssertEqual(TimersUtil.profileIdFromReminderIdentifier(identifier), profileId)
  }

  func testProfileIdFromReminderIdentifier_returnsNilForNonReminderIdentifier() {
    XCTAssertNil(TimersUtil.profileIdFromReminderIdentifier("some-other-notification"))
  }

  func testProfileIdFromReminderIdentifier_returnsNilForMalformedIdentifier() {
    XCTAssertNil(TimersUtil.profileIdFromReminderIdentifier("pre-activation-reminder-not-a-uuid-3"))
  }

  func testPreActivationReminderThreadIdentifier_format() {
    let profileId = UUID()
    let expected = "pre-activation-reminder-\(profileId.uuidString)"

    XCTAssertEqual(TimersUtil.preActivationReminderThreadIdentifier(for: profileId), expected)
  }

  // MARK: - Model Behavior Tests

  func testPreActivationReminderTimes_roundTrip() {
    let profile = BlockedProfiles(name: "Test")
    profile.preActivationReminderTimes = [1, 3, 5]

    XCTAssertEqual(profile.preActivationReminderTimes, [1, 3, 5])
  }

  func testPreActivationReminderTimes_deduplicatesAndSorts() {
    let profile = BlockedProfiles(name: "Test")
    profile.preActivationReminderTimes = [5, 1, 5, 3]

    XCTAssertEqual(profile.preActivationReminderTimes, [1, 3, 5])
  }

  func testPreActivationReminderTimes_filtersOutOfRangeValues() {
    let profile = BlockedProfiles(name: "Test")
    profile.preActivationReminderTimes = [0, 1, 2, 3, 4, 5, 6, 255]

    XCTAssertEqual(profile.preActivationReminderTimes, [1, 3, 5])
  }

  func testPreActivationReminderTimes_getterFiltersLegacyPersistedValues() {
    let profile = BlockedProfiles(name: "Test")
    // Bypass the setter by writing directly to the raw data property,
    // simulating legacy persisted data or unfiltered CloudKit sync
    let legacyValues: [UInt8] = [1, 2, 3, 4, 5]
    profile.preActivationReminderTimesData = try! JSONEncoder().encode(legacyValues)

    // Getter should filter out unsupported values (2, 4)
    XCTAssertEqual(profile.preActivationReminderTimes, [1, 3, 5])
  }

  func testPreActivationReminderEnabled_emptyMeansDisabled() {
    let profile = BlockedProfiles(name: "Test")
    profile.preActivationReminderTimes = []

    XCTAssertFalse(profile.preActivationReminderEnabled)
  }

  func testPreActivationReminderEnabled_nonEmptyMeansEnabled() {
    let profile = BlockedProfiles(name: "Test")
    profile.preActivationReminderTimes = [3]

    XCTAssertTrue(profile.preActivationReminderEnabled)
  }

  // MARK: - Time Calculation Tests

  func testReminderTimeCalculation() {
    let calendar = Calendar(identifier: .gregorian)
    // Use a fixed reference date to avoid midnight/DST boundary issues
    let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)  // 2023-11-14

    guard
      let scheduledStart = calendar.date(
        bySettingHour: 10, minute: 0, second: 0, of: referenceDate
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
