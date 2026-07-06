import FoqosShared
import XCTest

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

  func testGivenBackgroundStopsDisabled_WhenStopScheduleFires_ThenSessionSurvives() {
    let id = UUID()
    SharedData.createSessionForScheduler(for: id)
    let snap = snapshot(id: id, disableBackgroundStops: true)

    StopScheduleTimerActivity().stop(for: snap)

    XCTAssertNotNil(
      SharedData.getActiveSharedSession(),
      "disableBackgroundStops must block the scheduled stop (#239)")
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
}
