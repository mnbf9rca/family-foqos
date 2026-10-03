import DeviceActivity
import FoqosShared
import XCTest

private final class ReloadSpy: @unchecked Sendable {
  private(set) var count = 0

  func fire() {
    count += 1
  }
}

final class ScheduleTimerActivityTests: XCTestCase {
  private var suiteName: String!

  override func setUp() {
    super.setUp()
    suiteName = "ScheduleTimerActivityTests-\(UUID().uuidString)"
    SharedData.configure(suite: UserDefaults(suiteName: suiteName)!)
  }

  override func tearDown() {
    UserDefaults().removePersistentDomain(forName: suiteName)
    super.tearDown()
  }

  private func snapshot(
    id: UUID,
    disableBackgroundStops: Bool = false,
    stopConditions: ProfileStopConditions = ProfileStopConditions(schedule: true),
    stopSchedule: ProfileScheduleTime? = ProfileScheduleTime(
      days: Weekday.allCases, hour: 17, minute: 0, updatedAt: .distantPast)
  ) -> SharedData.ProfileSnapshot {
    SharedData.ProfileSnapshot(
      id: id, name: "P", selectedActivity: .init(), createdAt: .distantPast,
      updatedAt: .distantPast, order: 0, enableLiveActivity: false, enableBreaks: false,
      enableStrictMode: false, enableAllowMode: false, enableAllowModeDomains: false,
      enableSafariBlocking: false, stopSchedule: stopSchedule,
      disableBackgroundStops: disableBackgroundStops, stopConditions: stopConditions)
  }

  private func startScheduledSnapshot(
    id: UUID,
    stopConditions: ProfileStopConditions,
    stopSchedule: ProfileScheduleTime? = nil
  ) -> SharedData.ProfileSnapshot {
    SharedData.ProfileSnapshot(
      id: id, name: "P", selectedActivity: .init(), createdAt: .distantPast,
      updatedAt: .distantPast, order: 0, enableLiveActivity: false, enableBreaks: false,
      enableStrictMode: false, enableAllowMode: false, enableAllowModeDomains: false,
      enableSafariBlocking: false, stopSchedule: stopSchedule,
      disableBackgroundStops: false, stopConditions: stopConditions)
  }

  func testGivenPendingSelection_WhenScheduledStartFires_ThenNoSessionStarts() {
    var snap = snapshot(id: UUID())
    snap.schedule = BlockedProfileSchedule(
      days: Weekday.allCases, startHour: 9, startMinute: 0, endHour: 17, endMinute: 0,
      updatedAt: .distantPast)
    snap.needsAppSelection = true

    ScheduleTimerActivity().start(for: snap)

    XCTAssertNil(SharedData.getActiveSharedSession())
  }

  func testOldTrueFlagDoesNotVetoEitherConfiguredScheduleAdapter() {
    let now = Date()
    for stopOnly in [false, true] {
      for oldFlag in [false, true] {
        var snap = snapshot(id: UUID(), disableBackgroundStops: oldFlag)
        snap.profileSchemaVersion = 3
        SharedData.createActiveSharedSession(
          for: .init(
            id: UUID().uuidString, tag: "manual", blockedProfileId: snap.id,
            startTime: now, forceStarted: false, origin: .init(kind: .manual)))
        if stopOnly { StopScheduleTimerActivity().stop(for: snap) } else { ScheduleTimerActivity().stop(for: snap) }
        XCTAssertNil(SharedData.getActiveSharedSession(), "A configured V2 schedule ignores the retained flag")
      }
    }
  }

  func testGenuineV1VetoPreservedForBothScheduleAdapters() {
    let now = Date()
    for version: Int? in [nil, 1] {
      for stopOnly in [false, true] {
        var snap = snapshot(id: UUID(), disableBackgroundStops: true)
        snap.profileSchemaVersion = version
        let session = SharedData.SessionSnapshot(
          id: UUID().uuidString, tag: "legacy", blockedProfileId: snap.id,
          startTime: now, forceStarted: false)
        SharedData.createActiveSharedSession(for: session)
        if stopOnly { StopScheduleTimerActivity().stop(for: snap) } else { ScheduleTimerActivity().stop(for: snap) }
        XCTAssertEqual(SharedData.getActiveSharedSession(), session)
      }
    }
  }

