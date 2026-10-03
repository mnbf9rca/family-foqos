import DeviceActivity
import FoqosShared
import SwiftData
import XCTest

@testable import FamilyFoqos

private final class IndependentScheduleApplier: RestrictionApplying {
  var activations = 0
  var deactivations = 0
  func activateRestrictions(for profile: SharedData.ProfileSnapshot) { activations += 1 }
  func deactivateRestrictions() { deactivations += 1 }
  func deactivateRestrictions(keepingSafeguardsFor profile: SharedData.ProfileSnapshot?) { deactivations += 1 }
}

@MainActor
final class IndependentScheduleRuntimeTests: XCTestCase {
  private var suiteName: String!
  private var defaults: UserDefaults!
  private var applier: IndependentScheduleApplier!
  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }
  private var monday: Date {
    calendar.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 9))!
  }

  override func setUp() async throws {
    try await super.setUp()
    suiteName = "IndependentScheduleRuntime-\(UUID())"
    defaults = UserDefaults(suiteName: suiteName)!
    SharedData.configure(suite: defaults)
    applier = IndependentScheduleApplier()
  }

  override func tearDown() async throws {
    defaults.removePersistentDomain(forName: suiteName)
    try await super.tearDown()
  }

  private func at(_ hour: Int, day: Int = 0, minute: Int = 0) -> Date {
    let date = calendar.date(byAdding: .day, value: day, to: monday)!
    return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date)!
  }

  private func profile(start: ProfileScheduleTime? = nil, stop: ProfileScheduleTime? = nil, timer: Bool = false) -> SharedData.ProfileSnapshot {
    let model = BlockedProfiles(name: "Independent", createdAt: monday, updatedAt: monday)
    model.startTriggers = .init(manual: true, schedule: true)
    model.startSchedule = start ?? .init(days: [.monday], hour: 9, minute: 0, updatedAt: .distantPast)
    model.stopConditions = .init(manual: true, timer: timer, schedule: true, timerDurationMinutes: timer ? 37 : nil)
    model.stopSchedule = stop ?? .init(days: [.friday], hour: 17, minute: 0, updatedAt: .distantPast)
    let snapshot = BlockedProfiles.getSnapshot(for: model)
    SharedData.setSnapshot(snapshot, for: snapshot.id.uuidString)
    return snapshot
  }

  private func install(_ profile: SharedData.ProfileSnapshot, start: Date, origin: SessionOrigin.Kind = .manual) -> SharedData.SessionSnapshot {
    let session = SharedData.SessionSnapshot(id: UUID().uuidString, tag: "fixture", blockedProfileId: profile.id, startTime: start, forceStarted: false, origin: .init(kind: origin))
    SharedData.createActiveSharedSession(for: session)
    return session
  }

  private func starter(registrations: @escaping (Int, Date) -> Void = { _, _ in }) -> ScheduleTimerActivity {
    ScheduleTimerActivity(
      applier: applier,
      registerTimer: { _, _, minutes, now in
        registrations(minutes, now)
        return now.addingTimeInterval(TimeInterval(minutes * 60))
      }, cancelTimer: { _, _ in }, cancelReminders: { _ in })
  }

  func testRealLateCallbackStartsOnceAndTimerBeginsAtDelivery() throws {
    let now = at(18)
    let profile = profile(timer: true)
    var registrations = 0
    let start = starter { minutes, accepted in
      registrations += 1
      XCTAssertEqual(minutes, 37)
      XCTAssertEqual(accepted, now)
    }
    start.start(for: profile, now: now, calendar: calendar)
    let session = try XCTUnwrap(SharedData.getActiveSharedSession())
    XCTAssertEqual(session.startTime, now)
    XCTAssertEqual(session.timerEndTime, now.addingTimeInterval(37 * 60))
    XCTAssertEqual(session.origin?.kind, .schedule)
    start.start(for: profile, now: now.addingTimeInterval(60), calendar: calendar)
    XCTAssertEqual(SharedData.getActiveSharedSession()?.id, session.id)
    XCTAssertEqual(registrations, 1)
    XCTAssertEqual(applier.activations, 1)
  }

  func testLateCallbackSkipsOnlyEnabledStopsInStartToDeliveryInterval() {
    for delivery in [at(18), at(18, day: 4)] {
      defaults.removePersistentDomain(forName: suiteName)
      let profile = profile()
      starter().start(for: profile, now: delivery, calendar: calendar)
      XCTAssertEqual(SharedData.getActiveSharedSession() != nil, delivery == at(18))
    }
    defaults.removePersistentDomain(forName: suiteName)
    let equalDisjoint = profile(stop: .init(days: [.friday], hour: 9, minute: 0, updatedAt: .distantPast))
    starter().start(for: equalDisjoint, now: monday, calendar: calendar)
    XCTAssertNotNil(SharedData.getActiveSharedSession())
  }

  func testOvernightStartAcceptsBeforeStopAndSkipsAfterIt() {
    for hour in [3, 7] {
      defaults.removePersistentDomain(forName: suiteName)
      let profile = profile(
        start: .init(days: [.monday], hour: 22, minute: 0, updatedAt: .distantPast),
        stop: .init(days: [.tuesday], hour: 6, minute: 0, updatedAt: .distantPast))
      starter().start(for: profile, now: at(hour, day: 1), calendar: calendar)
      XCTAssertEqual(SharedData.getActiveSharedSession() != nil, hour == 3)
    }
  }

  func testDailyClockDoesNotRescueRefusedMondayOnTuesday() {
    let now = at(9, day: 1)
    var profile = profile()
    profile.scheduleLastStoppedAt = monday
    SharedData.setSnapshot(profile, for: profile.id.uuidString)
    starter().start(for: profile, now: monday, calendar: calendar)
    XCTAssertNil(SharedData.getActiveSharedSession())
    starter().start(for: profile, now: now, calendar: calendar)
    XCTAssertNil(SharedData.getActiveSharedSession())
    starter().start(for: profile, now: at(9, day: 7), calendar: calendar)
    XCTAssertNotNil(SharedData.getActiveSharedSession())
  }

  func testTuesdayBeforeDailyClockMayDeliverMondayOccurrence() {
    let now = at(8, day: 1)
    let profile = profile()
    starter().start(for: profile, now: now, calendar: calendar)
    XCTAssertEqual(SharedData.getActiveSharedSession()?.startTime, now)
  }

  func testConfigAndRegistrationCutoffsRejectHistoricalStartWithoutAgeHeuristic() {
    let now = at(14)
    for cutoff in [false, true] {
      defaults.removePersistentDomain(forName: suiteName)
      var profile = profile()
      if cutoff {
        XCTAssertTrue(SharedData.setStartRegistrationNotBefore(now, for: profile.id))
      } else {
        profile.startSchedule?.updatedAt = at(10)
        SharedData.setSnapshot(profile, for: profile.id.uuidString)
      }
      starter().start(for: profile, now: now, calendar: calendar)
      XCTAssertNil(SharedData.getActiveSharedSession())
      starter().start(for: profile, now: at(9, day: 7), calendar: calendar)
      XCTAssertNotNil(SharedData.getActiveSharedSession())
    }
    defaults.removePersistentDomain(forName: suiteName)
    var justSaved = profile()
    justSaved.startSchedule?.updatedAt = monday
    SharedData.setSnapshot(justSaved, for: justSaved.id.uuidString)
    starter().start(for: justSaved, now: monday, calendar: calendar)
    XCTAssertNotNil(SharedData.getActiveSharedSession(), "No arbitrary one-minute exclusion")
  }

  func testMissingRegistrationImmediateCallbackCannotCatchUp() {
    let now = at(14)
    let model = BlockedProfiles(name: "Missing")
    model.startTriggers = .init(schedule: true)
    model.startSchedule = .init(days: [.monday], hour: 9, minute: 0, updatedAt: .distantPast)
    model.stopConditions = .init(manual: true)
    let profile = BlockedProfiles.getSnapshot(for: model)
    SharedData.setSnapshot(profile, for: profile.id.uuidString)
    let start = starter()
    XCTAssertTrue(
      DeviceActivityCenterUtil.scheduleTimerActivity(
        for: model, now: now, scheduleFor: { _ in nil },
        startMonitoring: { _, _ in start.start(for: profile, now: now, calendar: self.calendar) }, stopMonitoring: { _ in }
      ).isEmpty)
    XCTAssertNil(SharedData.getActiveSharedSession())
    start.start(for: profile, now: at(9, day: 7), calendar: calendar)
    XCTAssertNotNil(SharedData.getActiveSharedSession())
  }

  func testStopWinsInEitherOrderForRawEqualClocks() {
    let now = monday
    for withSession in [false, true] {
      for stopFirst in [false, true] {
        defaults.removePersistentDomain(forName: suiteName)
        let profile = profile(stop: .init(days: [.monday], hour: 9, minute: 0, updatedAt: .distantPast), timer: true)
        if withSession { _ = install(profile, start: now.addingTimeInterval(-60)) }
        var registrations = 0
        let start = starter { _, _ in registrations += 1 }
        let stop = StopScheduleTimerActivity(applier: applier)
        if stopFirst { stop.stop(for: profile, now: now, calendar: calendar) }
        start.start(for: profile, now: now, calendar: calendar)
        if !stopFirst { stop.stop(for: profile, now: now, calendar: calendar) }
        XCTAssertNil(SharedData.getActiveSharedSession())
        XCTAssertEqual(registrations, 0)
      }
    }
  }

  func testStopOwnsWeekdaysAndAllSessionOrigins() {
    let now = at(17)
    for origin in [SessionOrigin.Kind.manual, .nfc, .qr, .shortcut, .link, .schedule] {
      defaults.removePersistentDomain(forName: suiteName)
      let profile = profile()
      let session = install(profile, start: at(8), origin: origin)
      let stop = StopScheduleTimerActivity(applier: applier)
      stop.stop(for: profile, now: now, calendar: calendar)
      XCTAssertEqual(SharedData.getActiveSharedSession(), session, "Friday stop does not fire Monday")
      stop.stop(for: profile, now: at(17, day: 4), calendar: calendar)
      XCTAssertNil(SharedData.getActiveSharedSession())
      XCTAssertNil(SharedData.completedSessionsInScheduler.last?.origin)
      XCTAssertNil(SharedData.completedSessionsInScheduler.last?.timerEndTime)
    }
  }

  func testMissedFridayStopCompletesOnLateSaturdayCallback() {
    let now = at(18, day: 5)
    let profile = profile()
    _ = install(profile, start: at(12, day: 3))
    StopScheduleTimerActivity(applier: applier).stop(for: profile, now: now, calendar: calendar)
    XCTAssertNil(SharedData.getActiveSharedSession())
    XCTAssertEqual(SharedData.completedSessionsInScheduler.last?.endTime, now)
    XCTAssertEqual(applier.deactivations, 1)
  }

  func testStopEditDoesNotRetroactivelyEndSessionForNewlyEnabledDay() {
    let now = at(18, day: 5)
    var profile = profile(stop: .init(days: [.thursday], hour: 17, minute: 0, updatedAt: .distantPast))
    let session = install(profile, start: at(12, day: 4))
    profile.stopSchedule = .init(days: [.friday], hour: 17, minute: 0, updatedAt: at(18, day: 4))
    SharedData.setSnapshot(profile, for: profile.id.uuidString)
    var cancellations = 0
    let stop = StopScheduleTimerActivity(applier: applier, cancelTimer: { _, _ in cancellations += 1 })
    stop.stop(for: profile, now: now, calendar: calendar)
    XCTAssertEqual(SharedData.getActiveSharedSession(), session)
    XCTAssertEqual(applier.deactivations, 0)
    XCTAssertEqual(cancellations, 0)
    XCTAssertTrue(SharedData.completedSessionsInScheduler.isEmpty)
    stop.stop(for: profile, now: at(17, day: 11), calendar: calendar)
    XCTAssertNil(SharedData.getActiveSharedSession(), "The next configured Friday stop remains eligible")
    XCTAssertEqual(applier.deactivations, 1)
    XCTAssertEqual(cancellations, 1)
  }

  func testCompletionRejectsStopOccurrenceBeforeConfigEditUnderOwnershipLock() {
    let now = at(18, day: 5)
    var profile = profile()
    let session = install(profile, start: at(12, day: 3))
    profile.stopSchedule?.updatedAt = at(18, day: 4)
    SharedData.setSnapshot(profile, for: profile.id.uuidString)
    var effects = 0
    XCTAssertFalse(
      SharedData.completeSession(
        expectedSessionId: session.id, now: now, scheduledStopAt: at(17, day: 4),
        expectedProfileId: profile.id, calendar: calendar, onComplete: { effects += 1 }))
    XCTAssertEqual(SharedData.getActiveSharedSession(), session)
    XCTAssertEqual(effects, 0)
  }

  func testUnchangedPickerSavePreservesAlreadyDueDelayedStop() throws {
    let now = at(18, day: 5)
    var profile = profile()
    let session = install(profile, start: at(12, day: 3))
    let stored = try XCTUnwrap(profile.stopSchedule)
    profile.stopSchedule = ScheduleTimePicker.scheduleAfterSaving(
      existing: stored, days: Set(stored.days), hour: stored.hour, minute: stored.minute, now: now)
    SharedData.setSnapshot(profile, for: profile.id.uuidString)
    StopScheduleTimerActivity(applier: applier).stop(for: profile, now: now, calendar: calendar)
    XCTAssertNil(SharedData.getActiveSharedSession())
    XCTAssertEqual(SharedData.completedSessionsInScheduler.last?.id, session.id)
    XCTAssertEqual(applier.deactivations, 1)
  }

  func testReenablingSchedulesRejectsPassedStopAndPreservesTheNextOccurrence() throws {
    let now = at(18, day: 4)
    let model = BlockedProfiles(name: "Reenabled")
    model.startTriggers = .init(manual: true)
    model.stopConditions = .init(manual: true)
    model.startSchedule = .init(days: [.monday], hour: 9, minute: 0, updatedAt: .distantPast)
    model.stopSchedule = .init(days: [.friday], hour: 17, minute: 0, updatedAt: .distantPast)
    let container = try TestModelContainer.create()
    let context = ModelContext(container)
    context.insert(model)
    try context.save()
    let configuration = TriggerConfigurationModel()
    configuration.startTriggers = .init(manual: true, schedule: true)
    configuration.stopConditions = .init(manual: true, schedule: true)
    configuration.startSchedule = model.startSchedule
    configuration.stopSchedule = model.stopSchedule
    let session = install(BlockedProfiles.getSnapshot(for: model), start: at(12, day: 3))
    _ = try BlockedProfiles.updateProfile(model, in: context, now: now, triggerConfiguration: configuration)
    XCTAssertEqual(model.startSchedule?.updatedAt, now)
    XCTAssertEqual(model.stopSchedule?.updatedAt, now)
    _ = try BlockedProfiles.updateProfile(model, in: context, now: now.addingTimeInterval(60), triggerConfiguration: configuration)
    XCTAssertEqual(model.startSchedule?.updatedAt, now, "A second unchanged save retains the enable cutoff")
    XCTAssertEqual(model.stopSchedule?.updatedAt, now)
    let profile = BlockedProfiles.getSnapshot(for: model)
    SharedData.setSnapshot(profile, for: profile.id.uuidString)
    let stop = StopScheduleTimerActivity(applier: applier)
    stop.stop(for: profile, now: at(18, day: 5), calendar: calendar)
    XCTAssertEqual(SharedData.getActiveSharedSession(), session)
    XCTAssertEqual(applier.deactivations, 0)
    stop.stop(for: profile, now: at(17, day: 11), calendar: calendar)
    XCTAssertNil(SharedData.getActiveSharedSession())
    XCTAssertEqual(applier.deactivations, 1)
  }

  func testStopConfigCutoffBoundaryPreservesUnchangedLateStops() {
    let now = at(18, day: 5)
    let occurrence = at(17, day: 4)
    for update in [Date.distantPast, occurrence.addingTimeInterval(-1), occurrence, occurrence.addingTimeInterval(1)] {
      defaults.removePersistentDomain(forName: suiteName)
      applier.deactivations = 0
      let profile = profile(stop: .init(days: [.friday], hour: 17, minute: 0, updatedAt: update))
      let session = install(profile, start: at(12, day: 3))
      StopScheduleTimerActivity(applier: applier).stop(for: profile, now: now, calendar: calendar)
      if update <= occurrence {
        XCTAssertNil(SharedData.getActiveSharedSession(), "An unchanged or boundary-valid missed stop still ends the session")
        XCTAssertEqual(applier.deactivations, 1)
      } else {
        XCTAssertEqual(SharedData.getActiveSharedSession(), session)
        XCTAssertEqual(applier.deactivations, 0)
      }
    }
  }

  func testLateStopDoesNotEndReplacementStartedAfterOccurrence() {
    let now = at(18, day: 5)
    let profile = profile()
    let session = install(profile, start: at(18, day: 4))
    StopScheduleTimerActivity(applier: applier).stop(for: profile, now: now, calendar: calendar)
    XCTAssertEqual(SharedData.getActiveSharedSession(), session)
    XCTAssertEqual(applier.deactivations, 0)
    XCTAssertTrue(SharedData.completedSessionsInScheduler.isEmpty)
  }

  func testCompletionRechecksExactSessionAndOccurrenceUnderOwnershipLock() {
    let now = at(18, day: 5)
    let profile = profile()
    let stale = install(profile, start: at(12, day: 3))
    let replacement = install(profile, start: at(18, day: 4))
    var effects = 0
    XCTAssertFalse(SharedData.completeSession(expectedSessionId: stale.id, now: now, scheduledStopAt: at(17, day: 4), expectedProfileId: profile.id, calendar: calendar, onComplete: { effects += 1 }))
    XCTAssertFalse(SharedData.completeSession(expectedSessionId: replacement.id, now: now, scheduledStopAt: at(17, day: 4), expectedProfileId: profile.id, calendar: calendar, onComplete: { effects += 1 }))
    XCTAssertEqual(SharedData.getActiveSharedSession(), replacement)
    XCTAssertEqual(effects, 0)
  }

  func testDisabledInvalidWrongProfileOrFutureStopHasNoEffects() {
    let now = at(16, day: 4)
    var profile = profile()
    let session = install(profile, start: at(8))
    let stop = StopScheduleTimerActivity(applier: applier)
    stop.stop(for: profile, now: now, calendar: calendar)
    XCTAssertEqual(SharedData.getActiveSharedSession(), session)
    profile.stopConditionsSchedule = false
    stop.stop(for: profile, now: at(18, day: 4), calendar: calendar)
    XCTAssertEqual(SharedData.getActiveSharedSession(), session)
    profile.stopConditionsSchedule = true
    profile.stopSchedule?.hour = 24
    stop.stop(for: profile, now: at(18, day: 4), calendar: calendar)
    XCTAssertEqual(SharedData.getActiveSharedSession(), session)
    let other = self.profile()
    stop.stop(for: other, now: at(18, day: 4), calendar: calendar)
    XCTAssertEqual(SharedData.getActiveSharedSession(), session)
    XCTAssertEqual(applier.deactivations, 0)
  }

  func testCompletionSuppressesStoppedOccurrenceButNotNextWeek() throws {
    let now = at(10)
    let profile = profile()
    starter().start(for: profile, now: monday, calendar: calendar)
    let session = try XCTUnwrap(SharedData.getActiveSharedSession())
    XCTAssertTrue(SharedData.completeSession(expectedSessionId: session.id, now: now))
    starter().start(for: profile, now: now.addingTimeInterval(60), calendar: calendar)
    XCTAssertNil(SharedData.getActiveSharedSession(), "Even a stale callback snapshot must recheck shared suppression")
    starter().start(for: profile, now: at(9, day: 7), calendar: calendar)
    XCTAssertNotNil(SharedData.getActiveSharedSession())
  }

  func testTakeoverRefusalAndTimerFailurePreserveVictim() {
    let now = at(18)
    var victim = profile()
    victim.stopConditions = .init(nfc: .any)
    SharedData.setSnapshot(victim, for: victim.id.uuidString)
    let original = install(victim, start: at(8))
    let incoming = profile(timer: true)
    starter().start(for: incoming, now: now, calendar: calendar)
    XCTAssertEqual(SharedData.getActiveSharedSession(), original)
    XCTAssertEqual(applier.activations, 0)
    victim.stopConditions = .init(manual: true)
    SharedData.setSnapshot(victim, for: victim.id.uuidString)
    ScheduleTimerActivity(applier: applier, registerTimer: { _, _, _, _ in throw NSError(domain: "timer", code: 1) }, cancelTimer: { _, _ in }, cancelReminders: { _ in })
      .start(for: incoming, now: now, calendar: calendar)
    XCTAssertEqual(SharedData.getActiveSharedSession(), original)
    XCTAssertEqual(applier.activations, 0)
  }

  func testReplacementDuringTimerRegistrationPreservesReplacement() {
    let now = at(18)
    let victim = profile()
    let original = install(victim, start: at(8))
    let incoming = profile(timer: true)
    var replacement: SharedData.SessionSnapshot?
    var cancellations = 0
    ScheduleTimerActivity(
      applier: applier,
      registerTimer: { _, _, _, delivery in
        XCTAssertEqual(SharedData.getActiveSharedSession(), original)
        replacement = self.install(victim, start: delivery)
        return delivery.addingTimeInterval(37 * 60)
      }, cancelTimer: { _, _ in cancellations += 1 }, cancelReminders: { _ in }
    )
    .start(for: incoming, now: now, calendar: calendar)
    XCTAssertEqual(SharedData.getActiveSharedSession(), replacement)
    XCTAssertEqual(cancellations, 1)
    XCTAssertEqual(applier.activations, 0)
  }

  func testScheduledVictimTakeoverSuppressesItsOccurrence() {
    let now = at(18)
    let victim = profile()
    _ = install(victim, start: at(9), origin: .schedule)
    let incoming = profile()
    starter().start(for: incoming, now: now, calendar: calendar)
    XCTAssertEqual(SharedData.getActiveSharedSession()?.blockedProfileId, incoming.id)
    XCTAssertEqual(SharedData.snapshot(for: victim.id.uuidString)?.scheduleLastStoppedAt, now)
    starter().start(for: victim, now: now.addingTimeInterval(60), calendar: calendar)
    XCTAssertEqual(SharedData.getActiveSharedSession()?.blockedProfileId, incoming.id)
  }

  func testRefreshNeverOriginatesMissedStartButPublishesAndRegistersFutureEvents() throws {
    let now = at(14)
    let container = try TestModelContainer.create()
    let context = container.mainContext
    let model = BlockedProfiles(name: "Refresh", createdAt: now, updatedAt: now)
    model.startTriggers = .init(schedule: true)
    model.startSchedule = .init(days: [.monday], hour: 9, minute: 0, updatedAt: .distantPast)
    model.stopConditions = .init(manual: true)
    context.insert(model)
    try context.save()
    PreActivationReminderScheduler.reconcileMissingSnapshots(context: context)
    var registrations = 0
    PreActivationReminderScheduler.reconcileScheduleRegistrations(
      context: context,
      register: { profile in
        registrations += 1
        return DeviceActivityCenterUtil.scheduleTimerActivity(
          for: profile, now: now, scheduleFor: { _ in nil }, startMonitoring: { _, _ in }, stopMonitoring: { _ in })
      })
    XCTAssertNotNil(SharedData.snapshot(for: model.id.uuidString))
    XCTAssertEqual(registrations, 1)
    XCTAssertEqual(SharedData.startRegistrationNotBefore(for: model.id), now)
    XCTAssertNil(SharedData.getActiveSharedSession())
    XCTAssertEqual(applier.activations, 0)
  }
}
