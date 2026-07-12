import XCTest

@testable import FamilyFoqos

final class TimersUtilTargetedCancelTests: XCTestCase {
  override func setUp() {
    UserDefaults.standard.removeObject(forKey: TimersUtil.ownedReminderIdentifiersUserDefaultsKey)
    super.setUp()
  }

  override func tearDown() {
    UserDefaults.standard.removeObject(forKey: TimersUtil.ownedReminderIdentifiersUserDefaultsKey)
    super.tearDown()
  }

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

  func testGivenOwnedReminderScheduled_WhenTimersUtilIsRecreated_ThenOwnershipIsDurable() {
    let identifier = TimersUtil.breakReminderIdentifier(for: UUID())
    let firstTimers = TimersUtil()

    _ = firstTimers.scheduleNotification(
      title: "Break",
      message: "Message",
      seconds: 60,
      identifier: identifier)

    let recreatedTimers = TimersUtil()

    XCTAssertEqual(recreatedTimers.ownedReminderIdentifiersForTesting, [identifier])

    recreatedTimers.cancelAllNotifications()

    XCTAssertTrue(firstTimers.ownedReminderIdentifiersForTesting.isEmpty)
  }

  func testGivenOwnedReminderScheduleGeneration_WhenCancelled_ThenGenerationIsInvalidated() {
    let timers = TimersUtil()
    let identifier = TimersUtil.sessionReminderIdentifier(for: UUID())

    _ = timers.scheduleNotification(
      title: "Session",
      message: "Message",
      seconds: 60,
      identifier: identifier)
    let generation = try! XCTUnwrap(timers.ownedReminderScheduleGenerationForTesting(identifier))

    XCTAssertTrue(
      timers.isOwnedReminderScheduleCurrentForTesting(identifier, generation: generation))

    timers.cancelAllNotifications()

    XCTAssertFalse(
      timers.isOwnedReminderScheduleCurrentForTesting(identifier, generation: generation))
  }

  func testGivenOwnedReminderAddCompletesAfterCancel_WhenCheckingStaleGeneration_ThenRequestsRemoval() {
    let timers = TimersUtil()
    let identifier = TimersUtil.sessionReminderIdentifier(for: UUID())

    _ = timers.scheduleNotification(
      title: "Session",
      message: "Message",
      seconds: 60,
      identifier: identifier)
    let generation = try! XCTUnwrap(timers.ownedReminderScheduleGenerationForTesting(identifier))

    timers.cancelAllNotifications()

    XCTAssertTrue(
      timers.shouldRemoveStaleOwnedReminderForTesting(identifier, generation: generation),
      "A stale completion after cancellation must remove the request that may have just been added")
  }

  func testGivenOlderOwnedReminderAddCompletesAfterNewerSchedule_WhenCheckingStaleGeneration_ThenKeepsNewerReminder() {
    let timers = TimersUtil()
    let identifier = TimersUtil.sessionReminderIdentifier(for: UUID())

    _ = timers.scheduleNotification(
      title: "Old Session",
      message: "Message",
      seconds: 60,
      identifier: identifier)
    let oldGeneration = try! XCTUnwrap(
      timers.ownedReminderScheduleGenerationForTesting(identifier))

    _ = timers.scheduleNotification(
      title: "New Session",
      message: "Message",
      seconds: 120,
      identifier: identifier)

    XCTAssertFalse(
      timers.shouldRemoveStaleOwnedReminderForTesting(identifier, generation: oldGeneration),
      "A stale completion from an older schedule must not remove the newer owned reminder")
  }
}