  func testGivenScheduleStopEnabled_WhenStopScheduleFires_ThenSessionEnds() {
    let id = UUID()
    SharedData.createSessionForScheduler(for: id)
    let snap = snapshot(id: id, disableBackgroundStops: false)

    StopScheduleTimerActivity().stop(for: snap)

    XCTAssertNil(SharedData.getActiveSharedSession(), "scheduled stop ends the session normally")
  }

  func testGivenDifferentProfileSession_WhenStopScheduleFires_ThenNoOp() {
    SharedData.createSessionForScheduler(for: UUID())
    let snap = snapshot(id: UUID())

    StopScheduleTimerActivity().stop(for: snap)

    XCTAssertNotNil(SharedData.getActiveSharedSession(), "unrelated session untouched")
  }

  func testGivenManualOnlyStopProfile_WhenScheduleStopFires_ThenSessionSurvives() {
    let id = UUID()
    SharedData.createActiveSharedSession(
      for: SharedData.SessionSnapshot(
        id: UUID().uuidString, tag: "manual", blockedProfileId: id,
        startTime: .distantPast, forceStarted: false))
    let snap = startScheduledSnapshot(id: id, stopConditions: ProfileStopConditions(manual: true))

    ScheduleTimerActivity().stop(for: snap)

    XCTAssertNotNil(
      SharedData.getActiveSharedSession(),
      "manual-only-stop profile must not be ended by the synthetic schedule interval (#206)")
  }

  func testGivenScheduleStopProfileToday_WhenScheduleStopFires_ThenSessionEnds() {
    let id = UUID()
    SharedData.createSessionForScheduler(for: id)
    let everyDayStop = ProfileScheduleTime(
      days: Weekday.allCases, hour: 17, minute: 0, updatedAt: .distantPast)
    let snap = startScheduledSnapshot(
      id: id, stopConditions: ProfileStopConditions(schedule: true), stopSchedule: everyDayStop)

    ScheduleTimerActivity().stop(for: snap)

    XCTAssertNil(SharedData.getActiveSharedSession(), "schedule-stop profile ends on its interval")
  }

  func testGivenProtectedVictim_WhenScheduledStartTakesOver_ThenVictimSurvives() throws {
    let victimId = UUID()
    SharedData.createActiveSharedSession(
      for: SharedData.SessionSnapshot(
        id: UUID().uuidString, tag: "nfc:abc", blockedProfileId: victimId,
        startTime: .distantPast, forceStarted: false))
    SharedData.setSnapshot(
      startScheduledSnapshot(id: victimId, stopConditions: ProfileStopConditions(anyNFC: true)),
      for: victimId.uuidString)

    let incomingId = UUID()
    let now = Date()
    let components = Calendar.current.dateComponents([.hour, .minute], from: now)
    let startNow = ProfileScheduleTime(
      days: Weekday.allCases, hour: components.hour!, minute: components.minute!,
      updatedAt: .distantPast)
    var incoming = startScheduledSnapshot(
      id: incomingId, stopConditions: ProfileStopConditions(schedule: true))
    incoming.startSchedule = startNow
    incoming.startTriggersSchedule = true

    ScheduleTimerActivity().start(for: incoming)

    XCTAssertEqual(
      SharedData.getActiveSharedSession()?.blockedProfileId, victimId,
      "the protected victim session must survive; the scheduled takeover is skipped (#236)")
  }

  func testScheduledTakeoverIgnoresOnlyV2VictimsOldFlag() {
    let now = Date()
    for version in [1, 3] {
      var victim = snapshot(id: UUID(), disableBackgroundStops: true, stopConditions: .init(manual: true))
      victim.profileSchemaVersion = version
      SharedData.setSnapshot(victim, for: victim.id.uuidString)
      let original = SharedData.SessionSnapshot(
        id: UUID().uuidString, tag: "manual",
        blockedProfileId: victim.id, startTime: now, forceStarted: false)
      SharedData.createActiveSharedSession(for: original)
      var incoming = startScheduledSnapshot(id: UUID(), stopConditions: .init(manual: true))
      incoming.profileSchemaVersion = 3
      incoming.settingsReadable = true
      incoming.startTriggers = .init(schedule: true)
      incoming.startTriggersSchedule = true
      incoming.startSchedule = .init(days: Weekday.allCases, hour: 0, minute: 0, updatedAt: .distantPast)
      SharedData.setSnapshot(incoming, for: incoming.id.uuidString)
      ScheduleTimerActivity(cancelReminders: { _ in }).start(for: incoming)
      XCTAssertEqual(SharedData.getActiveSharedSession()?.blockedProfileId, version == 1 ? victim.id : incoming.id)
    }
  }

