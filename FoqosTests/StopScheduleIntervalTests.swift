import DeviceActivity
import FoqosShared
import XCTest

@testable import FamilyFoqos

@MainActor
final class StopScheduleIntervalTests: XCTestCase {

  func testGivenStopBeforeMidnightPlus15_WhenComputingInterval_ThenWindowIsHonorable() {
    let (start, end) = DeviceActivityCenterUtil.stopScheduleInterval(stopHour: 0, stopMinute: 10)
    // Anchor moves to 00:11 so the wrap window is ~1439 min, still ending at 00:10.
    XCTAssertEqual(end.hour, 0)
    XCTAssertEqual(end.minute, 10)
    XCTAssertEqual(start.hour, 0)
    XCTAssertEqual(start.minute, 11)
    XCTAssertFalse(start.hour == end.hour && start.minute == end.minute)
  }

  func testGivenStopAtExactlyMidnight_WhenComputingInterval_ThenNotZeroLength() {
    let (start, end) = DeviceActivityCenterUtil.stopScheduleInterval(stopHour: 0, stopMinute: 0)
    XCTAssertEqual(end.hour, 0)
    XCTAssertEqual(end.minute, 0)
    XCTAssertEqual(start.hour, 0)
    XCTAssertEqual(start.minute, 1)
    XCTAssertFalse(start.hour == end.hour && start.minute == end.minute)
  }

  func testGivenStopAt0015_WhenComputingInterval_ThenKeepsMidnightAnchor() {
    let (start, end) = DeviceActivityCenterUtil.stopScheduleInterval(stopHour: 0, stopMinute: 15)
    XCTAssertEqual(start.hour, 0)
    XCTAssertEqual(start.minute, 0)
    XCTAssertEqual(end.hour, 0)
    XCTAssertEqual(end.minute, 15)
  }

  func testGivenStopMidMorning_WhenComputingInterval_ThenKeepsMidnightAnchor() {
    let (start, end) = DeviceActivityCenterUtil.stopScheduleInterval(stopHour: 9, stopMinute: 0)
    XCTAssertEqual(start.hour, 0)
    XCTAssertEqual(start.minute, 0)
    XCTAssertEqual(end.hour, 9)
    XCTAssertEqual(end.minute, 0)
  }
  private func profile(now: Date) -> BlockedProfiles {
    let profile = BlockedProfiles(name: "Independent", createdAt: now, updatedAt: now)
    profile.startTriggers = .init(schedule: true)
    profile.stopConditions = .init(manual: true, schedule: true)
    profile.startSchedule = .init(days: [.monday], hour: 9, minute: 0, updatedAt: now)
    profile.stopSchedule = .init(days: [.friday], hour: 17, minute: 0, updatedAt: now)
    return profile
  }

