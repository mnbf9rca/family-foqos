@preconcurrency import FoqosShared
import SwiftData
import XCTest

@testable import FamilyFoqos

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
    return session
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
}
