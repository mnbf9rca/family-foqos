import SwiftData
import XCTest

@testable import FamilyFoqos
@testable import FoqosShared

@MainActor
final class StrategyManagerBreakOMMTests: XCTestCase {
  var suiteName = ""
  var container: ModelContainer!
  var context: ModelContext!
  var applier: RecordingRestrictionApplier!
  var registrar: RecordingBackstopRegistrar!
  var manager: StrategyManager!

  override func setUp() async throws {
    try await super.setUp()
    suiteName = "StrategyManagerBreakOMMTests-\(UUID().uuidString)"
    SharedData.configure(suite: UserDefaults(suiteName: suiteName)!)
    container = try TestModelContainer.create()
    context = ModelContext(container)
    applier = RecordingRestrictionApplier()
    registrar = RecordingBackstopRegistrar()
    manager = StrategyManager(appBlocker: applier, backstopRegistrar: registrar)
  }

  override func tearDown() async throws {
    manager.stopTimer()
    UserDefaults().removePersistentDomain(forName: suiteName)
    try await super.tearDown()
  }

  @discardableResult
  private func seedActiveSession(breakMinutes: Int = 5) throws -> BlockedProfileSession {
    let profile = BlockedProfiles(name: "P")
    profile.enableBreaks = true
    profile.breakTimeInMinutes = breakMinutes
    context.insert(profile)
    let session = BlockedProfileSession.createSession(in: context, withTag: "t", withProfile: profile)
    try context.save()
    try manager.loadActiveSession(context: context)
    applier.clearForAssertion()
    registrar.clearForAssertion()
    return session
  }

  func testGivenActiveSession_WhenForceClearingForSyncedDataWipe_ThenEnforcementIsRemoved() throws {
    _ = try seedActiveSession()

    XCTAssertTrue(manager.isBlocking)

    manager.forceClearEnforcementForSyncedDataWipe(context: context)

    XCTAssertEqual(applier.calls, [.deactivate])
    XCTAssertNil(manager.activeSession)
    XCTAssertFalse(manager.isBlocking)
    XCTAssertNil(manager.timerTask)
  }

  func testGivenBlockingSession_WhenToggleBreakStart_ThenRegistersBeforeLiftAndOpensGrant() {
    let session = try! seedActiveSession()
    let pid = session.blockedProfile.id
    applier.onDeactivate = {
      XCTAssertTrue(self.registrar.calls.contains(.replaceBreak(pid)))
    }
    manager.toggleBreak(context: context)
    XCTAssertEqual(registrar.calls.first, .replaceBreak(pid))
    XCTAssertEqual(applier.calls, [.deactivate])
    let shared = SharedData.getActiveSharedSession()
    XCTAssertNotNil(shared?.breakStartTime)
    XCTAssertNotNil(shared?.breakEndDeadline)
    XCTAssertNotNil(shared?.pinnedProfileConfig)
    XCTAssertNil(manager.errorMessage)
  }

  func testGivenBackstopRegistrationThrows_WhenToggleBreakStart_ThenFailClosedNoLiftNoState() {
    let session = try! seedActiveSession()
    registrar.throwOnReplaceBreak = true
    manager.toggleBreak(context: context)
    XCTAssertNil(SharedData.getActiveSharedSession()?.breakStartTime)
    XCTAssertTrue(applier.calls.isEmpty)
    XCTAssertNotNil(manager.errorMessage)
    _ = session
  }

  func testGivenBlockingSession_WhenStartOneMoreMinute_ThenRegistersAndOpensGrant() {
    let session = try! seedActiveSession()
    let pid = session.blockedProfile.id
    manager.startOneMoreMinute(context: context)
    XCTAssertEqual(registrar.calls.first, .replaceOMM(pid))
    XCTAssertEqual(applier.calls, [.deactivate])
    let shared = SharedData.getActiveSharedSession()
    XCTAssertNotNil(shared?.oneMoreMinuteStartTime)
    XCTAssertNotNil(shared?.oneMoreMinuteDeadline)
    XCTAssertTrue(shared?.oneMoreMinuteUsed ?? false)
    XCTAssertNil(manager.errorMessage)
    _ = session
  }