  func testBothEventsRegisteredDespiteStartFailure() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let suiteName = "IndependentRegistration-\(UUID())"
    let defaults = UserDefaults(suiteName: suiteName)!
    SharedData.configure(suite: defaults)
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let profile = profile(now: now)
    let start = DeviceActivityName(profile.id.uuidString)
    let stop = StopScheduleTimerActivity().getDeviceActivityName(from: profile.id.uuidString)
    var attempted: [DeviceActivityName] = []
    var published = false
    let failures = DeviceActivityCenterUtil.scheduleTimerActivity(
      for: profile, now: now, scheduleFor: { _ in nil },
      startMonitoring: { name, schedule in
        attempted.append(name)
        if name == start {
          XCTAssertTrue(published, "Publish the local cutoff before asking the OS to monitor")
          XCTAssertEqual(schedule.intervalStart.hour, 9)
          XCTAssertEqual(schedule.intervalStart.minute, 0)
          XCTAssertEqual(schedule.intervalEnd.hour, 8)
          XCTAssertEqual(schedule.intervalEnd.minute, 59)
          throw NSError(domain: "test-start", code: 1)
        }
        XCTAssertEqual(schedule.intervalEnd.hour, 17)
        XCTAssertEqual(schedule.intervalEnd.minute, 0)
      }, stopMonitoring: { _ in },
      publishStartCutoff: { id, cutoff in
        XCTAssertEqual(id, profile.id)
        XCTAssertEqual(cutoff, now)
        published = true
        return true
      })
    XCTAssertEqual(attempted, [start, stop])
    XCTAssertEqual(failures.count, 1)
  }

  func testRefreshAndSessionEndDoNotRestartUnchangedSchedule() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let suiteName = "StableRegistration-\(UUID())"
    let defaults = UserDefaults(suiteName: suiteName)!
    SharedData.configure(suite: defaults)
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let profile = profile(now: now)
    let start = DeviceActivityName(profile.id.uuidString)
    let stop = StopScheduleTimerActivity().getDeviceActivityName(from: profile.id.uuidString)
    var normalizedStart = DateComponents(hour: 9, minute: 0)
    normalizedStart.calendar = .current
    normalizedStart.timeZone = .current
    let inventory = [
      start: DeviceActivitySchedule(intervalStart: normalizedStart, intervalEnd: .init(hour: 8, minute: 59), repeats: true),
      stop: DeviceActivitySchedule(intervalStart: .init(hour: 0, minute: 0), intervalEnd: .init(hour: 17, minute: 0), repeats: true),
    ]
    XCTAssertTrue(SharedData.setStartRegistrationNotBefore(now.addingTimeInterval(-3600), for: profile.id))
    for _ in 0..<2 {
      XCTAssertTrue(
        DeviceActivityCenterUtil.scheduleTimerActivity(
          for: profile, now: now, scheduleFor: { inventory[$0] },
          startMonitoring: { _, _ in XCTFail("Unchanged schedules must remain monitored") },
          stopMonitoring: { _ in XCTFail("Unchanged schedules must not be stopped") },
          publishStartCutoff: { _, _ in
            XCTFail("Refresh must not move the cutoff")
            return false
          }
        ).isEmpty)
    }
    XCTAssertEqual(SharedData.startRegistrationNotBefore(for: profile.id), now.addingTimeInterval(-3600))
    XCTAssertNil(SharedData.getActiveSharedSession())
  }

  func testMissingOrChangedRegistrationPublishesCutoffAndFailedPublicationPreservesStop() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let suiteName = "ChangedRegistration-\(UUID())"
    let defaults = UserDefaults(suiteName: suiteName)!
    SharedData.configure(suite: defaults)
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let profile = profile(now: now)
    let start = DeviceActivityName(profile.id.uuidString)
    let stop = StopScheduleTimerActivity().getDeviceActivityName(from: profile.id.uuidString)
    var inventory: [DeviceActivityName: DeviceActivitySchedule] = [:]
    var attempts: [DeviceActivityName] = []
    let monitor: (DeviceActivityName, DeviceActivitySchedule) -> Void = { name, schedule in
      attempts.append(name)
      if name == start { XCTAssertEqual(SharedData.startRegistrationNotBefore(for: profile.id), now) }
      inventory[name] = schedule
    }
    XCTAssertTrue(
      DeviceActivityCenterUtil.scheduleTimerActivity(
        for: profile, now: now, scheduleFor: { inventory[$0] },
        startMonitoring: monitor, stopMonitoring: { names in for name in names { inventory.removeValue(forKey: name) } }
      ).isEmpty)
    XCTAssertEqual(attempts, [start, stop])
    profile.startSchedule?.minute = 1
    attempts = []
    XCTAssertFalse(
      DeviceActivityCenterUtil.scheduleTimerActivity(
        for: profile, now: now, scheduleFor: { inventory[$0] }, startMonitoring: monitor,
        stopMonitoring: { _ in XCTFail("Do not replace monitoring after a failed cutoff write") },
        publishStartCutoff: { _, _ in false }
      ).isEmpty)
    XCTAssertTrue(attempts.isEmpty, "The unchanged independent stop stays monitored")
    inventory.removeValue(forKey: stop)
    XCTAssertFalse(
      DeviceActivityCenterUtil.scheduleTimerActivity(
        for: profile, now: now, scheduleFor: { inventory[$0] }, startMonitoring: monitor,
        stopMonitoring: { _ in }, publishStartCutoff: { _, _ in false }
      ).isEmpty)
    XCTAssertEqual(attempts, [stop], "Start publication failure must still attempt the missing stop")
  }

  func testDisablingOrPendingSelectionRemovesOnlyItsOwnActivityAndCutoff() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let suiteName = "DisableRegistration-\(UUID())"
    let defaults = UserDefaults(suiteName: suiteName)!
    SharedData.configure(suite: defaults)
    defer { defaults.removePersistentDomain(forName: suiteName) }
    for pending in [false, true] {
      let profile = profile(now: now)
      let start = DeviceActivityName(profile.id.uuidString)
      let stop = StopScheduleTimerActivity().getDeviceActivityName(from: profile.id.uuidString)
      var inventory = [
        start: DeviceActivitySchedule(intervalStart: .init(hour: 9, minute: 0), intervalEnd: .init(hour: 8, minute: 59), repeats: true),
        stop: DeviceActivitySchedule(intervalStart: .init(hour: 0, minute: 0), intervalEnd: .init(hour: 17, minute: 0), repeats: true),
      ]
      XCTAssertTrue(SharedData.setStartRegistrationNotBefore(now, for: profile.id))
      profile.startTriggers.schedule = pending
      profile.needsAppSelection = pending
      var removed: [DeviceActivityName] = []
      XCTAssertTrue(
        DeviceActivityCenterUtil.scheduleTimerActivity(
          for: profile, now: now, scheduleFor: { inventory[$0] },
          startMonitoring: { _, _ in XCTFail("Stop must remain registered") },
          stopMonitoring: { names in
            removed += names
            for name in names { inventory.removeValue(forKey: name) }
          }
        ).isEmpty)
      XCTAssertEqual(removed, [start])
      XCTAssertNil(SharedData.startRegistrationNotBefore(for: profile.id))
      XCTAssertEqual(DeviceActivityCenterUtil.requiredActivities(for: profile), [stop])
      profile.stopConditions.schedule = false
      removed = []
      _ = DeviceActivityCenterUtil.scheduleTimerActivity(
        for: profile, now: now, scheduleFor: { inventory[$0] },
        startMonitoring: { _, _ in XCTFail("No schedules enabled") }, stopMonitoring: { removed += $0 })
      XCTAssertEqual(removed, [stop])
    }
  }

}