  func testGivenSameProfileName_WhenBuildingSkippedStartNotificationIds_ThenIdsUseProfileUUID() {
    let firstProfileId = UUID()
    let secondProfileId = UUID()

    let firstIdentifier = ScheduleTimerActivity.skippedStartNotificationIdentifier(
      for: firstProfileId)
    let secondIdentifier = ScheduleTimerActivity.skippedStartNotificationIdentifier(
      for: secondProfileId)

    XCTAssertEqual(firstIdentifier, "scheduled-start-skipped-\(firstProfileId.uuidString)")
    XCTAssertEqual(secondIdentifier, "scheduled-start-skipped-\(secondProfileId.uuidString)")
    XCTAssertNotEqual(
      firstIdentifier,
      secondIdentifier,
      "profiles with the same display name must not replace each other's skipped-start notices")
  }

  func testGivenLegacySchedule_WhenComputingWindowStart_ThenTodayAtStartTime() {
    let cal = Calendar(identifier: .gregorian)
    var components = DateComponents()
    components.year = 2026
    components.month = 6
    components.day = 15
    components.hour = 12
    components.minute = 0
    let now = cal.date(from: components)!
    let schedule = BlockedProfileSchedule(
      days: Weekday.allCases, startHour: 9, startMinute: 0, endHour: 17, endMinute: 0,
      updatedAt: .distantPast)

    let windowStart = schedule.windowStart(on: now, calendar: cal)

    var expected = DateComponents()
    expected.year = 2026
    expected.month = 6
    expected.day = 15
    expected.hour = 9
    expected.minute = 0
    XCTAssertEqual(windowStart, cal.date(from: expected))
  }

  func testGivenLegacyStoppedThisWindow_WhenStartFires_ThenSuppressed() {
    let id = UUID()
    let cal = Calendar.current
    let now = Date()
    var components = cal.dateComponents([.year, .month, .day], from: now)
    components.hour = 10
    components.minute = 5
    let stoppedAt = cal.date(from: components)!
    var snap = SharedData.ProfileSnapshot(
      id: id, name: "Legacy", selectedActivity: .init(), createdAt: .distantPast,
      updatedAt: .distantPast, order: 0, enableLiveActivity: false, enableBreaks: false,
      enableStrictMode: false, enableAllowMode: false, enableAllowModeDomains: false,
      enableSafariBlocking: false,
      schedule: BlockedProfileSchedule(
        days: Weekday.allCases, startHour: 9, startMinute: 0, endHour: 17, endMinute: 0,
        updatedAt: .distantPast),
      disableBackgroundStops: false, stopConditions: ProfileStopConditions(manual: true),
      scheduleLastStoppedAt: stoppedAt)
    snap.startTriggersSchedule = false

    ScheduleTimerActivity().start(for: snap)

    XCTAssertNil(
      SharedData.getActiveSharedSession(),
      "legacy branch must suppress a window already stopped this window (#229)")
  }

  func testGivenStartFunnelWithNoSnapshot_WhenInvoked_ThenWidgetReloadFiredOnce() {
    let original = TimerActivityUtil.reloadWidgets
    defer { TimerActivityUtil.reloadWidgets = original }
    let spy = ReloadSpy()
    TimerActivityUtil.reloadWidgets = { spy.fire() }

    let activity = DeviceActivityName(
      rawValue: "\(ScheduleTimerActivity.id):\(UUID().uuidString)")
    TimerActivityUtil.startTimerActivity(for: activity)

    XCTAssertEqual(
      spy.count,
      1,
      "each start funnel must request exactly one widget reload (#238)"
    )
  }

  func testGivenStopFunnelWithNoSnapshot_WhenInvoked_ThenWidgetReloadFiredOnce() {
    let original = TimerActivityUtil.reloadWidgets
    defer { TimerActivityUtil.reloadWidgets = original }
    let spy = ReloadSpy()
    TimerActivityUtil.reloadWidgets = { spy.fire() }

    let activity = DeviceActivityName(
      rawValue: "\(ScheduleTimerActivity.id):\(UUID().uuidString)")
    TimerActivityUtil.stopTimerActivity(for: activity)

    XCTAssertEqual(spy.count, 1)
  }
  func testPreUpdateV1SnapshotSurvivesBeforeFirstAppLaunch() throws {
    let now = Date()
    var old = snapshot(id: UUID())
    old.schedule = BlockedProfileSchedule(
      days: Weekday.allCases, startHour: 0, startMinute: 0, endHour: 23, endMinute: 59,
      updatedAt: now.addingTimeInterval(-3600))
    let data = try JSONEncoder().encode(old)
    let decoded = try JSONDecoder().decode(SharedData.ProfileSnapshot.self, from: data)
    XCTAssertNil(decoded.profileSchemaVersion)
    XCTAssertNil(decoded.startTriggers)
    XCTAssertNil(decoded.settingsReadable)
    ScheduleTimerActivity().start(for: decoded)
    XCTAssertEqual(SharedData.getActiveSharedSession()?.blockedProfileId, old.id)
  }

