@preconcurrency import FoqosShared
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class StrategyManagerBackgroundTests: XCTestCase {

  private var container: ModelContainer!
  private var context: ModelContext!
  private var manager: StrategyManager!
  private var testSuiteName: String!

  override func setUp() async throws {
    try await super.setUp()
    testSuiteName = "StrategyManagerBackgroundTests-\(UUID().uuidString)"
    SharedData.configure(
      suite: UserDefaults(suiteName: testSuiteName)!
    )
    container = try TestModelContainer.create()
    context = container.mainContext
    manager = StrategyManager()
  }

  override func tearDown() async throws {
    UserDefaults().removePersistentDomain(forName: testSuiteName)
    try await super.tearDown()
  }

  // MARK: - startSessionFromBackground

  func testGivenNoProfile_WhenStartingFromBackground_ThenThrowsProfileNotFound() {
    XCTAssertThrowsError(
      try manager.startSessionFromBackground(UUID(), context: context)
    ) { error in
      XCTAssertTrue(error is IntentError)
      if case IntentError.profileNotFound = error {
      } else {
        XCTFail("Expected profileNotFound, got \(error)")
      }
    }
  }

  func testGivenActiveSession_WhenStartingFromBackground_ThenThrowsSessionAlreadyActive() throws {
    let profile = BlockedProfiles(name: "Test")
    context.insert(profile)
    let session = BlockedProfileSession(tag: "test", blockedProfile: profile)
    context.insert(session)
    try context.save()

    XCTAssertThrowsError(
      try manager.startSessionFromBackground(profile.id, context: context)
    ) { error in
      if case IntentError.sessionAlreadyActive = error {
      } else {
        XCTFail("Expected sessionAlreadyActive, got \(error)")
      }
    }
  }

  func testGivenProfileNeedsAppSelection_WhenStartSessionFromBackground_ThenThrowsAndNoSession()
    throws
  {
    let profile = BlockedProfiles(name: "Needs Apps")
    profile.needsAppSelection = true
    context.insert(profile)
    try context.save()

    XCTAssertThrowsError(
      try manager.startSessionFromBackground(profile.id, context: context)
    ) { error in
      if case IntentError.needsAppSelection = error {
      } else {
        XCTFail("Expected needsAppSelection, got \(error)")
      }
    }

    let sessions = try context.fetch(FetchDescriptor<BlockedProfileSession>())
    XCTAssertTrue(sessions.isEmpty)
    XCTAssertNotNil(manager.errorMessage)
  }

  func testGivenDurationTooShort_WhenStartingFromBackground_ThenThrowsDurationOutOfRange() throws {
    let profile = BlockedProfiles(name: "Test")
    context.insert(profile)
    try context.save()

    XCTAssertThrowsError(
      try manager.startSessionFromBackground(
        profile.id, context: context, durationInMinutes: 14
      )
    ) { error in
      if case IntentError.durationOutOfRange = error {
      } else {
        XCTFail("Expected durationOutOfRange, got \(error)")
      }
    }
  }

  func testGivenDurationTooLong_WhenStartingFromBackground_ThenThrowsDurationOutOfRange() throws {
    let profile = BlockedProfiles(name: "Test")
    context.insert(profile)
    try context.save()

    XCTAssertThrowsError(
      try manager.startSessionFromBackground(
        profile.id, context: context, durationInMinutes: 1441
      )
    ) { error in
      if case IntentError.durationOutOfRange = error {
      } else {
        XCTFail("Expected durationOutOfRange, got \(error)")
      }
    }
  }

  func testGivenDurationExactly1440_WhenStartingFromBackground_ThenThrowsDurationOutOfRange() throws {
    let profile = BlockedProfiles(name: "Test")
    context.insert(profile)
    try context.save()

    XCTAssertThrowsError(
      try manager.startSessionFromBackground(
        profile.id, context: context, durationInMinutes: 1440
      )
    ) { error in
      if case IntentError.durationOutOfRange = error {
      } else {
        XCTFail("Expected durationOutOfRange, got \(error)")
      }
    }
  }

  func testBackgroundStartRefusesTagOnlyProfileWithoutMutation() throws {
    let profile = BlockedProfiles(name: "Tag only")
    profile.startTriggers = ProfileStartTriggers(anyNFC: true)
    profile.stopConditions = ProfileStopConditions(manual: true)
    context.insert(profile)
    try context.save()
    let updatedAt = profile.updatedAt
    XCTAssertThrowsError(try manager.startSessionFromBackground(profile.id, context: context))
    XCTAssertTrue(try context.fetch(FetchDescriptor<BlockedProfileSession>()).isEmpty)
    XCTAssertEqual(profile.updatedAt, updatedAt)
    XCTAssertNil(profile.strategyData)
  }

  // MARK: - stopSessionFromBackground

  func testGivenNoProfile_WhenStoppingFromBackground_ThenThrowsProfileNotFound() async {
    do {
      try await manager.stopSessionFromBackground(UUID(), context: context)
      XCTFail("Expected error to be thrown")
    } catch let error as IntentError {
      if case .profileNotFound = error {
      } else {
        XCTFail("Expected profileNotFound, got \(error)")
      }
    } catch {
      XCTFail("Expected IntentError, got \(error)")
    }
  }

  func testGivenNoActiveSession_WhenStoppingFromBackground_ThenThrowsNoActiveSession() async throws {
    let profile = BlockedProfiles(name: "Test")
    context.insert(profile)
    try context.save()

    do {
      try await manager.stopSessionFromBackground(profile.id, context: context)
      XCTFail("Expected error to be thrown")
    } catch let error as IntentError {
      if case .noActiveSession = error {
      } else {
        XCTFail("Expected noActiveSession, got \(error)")
      }
    } catch {
      XCTFail("Expected IntentError, got \(error)")
    }
  }

  func testGivenActiveSessionOnDifferentProfile_WhenStoppingFromBackground_ThenThrowsNoActiveSession()
    async throws
  {
    let profileA = BlockedProfiles(name: "Profile A")
    let profileB = BlockedProfiles(name: "Profile B")
    context.insert(profileA)
    context.insert(profileB)
    let session = BlockedProfileSession(tag: "test", blockedProfile: profileA)
    context.insert(session)
    try context.save()

    do {
      try await manager.stopSessionFromBackground(profileB.id, context: context)
      XCTFail("Expected error to be thrown")
    } catch let error as IntentError {
      if case .noActiveSession = error {
      } else {
        XCTFail("Expected noActiveSession, got \(error)")
      }
    } catch {
      XCTFail("Expected IntentError, got \(error)")
    }
  }

  func testGivenBackgroundStopsDisabled_WhenStoppingFromBackground_ThenThrowsBackgroundStopsDisabled()
    async throws
  {
    let profile = BlockedProfiles(name: "Test")
    profile.disableBackgroundStops = true
    context.insert(profile)
    let session = BlockedProfileSession(tag: "test", blockedProfile: profile)
    context.insert(session)
    try context.save()

    do {
      try await manager.stopSessionFromBackground(profile.id, context: context)
      XCTFail("Expected error to be thrown")
    } catch let error as IntentError {
      if case .backgroundStopsDisabled = error {
      } else {
        XCTFail("Expected backgroundStopsDisabled, got \(error)")
      }
    } catch {
      XCTFail("Expected IntentError, got \(error)")
    }
  }

  func testGivenNFCOnlyStopProfile_WhenStoppingFromBackground_ThenThrowsStopConditionsNotMet()
    async throws
  {
    let profile = BlockedProfiles(name: "Commitment")
    profile.disableBackgroundStops = false
    profile.stopConditions = ProfileStopConditions(manual: false, anyNFC: true)
    context.insert(profile)
    let session = BlockedProfileSession(tag: "test", blockedProfile: profile)
    context.insert(session)
    try context.save()

    do {
      try await manager.stopSessionFromBackground(profile.id, context: context)
      XCTFail("Expected the NFC-only profile to refuse a background stop (#261)")
    } catch let error as IntentError {
      if case .stopConditionsNotMet = error {
      } else {
        XCTFail("Expected stopConditionsNotMet, got \(error)")
      }
    }
  }

  func testGivenManualStopProfile_WhenStoppingFromBackground_ThenSucceeds() async throws {
    let profile = BlockedProfiles(name: "Casual")
    profile.stopConditions = ProfileStopConditions(manual: true)
    context.insert(profile)
    let session = BlockedProfileSession(tag: "test", blockedProfile: profile)
    context.insert(session)
    try context.save()

    try await manager.stopSessionFromBackground(profile.id, context: context)
  }
  private func eligibleProfile() throws -> BlockedProfiles {
    let profile = BlockedProfiles(name: "Current name")
    profile.startTriggers = ProfileStartTriggers(manual: true, shortcuts: true)
    profile.stopConditions = ProfileStopConditions(manual: true)
    context.insert(profile)
    try context.save()
    return profile
  }

  func testStartPermissionsAndStopReachability() throws {
    let authorization = MockAuthorizationRequesting(initialStatus: .approved)
    let profile = try eligibleProfile()
    let deniedTriggers = [
      ProfileStartTriggers(manual: true), ProfileStartTriggers(anyNFC: true),
      ProfileStartTriggers(anyQR: true), ProfileStartTriggers(schedule: true),
    ]
    for triggers in deniedTriggers {
      profile.startTriggers = triggers
      XCTAssertThrowsError(try manager.startSessionFromBackground(profile.id, context: context, authorization: authorization))
      XCTAssertTrue(try context.fetch(FetchDescriptor<BlockedProfileSession>()).isEmpty)
    }
    profile.startTriggers = ProfileStartTriggers(anyNFC: true, shortcuts: true)
    for conditions in [
      ProfileStopConditions(), ProfileStopConditions(timer: true),
      ProfileStopConditions(sameNFC: true), ProfileStopConditions(sameQR: true),
    ] {
      profile.stopConditions = conditions
      XCTAssertThrowsError(try manager.startSessionFromBackground(profile.id, context: context, authorization: authorization))
      XCTAssertTrue(try context.fetch(FetchDescriptor<BlockedProfileSession>()).isEmpty)
    }
    profile.stopConditions = ProfileStopConditions(anyNFC: true)
    let name = try manager.startSessionFromBackground(profile.id, context: context, authorization: authorization)
    XCTAssertEqual(name, "Current name")
    XCTAssertFalse(try XCTUnwrap(manager.activeSession).forceStarted)
    XCTAssertNil(manager.activeSession?.timerEndTime)
    let id = manager.activeSession?.id
    XCTAssertThrowsError(try manager.startSessionFromBackground(profile.id, context: context, authorization: authorization))
    XCTAssertEqual(manager.activeSession?.id, id)
  }

  func testAuthorizationAndDeletedUUIDFailClosed() throws {
    let profile = try eligibleProfile()
    let authorization = MockAuthorizationRequesting(initialStatus: .denied)
    XCTAssertThrowsError(try manager.startSessionFromBackground(profile.id, context: context, authorization: authorization))
    XCTAssertTrue(authorization.requestedMembers.isEmpty)
    XCTAssertTrue(try context.fetch(FetchDescriptor<BlockedProfileSession>()).isEmpty)
    let id = profile.id
    context.delete(profile)
    try context.save()
    XCTAssertThrowsError(try manager.startSessionFromBackground(id, context: context, authorization: authorization))
  }

  func testDurationUsesEditorGateAndNeverChangesProfile() throws {
    let now = Date()
    let authorization = MockAuthorizationRequesting(initialStatus: .approved)
    let profile = try eligibleProfile()
    profile.isManaged = true
    profile.stopConditions = ProfileStopConditions(sameNFC: true)
    profile.strategyData = StrategyTimerData.toData(from: StrategyTimerData(durationInMinutes: 120))
    BlockedProfiles.updateSnapshot(for: profile)
    try context.save()
    let originalData = profile.strategyData
    let originalUpdated = profile.updatedAt
    let originalSnapshot = SharedData.snapshot(for: profile.id.uuidString)
    var registrations: [Int] = []
    let register: (UUID, Int, Date) throws -> Date = { _, minutes, _ in
      registrations.append(minutes)
      return now.addingTimeInterval(Double(minutes) * 60)
    }
    XCTAssertThrowsError(
      try manager.startSessionFromBackground(
        profile.id, context: context, durationInMinutes: 30, authorization: authorization,
        mode: .child, isUnlocked: { _ in false }, canVerifyCode: true, registerTimer: register))
    XCTAssertTrue(registrations.isEmpty)
    XCTAssertTrue(try context.fetch(FetchDescriptor<BlockedProfileSession>()).isEmpty)
    XCTAssertEqual(profile.strategyData, originalData)
    XCTAssertEqual(profile.updatedAt, originalUpdated)
    XCTAssertEqual(SharedData.snapshot(for: profile.id.uuidString), originalSnapshot)
    try manager.startSessionFromBackground(
      profile.id, context: context, durationInMinutes: 30, authorization: authorization,
      mode: .child, isUnlocked: { _ in true }, canVerifyCode: true, registerTimer: register)
    XCTAssertEqual(registrations, [30])
    XCTAssertEqual(manager.activeSession?.timerEndTime, now.addingTimeInterval(1800))
    XCTAssertEqual(SharedData.getActiveSharedSession()?.timerEndTime, now.addingTimeInterval(1800))
    XCTAssertEqual(profile.strategyData, originalData)
    XCTAssertEqual(profile.updatedAt, originalUpdated)
    XCTAssertEqual(SharedData.snapshot(for: profile.id.uuidString), originalSnapshot)
  }

  func testNilDurationLockedProfileDoesNotRequireEditPermission() throws {
    let profile = try eligibleProfile()
    profile.isManaged = true
    profile.stopConditions = ProfileStopConditions(anyNFC: true)
    try manager.startSessionFromBackground(
      profile.id, context: context, authorization: MockAuthorizationRequesting(initialStatus: .approved),
      mode: .child, isUnlocked: { _ in false }, canVerifyCode: true)
    XCTAssertTrue(manager.isBlocking)
  }

  func testExecutionDurationWithNoSavedDataAndFollowingUntimedStart() async throws {
    let now = Date()
    let profile = try eligibleProfile()
    let authorization = MockAuthorizationRequesting(initialStatus: .approved)
    if #available(iOS 26.4, *) { authorization.sendStatus(.approvedWithDataAccess) }
    try manager.startSessionFromBackground(
      profile.id, context: context, durationInMinutes: 15, authorization: authorization,
      registerTimer: { _, minutes, _ in
        XCTAssertEqual(minutes, 15)
        return now.addingTimeInterval(900)
      })
    XCTAssertNil(profile.strategyData)
    try await manager.stopSessionFromBackground(profile.id, context: context)
    try manager.startSessionFromBackground(profile.id, context: context, authorization: authorization)
    XCTAssertNil(manager.activeSession?.timerEndTime)
    XCTAssertNil(profile.strategyData)
  }

  func testRemoteActiveProfileRefusesDurationBeforeRegistration() throws {
    let profile = try eligibleProfile()
    manager.setRemoteSessionActive(true, profileId: profile.id)
    defer { manager.setRemoteSessionActive(false, profileId: profile.id) }
    XCTAssertThrowsError(
      try manager.startSessionFromBackground(
        profile.id, context: context, durationInMinutes: 30,
        authorization: MockAuthorizationRequesting(initialStatus: .approved),
        registerTimer: { _, _, _ in
          XCTFail("Must not register")
          return Date.distantFuture
        }))
    XCTAssertTrue(try context.fetch(FetchDescriptor<BlockedProfileSession>()).isEmpty)
  }

  func testStopRechecksSessionAndPolicyAfterLocationAwait() async throws {
    let profile = try eligibleProfile()
    let original = BlockedProfileSession.createSession(in: context, withTag: "test", withProfile: profile)
    let geofence = ChangingStopGeofence()
    manager = StrategyManager(geofenceEvaluator: geofence)
    var replacement: BlockedProfileSession?
    geofence.change = {
      original.endSession()
      replacement = BlockedProfileSession.createSession(in: self.context, withTag: "replacement", withProfile: profile)
      try! self.context.save()
    }
    do {
      try await manager.stopSessionFromBackground(profile.id, context: context)
      XCTFail("Must refuse a replacement session")
    } catch { XCTAssertTrue(error is IntentError) }
    XCTAssertTrue(try XCTUnwrap(replacement).isActive)
    XCTAssertEqual(SharedData.getActiveSharedSession()?.id, replacement?.id)
    for disableBackground in [false, true] {
      profile.stopConditions = ProfileStopConditions(manual: true)
      profile.disableBackgroundStops = false
      geofence.change = {
        if disableBackground { profile.disableBackgroundStops = true } else { profile.stopConditions = ProfileStopConditions(anyNFC: true) }
      }
      do {
        try await manager.stopSessionFromBackground(profile.id, context: context)
        XCTFail("Must use current stop policy")
      } catch { XCTAssertTrue(error is IntentError) }
      XCTAssertTrue(try XCTUnwrap(replacement).isActive)
    }
  }

  func testMoreRestrictiveUnlockPreferenceDuringStopRefuses() async throws {
    let profile = try eligibleProfile()
    let session = BlockedProfileSession.createSession(in: context, withTag: "test", withProfile: profile)
    let geofence = ChangingStopGeofence()
    manager = StrategyManager(geofenceEvaluator: geofence)
    var requireUnlock = false
    geofence.change = { requireUnlock = true }
    do {
      try await manager.stopSessionFromBackground(profile.id, context: context, requireUnlock: { requireUnlock })
      XCTFail("Must retry with new authentication policy")
    } catch { XCTAssertTrue(error is IntentError) }
    XCTAssertTrue(session.isActive)
  }

  func testTimerOnlyOverrideUsesExistingModeAndCodeAvailabilityGate() throws {
    let now = Date()
    let profile = try eligibleProfile()
    profile.isManaged = true
    profile.stopConditions = ProfileStopConditions(timer: true)
    let authorization = MockAuthorizationRequesting(initialStatus: .approved)
    for (mode, codeAvailable) in [(AppMode.individual, true), (.parent, true), (.child, false)] {
      try manager.startSessionFromBackground(
        profile.id, context: context, durationInMinutes: 1439, authorization: authorization,
        mode: mode, isUnlocked: { _ in false }, canVerifyCode: codeAvailable,
        registerTimer: { _, minutes, _ in
          XCTAssertEqual(minutes, 1439)
          return now.addingTimeInterval(Double(minutes) * 60)
        })
      XCTAssertNotNil(manager.activeSession?.timerEndTime)
      XCTAssertNil(profile.strategyData)
      try XCTUnwrap(manager.activeSession).endSession(now: now)
      try context.save()
      manager.activeSession = nil
      manager.stopTimer()
    }
    profile.stopConditions = ProfileStopConditions()
    XCTAssertThrowsError(
      try manager.startSessionFromBackground(
        profile.id, context: context, durationInMinutes: 30, authorization: authorization,
        mode: .parent,
        registerTimer: { _, _, _ in
          XCTFail("Invalid stop conditions must refuse before registration")
          return now
        }))
  }

  func testTimerRegistrationFailureReportsStartedSessionWithoutClaimingTimer() throws {
    let profile = try eligibleProfile()
    let snapshot = BlockedProfiles.getSnapshot(for: profile)
    let updatedAt = profile.updatedAt
    do {
      try manager.startSessionFromBackground(
        profile.id, context: context, durationInMinutes: 30,
        authorization: MockAuthorizationRequesting(initialStatus: .approved),
        registerTimer: { _, _, _ in throw NSError(domain: "test", code: 1) })
      XCTFail("Registration failure must be reported")
    } catch {
      XCTAssertTrue(manager.errorMessage?.contains("The session started") == true)
      XCTAssertTrue(manager.errorMessage?.contains("timer could not be registered") == true)
    }
    XCTAssertTrue(manager.isBlocking)
    XCTAssertNil(manager.activeSession?.timerEndTime)
    XCTAssertNil(SharedData.getActiveSharedSession()?.timerEndTime)
    XCTAssertNil(profile.strategyData)
    XCTAssertEqual(profile.updatedAt, updatedAt)
    XCTAssertEqual(BlockedProfiles.getSnapshot(for: profile), snapshot)
  }

}

@MainActor
private final class ChangingStopGeofence: GeofenceEvaluator {
  var change: (() -> Void)?
  override func evaluateGeofenceForStop(profile: BlockedProfiles, context: ModelContext) async -> GeofenceCheckResult? {
    await Task.yield()
    change?()
    return nil
  }
}
