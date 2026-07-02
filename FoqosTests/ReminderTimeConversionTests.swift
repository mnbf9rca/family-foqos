import XCTest

@testable import FamilyFoqos

/// Regression tests for issue #234: the reminder-minutes field is free-form Int
/// input; converting it to UInt32 seconds must clamp instead of trapping on
/// large or negative values.
@MainActor
final class ReminderTimeConversionTests: XCTestCase {

  func testGivenReminderDisabled_WhenComputingSeconds_ThenReturnsNil() {
    XCTAssertNil(BlockedProfileView.reminderTimeSeconds(enabled: false, minutes: 15))
  }

  func testGivenTypicalMinutes_WhenComputingSeconds_ThenReturnsMinutesTimesSixty() {
    XCTAssertEqual(BlockedProfileView.reminderTimeSeconds(enabled: true, minutes: 15), 900)
  }

  func testGivenNineDigitMinutes_WhenComputingSeconds_ThenClampsInsteadOfTrapping() {
    // 100,000,000 minutes * 60 overflows UInt32 — must clamp, not crash (#234)
    XCTAssertEqual(
      BlockedProfileView.reminderTimeSeconds(enabled: true, minutes: 100_000_000),
      UInt32(BlockedProfileView.maxReminderTimeInMinutes * 60)
    )
  }

  func testGivenNegativeMinutes_WhenComputingSeconds_ThenClampsToZero() {
    XCTAssertEqual(BlockedProfileView.reminderTimeSeconds(enabled: true, minutes: -15), 0)
  }

  func testGivenMaximumAllowedMinutes_WhenComputingSeconds_ThenReturnsExactSeconds() {
    XCTAssertEqual(
      BlockedProfileView.reminderTimeSeconds(
        enabled: true, minutes: BlockedProfileView.maxReminderTimeInMinutes),
      UInt32(BlockedProfileView.maxReminderTimeInMinutes * 60)
    )
  }

  func testGivenPreviouslyValidLargeMinutes_WhenComputingSeconds_ThenValuePreservedUnclamped() {
    // A weekly reminder (10080 min) was valid before the clamp existed and must
    // survive an edit-and-save round trip unchanged
    XCTAssertEqual(
      BlockedProfileView.reminderTimeSeconds(enabled: true, minutes: 10_080), 604_800)
  }

  func testGivenMaxBound_WhenConvertedToSeconds_ThenFitsUInt32() {
    // The clamp bound itself must never trap
    XCTAssertNotNil(
      UInt32(exactly: BlockedProfileView.maxReminderTimeInMinutes * 60),
      "maxReminderTimeInMinutes * 60 must fit in UInt32"
    )
  }
}
