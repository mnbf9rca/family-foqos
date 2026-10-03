import DeviceActivity
import FoqosShared
import XCTest

@testable import FamilyFoqos

final class StrategyTimerActivityTests: XCTestCase {
  private var suiteName: String!
  private var defaults: UserDefaults!
  private var lock: String!

  override func setUp() {
    suiteName = "StrategyTimerActivityTests-\(UUID())"
    defaults = UserDefaults(suiteName: suiteName)!
    SharedData.configure(suite: defaults)
    lock = NSTemporaryDirectory() + suiteName + ".lock"
    SharedData.configureLockPath(lock)
  }

  override func tearDown() {
    SharedData.resetLockPath()
    defaults.removePersistentDomain(forName: suiteName)
    try? FileManager.default.removeItem(atPath: lock)
  }

  private func profile(now: Date) -> SharedData.ProfileSnapshot {
    let profile = BlockedProfiles(name: "Timer", createdAt: now, updatedAt: now)
    profile.startTriggers = .init(schedule: true)
    profile.startSchedule = .init(days: Weekday.allCases, hour: 9, minute: 0, updatedAt: .distantPast)
    profile.stopConditions = .init(timer: true, timerDurationMinutes: 37)
    profile.disableBackgroundStops = true
    return BlockedProfiles.getSnapshot(for: profile)
  }

  func testExactSessionExpiryIsIdempotentAndEarlyStartIsInert() throws {
    let now = Date()
    let profile = profile(now: now)
    let applier = TimerRestrictionSpy()
    var cancellations: [String] = []
    let timer = StrategyTimerActivity(applier: applier, cancelTimer: { _, id in cancellations.append(id) })
    var current = SharedData.SessionSnapshot(id: UUID().uuidString, tag: "not-a-profile-id", blockedProfileId: profile.id, startTime: now, timerEndTime: now.addingTimeInterval(2207), breakStartTime: now, forceStarted: true, oneMoreMinuteUsed: true, oneMoreMinuteStartTime: now, origin: .init(kind: .schedule))
    current.oneMoreMinuteDeadline = now.addingTimeInterval(60)
    SharedData.setSnapshot(profile, for: profile.id.uuidString)
    SharedData.createActiveSharedSession(for: current)
    timer.start(for: profile)
    XCTAssertEqual(applier.activations, 0)
    XCTAssertFalse(timer.stop(for: profile, sessionId: current.id, now: now.addingTimeInterval(2206)))
    XCTAssertFalse(timer.stop(for: profile, sessionId: UUID().uuidString, now: now.addingTimeInterval(2207)))
    XCTAssertEqual(SharedData.getActiveSharedSession(), current)
    XCTAssertTrue(timer.stop(for: profile, sessionId: current.id, now: now.addingTimeInterval(2207)))
    XCTAssertFalse(timer.stop(for: profile, sessionId: current.id, now: now.addingTimeInterval(2208)))
    XCTAssertNil(SharedData.getActiveSharedSession())
    XCTAssertEqual(applier.deactivations, 1)
    XCTAssertEqual(cancellations, [current.id])
    let ended = try XCTUnwrap(SharedData.completedSessionsInScheduler.last)
    XCTAssertEqual(ended.id, current.id)
    XCTAssertNil(ended.timerEndTime)
    XCTAssertNil(ended.origin)
    XCTAssertNil(ended.oneMoreMinuteStartTime)
    XCTAssertNil(ended.oneMoreMinuteDeadline)
    XCTAssertNotNil(ended.breakEndTime)
    XCTAssertEqual(SharedData.snapshot(for: profile.id.uuidString)?.scheduleLastStoppedAt, now.addingTimeInterval(2207))
  }

