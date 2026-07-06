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
}
