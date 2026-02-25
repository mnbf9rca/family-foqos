import XCTest

@testable import FamilyFoqos

final class PreActivationReminderTests: XCTestCase {
  // MARK: - Identifier Tests

  func testGivenProfileAndMinutes_WhenGeneratingIdentifier_ThenIncludesMinutes() {
    let profileId = UUID()
    let identifier = TimersUtil.preActivationReminderIdentifier(for: profileId, minutes: 3)

    XCTAssertEqual(identifier, "pre-activation-reminder-\(profileId.uuidString)-3")
  }

  func testGivenDifferentMinuteValues_WhenGeneratingIdentifiers_ThenProducesUniqueIds() {
    let profileId = UUID()
    let id1 = TimersUtil.preActivationReminderIdentifier(for: profileId, minutes: 1)
    let id2 = TimersUtil.preActivationReminderIdentifier(for: profileId, minutes: 5)

    XCTAssertNotEqual(id1, id2)
  }

  func testGivenProfile_WhenGeneratingIdentifier_ThenHasCorrectPrefix() {
    let profileId = UUID()
    let identifier = TimersUtil.preActivationReminderIdentifier(for: profileId, minutes: 2)

    XCTAssertTrue(identifier.hasPrefix(TimersUtil.preActivationReminderPrefix))
  }

  func testGivenProfile_WhenGettingAllIdentifiers_ThenReturnsFiveIds() {
    let profileId = UUID()
    let ids = TimersUtil.allPreActivationReminderIdentifiers(for: profileId)

    XCTAssertEqual(ids.count, 5)
    for minutes in TimersUtil.allReminderCleanupRange {
      let expected = "pre-activation-reminder-\(profileId.uuidString)-\(minutes)"
      XCTAssertTrue(ids.contains(expected), "Missing identifier for \(minutes) minutes")
    }
  }

  // MARK: - Profile ID Extraction Tests

  func testGivenValidReminderIdentifier_WhenExtractingProfileId_ThenReturnsCorrectUUID() {
    let profileId = UUID()
    let identifier = TimersUtil.preActivationReminderIdentifier(for: profileId, minutes: 3)

    XCTAssertEqual(TimersUtil.profileIdFromReminderIdentifier(identifier), profileId)
  }

  func testGivenNonReminderIdentifier_WhenExtractingProfileId_ThenReturnsNil() {
    XCTAssertNil(TimersUtil.profileIdFromReminderIdentifier("some-other-notification"))
  }

  func testGivenMalformedIdentifier_WhenExtractingProfileId_ThenReturnsNil() {
    XCTAssertNil(TimersUtil.profileIdFromReminderIdentifier("pre-activation-reminder-not-a-uuid-3"))
  }

  func testGivenProfile_WhenGettingThreadIdentifier_ThenFormatsCorrectly() {
    let profileId = UUID()
    let expected = "pre-activation-reminder-\(profileId.uuidString)"

    XCTAssertEqual(TimersUtil.preActivationReminderThreadIdentifier(for: profileId), expected)
  }

  // MARK: - Model Behavior Tests

  func testGivenReminderTimes_WhenSettingAndGetting_ThenRoundTrips() {
    let profile = BlockedProfiles(name: "Test")
    profile.preActivationReminderTimes = [1, 3, 5]

    XCTAssertEqual(profile.preActivationReminderTimes, [1, 3, 5])
  }

  func testGivenDuplicateUnsortedTimes_WhenSettingReminderTimes_ThenDeduplicatesAndSorts() {
    let profile = BlockedProfiles(name: "Test")
    profile.preActivationReminderTimes = [5, 1, 5, 3]

    XCTAssertEqual(profile.preActivationReminderTimes, [1, 3, 5])
  }

  func testGivenOutOfRangeValues_WhenSettingReminderTimes_ThenFiltersInvalid() {
    let profile = BlockedProfiles(name: "Test")
    profile.preActivationReminderTimes = [0, 1, 2, 3, 4, 5, 6, 255]

    XCTAssertEqual(profile.preActivationReminderTimes, [1, 3, 5])
  }

  func testGivenLegacyPersistedData_WhenGettingReminderTimes_ThenFiltersUnsupported() {
    let profile = BlockedProfiles(name: "Test")
    // Bypass the setter by writing directly to the raw data property,
    // simulating legacy persisted data or unfiltered CloudKit sync
    let legacyValues: [UInt8] = [1, 2, 3, 4, 5]
    profile.preActivationReminderTimesData = try! JSONEncoder().encode(legacyValues)

    // Getter should filter out unsupported values (2, 4)
    XCTAssertEqual(profile.preActivationReminderTimes, [1, 3, 5])
  }

  func testGivenEmptyReminderTimes_WhenCheckingEnabled_ThenReturnsFalse() {
    let profile = BlockedProfiles(name: "Test")
    profile.preActivationReminderTimes = []

    XCTAssertFalse(profile.preActivationReminderEnabled)
  }

  func testGivenNonEmptyReminderTimes_WhenCheckingEnabled_ThenReturnsTrue() {
    let profile = BlockedProfiles(name: "Test")
    profile.preActivationReminderTimes = [3]

    XCTAssertTrue(profile.preActivationReminderEnabled)
  }

  // MARK: - Time Calculation Tests

  func testGivenScheduledStartAndMinutes_WhenCalculatingReminderTime_ThenSubtractsCorrectly() {
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
