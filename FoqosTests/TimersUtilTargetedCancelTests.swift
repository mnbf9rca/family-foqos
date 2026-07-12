import XCTest

@testable import FamilyFoqos

final class TimersUtilTargetedCancelTests: XCTestCase {
  func testGivenReminderIdentifiers_WhenClassifying_ThenOnlySessionAndBreakAreOwned() {
    let profileId = UUID()

    XCTAssertTrue(
      TimersUtil.isSessionOrBreakReminder(
        TimersUtil.sessionReminderIdentifier(for: profileId)))
    XCTAssertTrue(
      TimersUtil.isSessionOrBreakReminder(
        TimersUtil.breakReminderIdentifier(for: profileId)))
    XCTAssertFalse(
      TimersUtil.isSessionOrBreakReminder(
        TimersUtil.preActivationReminderIdentifier(for: profileId, minutes: 5)))
  }

  func testGivenSameProfile_WhenBuildingReminderIds_ThenIdentifiersAreStableAndScoped() {
    let profileId = UUID()

    XCTAssertEqual(
      TimersUtil.sessionReminderIdentifier(for: profileId),
      "session-reminder-\(profileId.uuidString)")
    XCTAssertEqual(
      TimersUtil.breakReminderIdentifier(for: profileId),
      "break-reminder-\(profileId.uuidString)")
    XCTAssertEqual(
      TimersUtil.sessionReminderIdentifier(for: profileId),
      TimersUtil.sessionReminderIdentifier(for: profileId))
    XCTAssertNotEqual(
      TimersUtil.sessionReminderIdentifier(for: profileId),
      TimersUtil.sessionReminderIdentifier(for: UUID()))
  }

  func testGivenOwnedReminderScheduled_WhenReadingOwnedIdentifiers_ThenIdentifierIsTrackedAtCallTime() {
    let timers = TimersUtil()
    let identifier = TimersUtil.sessionReminderIdentifier(for: UUID())

    _ = timers.scheduleNotification(
      title: "Session",
      message: "Message",
      seconds: 60,
      identifier: identifier)

    XCTAssertEqual(timers.ownedReminderIdentifiersForTesting, [identifier])

    timers.cancelAllNotifications()

    XCTAssertTrue(timers.ownedReminderIdentifiersForTesting.isEmpty)
  }
}
