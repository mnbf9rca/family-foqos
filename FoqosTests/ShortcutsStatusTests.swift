import AppIntents
import FoqosShared
import XCTest

@testable import FamilyFoqos

@MainActor
final class ShortcutsStatusTests: XCTestCase {
  func testUnlockPreferenceDefaultsAndBothMutationPolicies() {
    let suite = "ShortcutsStatusTests-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    XCTAssertTrue(ShortcutsSettings.requiresDeviceUnlock(defaults: defaults))
    for value in [false, true] {
      defaults.set(value, forKey: ShortcutsSettings.requireDeviceUnlockKey)
      XCTAssertEqual(ShortcutsSettings.requiresDeviceUnlock(defaults: defaults), value)
    }
    XCTAssertEqual(StartProfileIntent.authenticationPolicy, StopProfileIntent.authenticationPolicy)
    XCTAssertEqual(CheckSessionActiveIntent.authenticationPolicy, .alwaysAllowed)
    XCTAssertEqual(CheckProfileStatusIntent.authenticationPolicy, .alwaysAllowed)
  }

  func testShortcutOnlyEntranceStillDirectsUserToShortcut() {
    XCTAssertEqual(StartStopActionResolver.determineStartAction(for: ProfileStartTriggers(shortcuts: true)), .cannotStart(reason: "Start this profile with Siri or Shortcuts."))
  }

  func testStatusTruthGrantTimingAndNoDurationGuess() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let profile = BlockedProfiles(name: "Focus")
    profile.strategyData = StrategyTimerData.toData(from: StrategyTimerData(durationInMinutes: 300))
    let session = BlockedProfileSession(tag: "timer", blockedProfile: profile, startTime: now.addingTimeInterval(-60))
    let answer: (TimeInterval?) -> (isActive: Bool, dialog: String) = {
      ShortcutStatus.answer(session: session, asked: nil, grantRemaining: $0, now: now)
    }
    XCTAssertEqual(answer(nil).dialog, "Focus is active, with no end time available.")
    XCTAssertTrue(answer(nil).isActive)
    session.timerEndTime = now.addingTimeInterval(720)
    XCTAssertEqual(answer(nil).dialog, "Focus is active, with 12 minutes left on its timer.")
    session.breakStartTime = now.addingTimeInterval(-60)
    XCTAssertEqual(answer(120).dialog, "Focus is active, with 2 minutes left in its break and 12 minutes left on its timer.")
    XCTAssertFalse(answer(0).dialog.contains("break"))
    session.breakEndTime = now
    session.oneMoreMinuteStartTime = now.addingTimeInterval(-10)
    XCTAssertTrue(answer(50).dialog.contains("less than a minute left in its one-more-minute grant"))
    session.timerEndTime = now.addingTimeInterval(-1)
    XCTAssertTrue(answer(50).isActive)
    XCTAssertTrue(answer(50).dialog.contains("timer time has elapsed"))
    let other = BlockedProfiles(name: "Study")
    let askedOther = ShortcutStatus.answer(session: session, asked: other, grantRemaining: 0, now: now)
    XCTAssertFalse(askedOther.isActive)
    XCTAssertTrue(askedOther.dialog.hasPrefix("Study is not active; Focus is"))
    let inactive = ShortcutStatus.answer(session: nil, asked: nil, grantRemaining: nil, now: now)
    XCTAssertFalse(inactive.isActive)
    XCTAssertEqual(inactive.dialog, "No session is active.")
  }

  func testShortcutStatusShowsConfiguredScheduleWithOldTrueFlag() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 10, hour: 12))!
    let profile = BlockedProfiles(name: "Focus")
    profile.stopConditions = ProfileStopConditions(schedule: true)
    profile.stopSchedule = ProfileScheduleTime(days: Weekday.allCases, hour: 17, minute: 0, updatedAt: now)
    let session = BlockedProfileSession(tag: "test", blockedProfile: profile, startTime: now)
    let answer = ShortcutStatus.answer(session: session, asked: nil, grantRemaining: nil, now: now, calendar: calendar)
    XCTAssertTrue(answer.dialog.contains("next scheduled stop today at"))
    profile.disableBackgroundStops = true
    XCTAssertEqual(ShortcutStatus.answer(session: session, asked: nil, grantRemaining: nil, now: now, calendar: calendar).dialog, answer.dialog)
    profile.startTriggers = ProfileStartTriggers(schedule: true)
    profile.startSchedule = ProfileScheduleTime(days: Weekday.allCases, hour: 9, minute: 0, updatedAt: now)
    let nextStart = ShortcutStatus.answer(session: nil, asked: profile, grantRemaining: nil, now: now, calendar: calendar)
    XCTAssertTrue(nextStart.dialog.contains("next scheduled to start"))
    XCTAssertFalse(nextStart.dialog.contains("today"))
    profile.startTriggers.schedule = false
    XCTAssertTrue(ShortcutStatus.answer(session: nil, asked: profile, grantRemaining: nil, now: now).dialog.contains("no scheduled start"))
  }

  func testDeletedAskedProfileThrowsInsteadOfInactiveAnswer() throws {
    let container = try TestModelContainer.create()
    XCTAssertThrowsError(try ShortcutStatus.read(manager: StrategyManager(), context: container.mainContext, askedProfileId: UUID()))
  }
}