  func testStaleSameProfileAndMalformedActivityNeverEndReplacement() throws {
    let now = Date()
    let profile = profile(now: now)
    let old = UUID().uuidString
    let replacement = SharedData.SessionSnapshot(id: UUID().uuidString, tag: "replacement", blockedProfileId: profile.id, startTime: now, timerEndTime: now.addingTimeInterval(2207), forceStarted: false, origin: .init(kind: .manual))
    SharedData.setSnapshot(profile, for: profile.id.uuidString)
    SharedData.createActiveSharedSession(for: replacement)
    let applier = TimerRestrictionSpy()
    let timer = StrategyTimerActivity(applier: applier)
    XCTAssertFalse(timer.stop(for: profile, sessionId: old, now: now.addingTimeInterval(3000)))
    timer.stop(for: profile)  // A V1 two-part callback cannot end a V2 session.
    for name in ["StrategyTimerActivity:\(profile.id):bad", "unknown:\(profile.id):\(replacement.id)", "StrategyTimerActivity:\(profile.id):\(replacement.id):extra"] {
      XCTAssertNil(StrategyTimerActivity.sessionIdentity(from: .init(name)))
      TimerActivityUtil.stopTimerActivity(for: .init(name))
    }
    XCTAssertEqual(SharedData.getActiveSharedSession(), replacement)
    XCTAssertEqual(applier.deactivations, 0)
    let parsed = try XCTUnwrap(StrategyTimerActivity.sessionIdentity(from: timer.getDeviceActivityName(profileId: profile.id, sessionId: replacement.id)))
    XCTAssertEqual(parsed.profileId, profile.id)
    XCTAssertEqual(parsed.sessionId, replacement.id)
  }

  func testSharedRegistrarValidatesBeforeCallingOSAndKeepsAcceptedPrecision() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 23, minute: 50, second: 42)))
    for invalid in [-1, 0, 14, 1440] {
      XCTAssertThrowsError(try StrategyTimerActivity.timerInterval(minutes: invalid, now: now, calendar: calendar))
    }
    let accepted = try StrategyTimerActivity.timerInterval(minutes: 37, now: now, calendar: calendar)
    XCTAssertEqual(accepted.deadline, calendar.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 0, minute: 27)))
    XCTAssertEqual(accepted.start.hour, 23)
    XCTAssertEqual(accepted.end.minute, 27)
    XCTAssertNoThrow(try StrategyTimerActivity.timerInterval(minutes: 15, now: now, calendar: calendar))
    XCTAssertNoThrow(try StrategyTimerActivity.timerInterval(minutes: 1439, now: now, calendar: calendar))
  }
  func testLegacyTimerStartStillAppliesOnlyForAnActiveV1Session() {
    let now = Date()
    var legacy = profile(now: now)
    legacy.profileSchemaVersion = 1
    let applier = TimerRestrictionSpy()
    let timer = StrategyTimerActivity(applier: applier)
    timer.start(for: legacy)
    XCTAssertEqual(applier.activations, 0)
    let active = SharedData.SessionSnapshot(
      id: UUID().uuidString, tag: "legacy-timer",
      blockedProfileId: legacy.id, startTime: now, forceStarted: false)
    SharedData.createActiveSharedSession(for: active)
    timer.start(for: legacy)
    XCTAssertEqual(applier.activations, 1)
    legacy.profileSchemaVersion = 3
    timer.start(for: legacy)
    XCTAssertEqual(applier.activations, 1)
  }

  func testFullTimerDateComponentsKeepAcceptedDeadlineAcrossSpringForward() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/London"))
    let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2027, month: 3, day: 27, hour: 23, minute: 30)))
    let interval = try StrategyTimerActivity.timerInterval(minutes: 1439, now: now, calendar: calendar)
    XCTAssertEqual(calendar.date(from: interval.start), now)
    XCTAssertEqual(calendar.date(from: interval.end), interval.deadline)
    XCTAssertEqual(interval.deadline.timeIntervalSince(now), 1439 * 60)
  }

  func testScheduleCompletionPreservesUndecodableProfileSnapshots() throws {
    let now = Date()
    let profile = profile(now: now)
    let bytes = Data("corrupt-profile-snapshots".utf8)
    defaults.set(bytes, forKey: "family_foqos_profile_snapshots")
    let active = SharedData.SessionSnapshot(
      id: UUID().uuidString, tag: "schedule",
      blockedProfileId: profile.id, startTime: now, timerEndTime: now, forceStarted: true,
      origin: .init(kind: .schedule))
    SharedData.createActiveSharedSession(for: active)
    XCTAssertTrue(StrategyTimerActivity().stop(for: profile, sessionId: active.id, now: now))
    XCTAssertEqual(defaults.data(forKey: "family_foqos_profile_snapshots"), bytes)
  }

}

private final class TimerRestrictionSpy: RestrictionApplying {
  var activations = 0
  var deactivations = 0
  func activateRestrictions(for profile: SharedData.ProfileSnapshot) { activations += 1 }
  func deactivateRestrictions() { deactivations += 1 }
  func deactivateRestrictions(keepingSafeguardsFor profile: SharedData.ProfileSnapshot?) { deactivations += 1 }
}