  func testGivenBackstopThrows_WhenStartOneMoreMinute_ThenFailClosedNoLift() {
    _ = try! seedActiveSession()
    registrar.throwOnReplaceOMM = true
    manager.startOneMoreMinute(context: context)
    XCTAssertNil(SharedData.getActiveSharedSession()?.oneMoreMinuteStartTime)
    XCTAssertTrue(applier.calls.isEmpty)
    XCTAssertNotNil(manager.errorMessage)
  }

  func testGivenBreakStarted_WhenToggleBreakAgain_ThenClosesReblocksAndDeregisters() {
    let session = try! seedActiveSession()
    let pid = session.blockedProfile.id
    manager.toggleBreak(context: context)
    manager.toggleBreak(context: context)
    let shared = SharedData.getActiveSharedSession()
    XCTAssertNotNil(shared?.breakEndTime)
    XCTAssertEqual(applier.calls, [.deactivate, .activate(profileId: pid)])
    XCTAssertEqual(registrar.calls, [.replaceBreak(pid), .removeOMM(pid), .removeBreak(pid)])
    XCTAssertFalse(session.isBreakAvailable)
  }

  func testGivenBreakOpenAndEnableBreaksOff_WhenToggleBreak_ThenStillRoutesToStop() {
    let session = try! seedActiveSession()
    manager.toggleBreak(context: context)
    session.blockedProfile.enableBreaks = false
    try? context.save()
    manager.toggleBreak(context: context)
    XCTAssertNotNil(SharedData.getActiveSharedSession()?.breakEndTime)
  }

  func testGivenExpiredBreak_WhenEvaluateGrantExpiry_ThenClosesAndRemovesBackstop() {
    let session = try! seedActiveSession()
    let now = Date()
    manager.toggleBreak(context: context)
    if var shared = SharedData.getActiveSharedSession() {
      shared.breakEndDeadline = now.addingTimeInterval(-1)
      SharedData.rawCommitActiveSession(shared)
    }
    session.breakEndDeadline = now.addingTimeInterval(-1)
    applier.clearForAssertion()
    registrar.clearForAssertion()
    manager.evaluateGrantExpiry(now: now)
    XCTAssertNotNil(SharedData.getActiveSharedSession()?.breakEndTime)
    XCTAssertEqual(registrar.calls, [.removeBreak(session.blockedProfile.id)])
  }

  func testGivenUnexpiredBreak_WhenEvaluateGrantExpiry_ThenNoOp() {
    let session = try! seedActiveSession()
    let now = Date()
    manager.toggleBreak(context: context)
    manager.evaluateGrantExpiry(now: now)
    XCTAssertNil(SharedData.getActiveSharedSession()?.breakEndTime)
    _ = session
  }

  func testGivenBreakDeadline_WhenGrantCountdownRemaining_ThenFromDeadlineNotProfileDuration() {
    let session = try! seedActiveSession(breakMinutes: 5)
    let now = Date()
    manager.toggleBreak(context: context)
    let r1 = manager.grantCountdownRemaining(now: now)
    XCTAssertNotNil(r1)
    XCTAssertEqual(r1!, 300, accuracy: 2)
    session.blockedProfile.breakTimeInMinutes = 1
    try? context.save()
    let r2 = manager.grantCountdownRemaining(now: now)
    XCTAssertEqual(r2!, 300, accuracy: 2)
  }

  func testGivenOpenUnexpiredBreakBackstopAbsent_WhenReconcile_ThenRearmsIfAbsent() {
    let session = try! seedActiveSession()
    manager.toggleBreak(context: context)
    registrar.hasBreakBackstopReturns = false
    registrar.clearForAssertion()
    manager.reconcileGrants(context: context)
    XCTAssertTrue(registrar.calls.contains(.registerBreakIfAbsent(session.blockedProfile.id)))
  }

  func testGivenRearmThrows_WhenReconcile_ThenFailClosedClosesBreak() {
    let session = try! seedActiveSession()
    manager.toggleBreak(context: context)
    registrar.throwOnRegisterIfAbsent = true
    manager.reconcileGrants(context: context)
    XCTAssertNotNil(SharedData.getActiveSharedSession()?.breakEndTime)
    XCTAssertNotNil(manager.errorMessage)
    _ = session
  }
}
