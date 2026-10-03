// FoqosTests/StrategyManagerStartTests.swift
import FoqosShared
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class StrategyManagerStartTests: XCTestCase {
  private var container: ModelContainer!
  private var context: ModelContext!
  private var manager: StrategyManager!
  private var suiteName: String!

  override func setUp() async throws {
    try await super.setUp()
    suiteName = "StrategyManagerStartTests-\(UUID().uuidString)"
    SharedData.configure(suite: UserDefaults(suiteName: suiteName)!)
    container = try TestModelContainer.create()
    context = container.mainContext
    manager = StrategyManager()
  }

  override func tearDown() async throws {
    manager.stopTimer()
    UserDefaults().removePersistentDomain(forName: suiteName)
    try await super.tearDown()
  }

  private func activeSessions() throws -> [BlockedProfileSession] {
    try context.fetch(
      FetchDescriptor<BlockedProfileSession>(
        predicate: #Predicate { $0.endTime == nil }
      ))
  }

  func testGivenManualTriggerOnly_WhenDeterminingStartAction_ThenReturnsStartImmediately() {
    var start = ProfileStartTriggers()
    start.manual = true

    let action = StartStopActionResolver.determineStartAction(for: start)

    XCTAssertEqual(action, .startImmediately)
  }

  func testGivenNFCTriggerOnly_WhenDeterminingStartAction_ThenReturnsScanNFC() {
    var start = ProfileStartTriggers()
    start.anyNFC = true

    let action = StartStopActionResolver.determineStartAction(for: start)

    XCTAssertEqual(action, .scanNFC)
  }

  func testGivenQRTriggerOnly_WhenDeterminingStartAction_ThenReturnsScanQR() {
    var start = ProfileStartTriggers()
    start.anyQR = true

    let action = StartStopActionResolver.determineStartAction(for: start)

    XCTAssertEqual(action, .scanQR)
  }

  func testGivenScheduleTriggerOnly_WhenDeterminingStartAction_ThenReturnsWaitForSchedule() {
    var start = ProfileStartTriggers()
    start.schedule = true

    let action = StartStopActionResolver.determineStartAction(for: start)

    XCTAssertEqual(action, .waitForSchedule)
  }

  func testGivenDeepLinkTriggerOnly_WhenDeterminingStartAction_ThenReturnsDeepLinkOnly() {
    var start = ProfileStartTriggers()
    start.deepLink = true

    let action = StartStopActionResolver.determineStartAction(for: start)

    XCTAssertEqual(action, .deepLinkOnly)
  }

  func testGivenManualAndNFCTriggers_WhenDeterminingStartAction_ThenShowsPicker() {
    var start = ProfileStartTriggers()
    start.manual = true
    start.anyNFC = true

    let action = StartStopActionResolver.determineStartAction(for: start)

    XCTAssertEqual(action, .showPicker(options: [.startImmediately, .scanNFC]))
  }

  func testGivenNFCAndQRTriggers_WhenDeterminingStartAction_ThenShowsPicker() {
    var start = ProfileStartTriggers()
    start.anyNFC = true
    start.anyQR = true

    let action = StartStopActionResolver.determineStartAction(for: start)

    XCTAssertEqual(action, .showPicker(options: [.scanNFC, .scanQR]))
  }

  func testGivenManualNFCAndQRTriggers_WhenDeterminingStartAction_ThenShowsPickerWithAll() {
    var start = ProfileStartTriggers()
    start.manual = true
    start.anyNFC = true
    start.anyQR = true

    let action = StartStopActionResolver.determineStartAction(for: start)

    XCTAssertEqual(action, .showPicker(options: [.startImmediately, .scanNFC, .scanQR]))
  }

  func testGivenNoTriggers_WhenDeterminingStartAction_ThenReturnsCannotStart() {
    let start = ProfileStartTriggers()

    let action = StartStopActionResolver.determineStartAction(for: start)

    if case .cannotStart = action {
      // expected
    } else {
      XCTFail("Expected .cannotStart, got \(action)")
    }
  }

  func testGivenManualStartWithInvalidStop_WhenDeterminingStartAction_ThenReturnsCannotStart() {
    var start = ProfileStartTriggers()
    start.manual = true
    let stop = ProfileStopConditions()  // all false — invalid

    let action = StartStopActionResolver.determineStartAction(for: start, stopConditions: stop)

    if case .cannotStart = action {
      // expected
    } else {
      XCTFail("Expected .cannotStart, got \(action)")
    }
  }

  func testGivenManualStartWithValidStop_WhenDeterminingStartAction_ThenReturnsStartImmediately() {
    var start = ProfileStartTriggers()
    start.manual = true
    var stop = ProfileStopConditions()
    stop.manual = true

    let action = StartStopActionResolver.determineStartAction(for: start, stopConditions: stop)

    XCTAssertEqual(action, .startImmediately)
  }

  func testGivenActiveSession_WhenStartWithNFCTag_ThenNoSecondSessionAndErrorSurfaced() throws {
    let activeProfile = BlockedProfiles(name: "Active")
    let scannedProfile = BlockedProfiles(name: "Scanned")
    context.insert(activeProfile)
    context.insert(scannedProfile)
    _ = BlockedProfileSession.createSession(
      in: context, withTag: "existing", withProfile: activeProfile)
    try context.save()

    manager.startWithNFCTag(context: context, profile: scannedProfile, tagId: "tag-1")

    XCTAssertEqual(try activeSessions().count, 1)
    XCTAssertNotNil(manager.errorMessage)
  }

  func testGivenProfileNeedsAppSelection_WhenStartWithQRCode_ThenNoSessionAndErrorSurfaced()
    throws
  {
    let profile = BlockedProfiles(name: "Needs Apps")
    profile.needsAppSelection = true
    context.insert(profile)
    try context.save()

    manager.startWithQRCode(context: context, profile: profile, codeValue: "qr-1")

    XCTAssertNil(manager.activeSession)
    XCTAssertTrue(try activeSessions().isEmpty)
    XCTAssertNotNil(manager.errorMessage)
  }

  func testGivenActiveSession_WhenToggleBlockingStart_ThenNoSecondSessionAndErrorSurfaced()
    throws
  {
    let activeProfile = BlockedProfiles(name: "Active")
    let nextProfile = BlockedProfiles(name: "Next")
    nextProfile.blockingStrategyId = ManualBlockingStrategy.id
    context.insert(activeProfile)
    context.insert(nextProfile)
    _ = BlockedProfileSession.createSession(
      in: context, withTag: "existing", withProfile: activeProfile)
    try context.save()

    manager.toggleBlocking(context: context, activeProfile: nextProfile)

    XCTAssertEqual(try activeSessions().count, 1)
    XCTAssertNotNil(manager.errorMessage)
  }

  func testGivenProfileNeedsAppSelection_WhenToggleBlockingStart_ThenNoSessionAndErrorSurfaced()
    throws
  {
    let profile = BlockedProfiles(name: "Needs Apps")
    profile.needsAppSelection = true
    profile.blockingStrategyId = ManualBlockingStrategy.id
    context.insert(profile)
    try context.save()

    manager.toggleBlocking(context: context, activeProfile: profile)

    XCTAssertNil(manager.activeSession)
    XCTAssertTrue(try activeSessions().isEmpty)
    XCTAssertNotNil(manager.errorMessage)
  }

  func testGivenNoActiveSessionAndAppsSelected_WhenStartWithNFCTag_ThenSessionStarts() throws {
    let profile = BlockedProfiles(name: "Ready")
    context.insert(profile)
    try context.save()

    manager.startWithNFCTag(context: context, profile: profile, tagId: "tag-1")

    XCTAssertEqual(manager.activeSession?.blockedProfile.id, profile.id)
    XCTAssertNotNil(manager.timerTask)
  }

  func testGivenProfileNeedsAppSelection_WhenToggleSessionFromDeeplink_ThenNoSessionAndErrorSurfaced()
    async throws
  {
    let profile = BlockedProfiles(name: "Needs Apps")
    profile.needsAppSelection = true
    profile.startTriggers = ProfileStartTriggers(deepLink: true)
    context.insert(profile)
    try context.save()

    await manager.toggleSessionFromDeeplink(
      profile.id.uuidString,
      url: URL(string: "familyfoqos://profile/\(profile.id.uuidString)")!,
      context: context
    )

    XCTAssertNil(manager.activeSession)
    XCTAssertTrue(try activeSessions().isEmpty)
    XCTAssertNotNil(manager.errorMessage)
  }

  func testGivenProfileNeedsAppSelection_WhenToggleSessionFromDeeplinkSwitching_ThenCurrentSessionRemainsAndErrorSurfaced()
    async throws
  {
    let activeProfile = BlockedProfiles(name: "Active")
    activeProfile.stopConditions = ProfileStopConditions(deepLink: true)
    let nextProfile = BlockedProfiles(name: "Needs Apps")
    nextProfile.needsAppSelection = true
    nextProfile.startTriggers = ProfileStartTriggers(deepLink: true)
    context.insert(activeProfile)
    context.insert(nextProfile)
    let activeSession = BlockedProfileSession.createSession(
      in: context, withTag: "active", withProfile: activeProfile)
    try context.save()

    await manager.toggleSessionFromDeeplink(
      nextProfile.id.uuidString,
      url: URL(string: "familyfoqos://profile/\(nextProfile.id.uuidString)")!,
      context: context
    )

    XCTAssertNil(activeSession.endTime)
    XCTAssertEqual(try activeSessions().count, 1)
    XCTAssertNotNil(manager.errorMessage)
  }

  func testGivenGeofenceCheckInFlight_WhenToggleBlockingCalledAgain_ThenSecondCallIsIgnored()
    throws
  {
    let geofenceEvaluator = GeofenceEvaluator()
    geofenceEvaluator.beginGeofenceCheck()
    manager = StrategyManager(geofenceEvaluator: geofenceEvaluator)
    let profile = BlockedProfiles(name: "Manual")
    profile.blockingStrategyId = ManualBlockingStrategy.id
    context.insert(profile)
    try context.save()

    manager.toggleBlocking(context: context, activeProfile: profile)

    XCTAssertNil(manager.activeSession)
    XCTAssertTrue(try activeSessions().isEmpty)
    XCTAssertNotNil(manager.errorMessage)
  }

  func testGivenStaleGeofenceCheckInFlight_WhenToggleBlockingCalledAgain_ThenStartCanProceed()
    throws
  {
    let geofenceEvaluator = GeofenceEvaluator()
    geofenceEvaluator.beginGeofenceCheck(now: Date().addingTimeInterval(-120))
    manager = StrategyManager(geofenceEvaluator: geofenceEvaluator)
    let profile = BlockedProfiles(name: "Manual")
    profile.blockingStrategyId = ManualBlockingStrategy.id
    context.insert(profile)
    try context.save()

    manager.toggleBlocking(context: context, activeProfile: profile)

    XCTAssertEqual(manager.activeSession?.blockedProfile.id, profile.id)
    XCTAssertFalse(geofenceEvaluator.isCheckingGeofence)
  }

  func testGivenRecoveredStaleGeofenceCheck_WhenOldGenerationCompletes_ThenCurrentStateIsNotMutated()
    throws
  {
    let now = Date()
    let geofenceEvaluator = GeofenceEvaluator()
    let staleGeneration = geofenceEvaluator.beginGeofenceCheck(
      now: now.addingTimeInterval(-120))
    XCTAssertTrue(geofenceEvaluator.recoverStaleGeofenceCheck(now: now))
    let currentGeneration = geofenceEvaluator.beginGeofenceCheck(now: now)

    let didCompleteStaleGeneration = geofenceEvaluator.completeGeofenceCheck(
      expectedGeneration: staleGeneration
    ) {
      geofenceEvaluator.errorMessage = "stale completion mutated state"
      geofenceEvaluator.geofenceWarningMessage = "stale warning"
      geofenceEvaluator.showGeofenceStartWarning = true
    }

    XCTAssertFalse(didCompleteStaleGeneration)
    XCTAssertTrue(geofenceEvaluator.isCheckingGeofence)
    XCTAssertNil(geofenceEvaluator.errorMessage)
    XCTAssertEqual(geofenceEvaluator.geofenceWarningMessage, "")
    XCTAssertFalse(geofenceEvaluator.showGeofenceStartWarning)

    let didCompleteCurrentGeneration = geofenceEvaluator.completeGeofenceCheck(
      expectedGeneration: currentGeneration
    ) {
      geofenceEvaluator.errorMessage = "current completion"
    }

    XCTAssertTrue(didCompleteCurrentGeneration)
    XCTAssertFalse(geofenceEvaluator.isCheckingGeofence)
    XCTAssertEqual(geofenceEvaluator.errorMessage, "current completion")
  }

  func testGivenRecoveredStaleGeofenceCheck_WhenEmergencyGenerationCompletes_ThenOldGenerationIsRejected()
    throws
  {
    let now = Date()
    let geofenceEvaluator = GeofenceEvaluator()
    let staleGeneration = geofenceEvaluator.beginGeofenceCheck(
      now: now.addingTimeInterval(-120))
    XCTAssertTrue(geofenceEvaluator.recoverStaleGeofenceCheck(now: now))
    let currentGeneration = geofenceEvaluator.beginGeofenceCheck(now: now)

    XCTAssertFalse(
      geofenceEvaluator.isCurrentGeofenceCheck(expectedGeneration: staleGeneration)
    )
    XCTAssertTrue(
      geofenceEvaluator.isCurrentGeofenceCheck(expectedGeneration: currentGeneration)
    )
  }

  func testGivenActiveSessionFetchFails_WhenRejectionForStart_ThenFailsClosed() throws {
    let profile = BlockedProfiles(name: "Manual")
    context.insert(profile)
    try context.save()

    let rejection = manager.rejectionForStart(profile) {
      throw CocoaError(.fileReadUnknown)
    }

    XCTAssertEqual(rejection, "Couldn't verify whether a session is already active. Try again.")
  }

  func testSpecificNFCStartsWithSpare() throws {
    let profile = BlockedProfiles(name: "Keys")
    profile.startTriggers = ProfileStartTriggers(specificNFC: true)
    profile.startNFCTagIds = ["X", "Y"]
    context.insert(profile)
    try context.save()
    manager.startWithNFCTag(context: context, profile: profile, tagId: "Y")
    XCTAssertEqual(manager.activeSession?.blockedProfile.id, profile.id)
  }

  func testSpecificNFCRejectsUnknownKey() throws {
    let profile = BlockedProfiles(name: "Keys")
    profile.startTriggers = ProfileStartTriggers(specificNFC: true)
    profile.startNFCTagIds = ["X", "Y"]
    context.insert(profile)
    try context.save()
    manager.startWithNFCTag(context: context, profile: profile, tagId: "Z")
    XCTAssertTrue(try activeSessions().isEmpty)
    XCTAssertTrue(manager.errorMessage?.contains("doesn't match") == true)
  }

  func testSpecificQRStartsWithSpare() throws {
    let profile = BlockedProfiles(name: "Keys")
    profile.startTriggers = ProfileStartTriggers(specificQR: true)
    profile.startQRCodeIds = ["X", "Y"]
    context.insert(profile)
    try context.save()
    manager.startWithQRCode(context: context, profile: profile, codeValue: "Y")
    XCTAssertEqual(manager.activeSession?.blockedProfile.id, profile.id)
  }

  func testSpecificQRRejectsUnknownKey() throws {
    let profile = BlockedProfiles(name: "Keys")
    profile.startTriggers = ProfileStartTriggers(specificQR: true)
    profile.startQRCodeIds = ["X", "Y"]
    context.insert(profile)
    try context.save()
    manager.startWithQRCode(context: context, profile: profile, codeValue: "Z")
    XCTAssertTrue(try activeSessions().isEmpty)
    XCTAssertTrue(manager.errorMessage?.contains("doesn't match") == true)
  }

  func testSpecificQRMatchesOldRawPrimaryAndSpareWithoutChangingAssignments() throws {
    let now = Date()
    let payload = " \nHTTPS://EXAMPLE.COM/\t"
    let oldHash = "f7bab0e3b417cf24e9a77e97a53fc4cea1084e20398a2e7258281e80239ca6f1"
    for ids in [[oldHash, "other"], ["other", oldHash]] {
      let profile = BlockedProfiles(name: "Legacy", createdAt: now, updatedAt: now)
      profile.startTriggers = ProfileStartTriggers(specificQR: true)
      profile.startQRCodeIds = ids
      context.insert(profile)
      try context.save()
      manager.startWithQRCode(
        context: context, profile: profile,
        codeValue: QRCodeHasher.hash(payload), rawHash: QRCodeHasher.rawHash(payload))
      let session = try XCTUnwrap(manager.activeSession)
      XCTAssertEqual(session.blockedProfile.id, profile.id)
      XCTAssertEqual(session.tag, "qr:100680ad546ce6a577f42f52df33b4cfdca756859e664b8d7de329b150d09ce9")
      XCTAssertEqual(profile.startQRCodeIds, ids)
      session.endSession()
      try context.save()
      manager.stopTimer()
      manager = StrategyManager()
    }
  }

  func testSpecificQRNewTagMatchesDifferentlyCasedPrintout() throws {
    let now = Date()
    let tag = try SavedTag.findOrCreate(
      id: QRCodeHasher.hash("HTTPS://EXAMPLE.COM/"),
      kind: "qr", name: "New code", in: context)
    let profile = BlockedProfiles(name: "New", createdAt: now, updatedAt: now)
    profile.startTriggers = ProfileStartTriggers(specificQR: true)
    profile.startQRCodeIds = ["other", tag.id]
    context.insert(profile)
    try context.save()
    let scan = " https://Example.Com "
    manager.startWithQRCode(
      context: context, profile: profile,
      codeValue: QRCodeHasher.hash(scan), rawHash: QRCodeHasher.rawHash(scan))
    XCTAssertEqual(manager.activeSession?.blockedProfile.id, profile.id)
  }

  func testSpecificQRRejectsBothDigestsOutsideAssignedTags() throws {
    let now = Date()
    let scan = " HTTPS://EXAMPLE.COM/ "
    _ = try SavedTag.findOrCreate(id: QRCodeHasher.rawHash(scan), kind: "qr", name: "Unassigned", in: context)
    let profile = BlockedProfiles(name: "Other", createdAt: now, updatedAt: now)
    profile.startTriggers = ProfileStartTriggers(specificQR: true)
    profile.startQRCodeIds = [QRCodeHasher.hash("https://elsewhere.example")]
    context.insert(profile)
    try context.save()
    manager.startWithQRCode(
      context: context, profile: profile,
      codeValue: QRCodeHasher.hash(scan), rawHash: QRCodeHasher.rawHash(scan))
    XCTAssertTrue(try activeSessions().isEmpty)
    XCTAssertTrue(manager.errorMessage?.contains("doesn't match") == true)
  }

  func testRegistrationPrecedesEveryObservableEffect() throws {
    let now = Date()
    let profile = BlockedProfiles(name: "Timed", createdAt: now, updatedAt: now)
    profile.startTriggers = .init(manual: true)
    profile.stopConditions = .init(manual: true, timer: true, timerDurationMinutes: 37)
    context.insert(profile)
    try context.save()
    let applier = StartRestrictionSpy()
    var registrations = 0
    let accepted = now.addingTimeInterval(2207)
    let sut = StrategyManager(
      appBlocker: applier,
      registerTimer: { profileId, sessionId, minutes, registeredAt in
        registrations += 1
        XCTAssertEqual(profileId, profile.id)
        XCTAssertNotNil(UUID(uuidString: sessionId))
        XCTAssertEqual(minutes, 37)
        XCTAssertEqual(registeredAt, now)
        XCTAssertTrue(profile.sessions.isEmpty)
        XCTAssertTrue(try self.activeSessions().isEmpty)
        XCTAssertNil(SharedData.getActiveSharedSession())
        XCTAssertEqual(applier.activations, 0)
        XCTAssertNil(self.manager.timerTask)
        return accepted
      })
    defer { sut.stopTimer() }
    let started = try sut.startOriginatingSession(context: context, profile: profile, origin: .init(kind: .manual), now: now)
    XCTAssertEqual(registrations, 1)
    XCTAssertEqual(started.timerEndTime, accepted)
    XCTAssertEqual(SharedData.getActiveSharedSession()?.timerEndTime, accepted)
    XCTAssertEqual(SharedData.getActiveSharedSession()?.id, started.id)
    XCTAssertEqual(started.origin, .init(kind: .manual))
    XCTAssertEqual(applier.activations, 1)
  }

  func testRegistrationFailureEvenWithManualLeavesNoEffects() throws {
    let now = Date()
    let profile = BlockedProfiles(name: "Timed", createdAt: now, updatedAt: now)
    profile.startTriggers = .init(manual: true)
    profile.stopConditions = .init(manual: true, timer: true, timerDurationMinutes: 37)
    context.insert(profile)
    try context.save()
    let applier = StartRestrictionSpy()
    var cancelled: [(UUID, String)] = []
    let sut = StrategyManager(
      appBlocker: applier,
      registerTimer: { _, _, _, _ in throw NSError(domain: "registrar", code: 1) },
      cancelTimer: { cancelled.append(($0, $1)) })
    XCTAssertThrowsError(try sut.startOriginatingSession(context: context, profile: profile, origin: .init(kind: .manual), now: now)) {
      XCTAssertEqual($0.localizedDescription, "This profile couldn’t start because its timer couldn’t be set. Please try again.")
    }
    XCTAssertTrue(profile.sessions.isEmpty)
    XCTAssertTrue(try activeSessions().isEmpty)
    XCTAssertNil(SharedData.getActiveSharedSession())
    XCTAssertEqual(applier.activations, 0)
    XCTAssertEqual(cancelled.count, 1)
    XCTAssertEqual(cancelled.first?.0, profile.id)
    XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(cancelled.first?.1)))
  }

  func testSaveFailureCompensatesOnlyCandidateAndKeepsUnrelatedEdit() throws {
    let now = Date()
    let profile = BlockedProfiles(name: "Timed", createdAt: now, updatedAt: now)
    profile.startTriggers = .init(manual: true)
    profile.stopConditions = .init(timer: true, timerDurationMinutes: 37)
    let unrelated = BlockedProfiles(name: "Before", createdAt: now, updatedAt: now)
    context.insert(profile)
    context.insert(unrelated)
    try context.save()
    unrelated.name = "Pending edit"
    let applier = StartRestrictionSpy()
    var saves = 0
    var cancelled: [String] = []
    let sut = StrategyManager(
      appBlocker: applier,
      registerTimer: { _, _, _, _ in now.addingTimeInterval(2207) },
      cancelTimer: { _, id in cancelled.append(id) },
      saveSession: { context in
        saves += 1
        if saves == 1 { throw NSError(domain: "save", code: 1) }
        try context.save()
      })
    XCTAssertThrowsError(try sut.startOriginatingSession(context: context, profile: profile, origin: .init(kind: .manual), now: now)) {
      XCTAssertEqual($0.localizedDescription, "Couldn’t start this profile. Please try again.")
    }
    XCTAssertEqual(saves, 2)
    XCTAssertEqual(unrelated.name, "Pending edit")
    XCTAssertTrue(profile.sessions.isEmpty)
    XCTAssertTrue(try activeSessions().isEmpty)
    XCTAssertNil(SharedData.getActiveSharedSession())
    XCTAssertEqual(applier.activations, 0)
    XCTAssertEqual(cancelled.count, 1)
  }

  func testReplacementBetweenRegistrationAndCommitSurvivesCandidateCleanup() throws {
    let now = Date()
    let profile = BlockedProfiles(name: "Timed", createdAt: now, updatedAt: now)
    profile.startTriggers = .init(manual: true)
    profile.stopConditions = .init(timer: true, timerDurationMinutes: 37)
    context.insert(profile)
    try context.save()
    let winner = SharedData.SessionSnapshot(id: UUID().uuidString, tag: "winner", blockedProfileId: UUID(), startTime: now, forceStarted: false)
    let applier = StartRestrictionSpy()
    var cancelled: [String] = []
    let sut = StrategyManager(
      appBlocker: applier,
      registerTimer: { _, _, _, _ in
        SharedData.createActiveSharedSession(for: winner)
        return now.addingTimeInterval(2207)
      }, cancelTimer: { _, id in cancelled.append(id) })
    XCTAssertThrowsError(try sut.startOriginatingSession(context: context, profile: profile, origin: .init(kind: .manual), now: now))
    XCTAssertEqual(SharedData.getActiveSharedSession(), winner)
    XCTAssertTrue(profile.sessions.isEmpty)
    XCTAssertTrue(try activeSessions().isEmpty)
    XCTAssertEqual(applier.activations, 0)
    XCTAssertEqual(applier.deactivations, 0)
    XCTAssertEqual(cancelled.count, 1)
    XCTAssertNotEqual(cancelled.first, winner.id)
  }

}

@MainActor
private final class StartRestrictionSpy: RestrictionApplying {
  var activations = 0
  var deactivations = 0
  nonisolated func activateRestrictions(for profile: SharedData.ProfileSnapshot) {
    MainActor.assumeIsolated { activations += 1 }
  }
  nonisolated func deactivateRestrictions() {
    MainActor.assumeIsolated { deactivations += 1 }
  }
  nonisolated func deactivateRestrictions(keepingSafeguardsFor profile: SharedData.ProfileSnapshot?) {
    deactivateRestrictions()
  }
}