  func testMonitorSavedTimerAndFailureLeaveVictimUntouched() throws {
    let now = Date()
    var incoming = startScheduledSnapshot(id: UUID(), stopConditions: .init(manual: true, timer: true, timerDurationMinutes: 37, allowChangingTimerBeforeStart: true))
    incoming.profileSchemaVersion = 3
    incoming.settingsReadable = true
    incoming.startTriggers = .init(schedule: true)
    incoming.startTriggersSchedule = true
    incoming.startSchedule = .init(days: Weekday.allCases, hour: 0, minute: 0, updatedAt: .distantPast)
    SharedData.setSnapshot(incoming, for: incoming.id.uuidString)
    let victimProfile = snapshot(id: UUID(), stopConditions: .init(manual: true))
    SharedData.setSnapshot(victimProfile, for: victimProfile.id.uuidString)
    let victim = SharedData.SessionSnapshot(id: UUID().uuidString, tag: "victim", blockedProfileId: victimProfile.id, startTime: now, forceStarted: false, origin: .init(kind: .manual))
    SharedData.createActiveSharedSession(for: victim)
    var registrations = 0
    var cancellations = 0
    var reminders = 0
    let accepted = now.addingTimeInterval(2207)
    let failed = ScheduleTimerActivity(
      registerTimer: { _, _, minutes, _ in
        registrations += 1
        XCTAssertEqual(minutes, 37)
        XCTAssertEqual(SharedData.getActiveSharedSession(), victim)
        throw NSError(domain: "registration", code: 1)
      }, cancelTimer: { _, _ in cancellations += 1 }, cancelReminders: { _ in reminders += 1 })
    failed.start(for: incoming)
    XCTAssertEqual(registrations, 1)
    XCTAssertEqual(cancellations, 1)
    XCTAssertEqual(reminders, 0)
    XCTAssertEqual(SharedData.getActiveSharedSession(), victim)
    let started = ScheduleTimerActivity(
      registerTimer: { _, _, minutes, _ in
        registrations += 1
        XCTAssertEqual(minutes, 37)
        return accepted
      }, cancelTimer: { _, _ in cancellations += 1 }, cancelReminders: { _ in reminders += 1 })
    started.start(for: incoming)
    XCTAssertEqual(registrations, 2)
    XCTAssertEqual(reminders, 1)
    XCTAssertEqual(SharedData.getActiveSharedSession()?.origin?.kind, .schedule)
    XCTAssertEqual(SharedData.getActiveSharedSession()?.timerEndTime, accepted)
    XCTAssertEqual(SharedData.completedSessionsInScheduler.last?.id, victim.id)
  }

  func testRawCreatorCannotPublishV2AndMalformedMonitorHasNoEffects() {
    var incoming = startScheduledSnapshot(id: UUID(), stopConditions: .init(manual: true, timer: true, timerDurationMinutes: 14))
    incoming.profileSchemaVersion = 3
    incoming.settingsReadable = true
    incoming.startTriggers = .init(schedule: true)
    incoming.startTriggersSchedule = true
    incoming.startSchedule = .init(days: Weekday.allCases, hour: 0, minute: 0, updatedAt: .distantPast)
    SharedData.setSnapshot(incoming, for: incoming.id.uuidString)
    SharedData.createSessionForScheduler(for: incoming.id)
    XCTAssertNil(SharedData.getActiveSharedSession())
    XCTAssertFalse(SharedData.startSchedulerSessionTakingOver(profileId: incoming.id, expectedVictimId: nil))
    var registrations = 0
    var reminders = 0
    ScheduleTimerActivity(
      registerTimer: { _, _, _, now in
        registrations += 1
        return now
      }, cancelReminders: { _ in reminders += 1 }
    ).start(for: incoming)
    XCTAssertEqual(registrations, 0)
    XCTAssertEqual(reminders, 0)
    XCTAssertNil(SharedData.getActiveSharedSession())
  }

}
