import XCTest

@testable import FamilyFoqos

@MainActor
final class StartupRecoveryCoordinatorTests: XCTestCase {
  func testGivenFreshChildMembership_WhenStarting_ThenPendingStatePrecedesRoleAndOffer() async {
    let (defaults, suiteName) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = StartupRecoveryStore(defaults: defaults)
    var steps: [String] = []

    let coordinator = StartupRecoveryCoordinator(
      store: store,
      lookupMembership: {
        steps.append("membership")
        return .member(role: .child, ownerUserRecordName: "owner-A")
      },
      lookupSyncedProfileCount: { ownerUserRecordName in
        XCTAssertEqual(ownerUserRecordName, "owner-A")
        steps.append("profiles")
        return .confirmed(2)
      },
      restoreFamilyRole: { role in
        XCTAssertEqual(role, .child)
        XCTAssertEqual(
          store.pendingOffer,
          .init(ownerUserRecordName: "owner-A", role: .child, profileCount: nil))
        steps.append("role")
      },
      refreshChildLockCodes: { steps.append("locks") },
      setSyncEnabled: { _ in XCTFail("Sync requires an explicit decision") },
      releaseStartup: { XCTFail("Offer must hold startup") })

    await coordinator.start(classification: .fresh)

    XCTAssertEqual(steps, ["membership", "role", "locks", "profiles"])
    XCTAssertEqual(coordinator.state, .offer(role: .child, profileCount: 2))
    XCTAssertEqual(
      store.pendingOffer,
      .init(ownerUserRecordName: "owner-A", role: .child, profileCount: 2))
  }

  func testGivenIndeterminateMembershipTwice_WhenContinuingSetup_ThenRecheckIsDurable() async {
    let (defaults, suiteName) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = StartupRecoveryStore(defaults: defaults)
    var releaseCount = 0
    let coordinator = makeCoordinator(
      store: store,
      membership: { .indeterminate },
      releaseStartup: { releaseCount += 1 })

    await coordinator.start(classification: .fresh)
    XCTAssertEqual(coordinator.state, .retryMembership(canContinueSetup: false))

    await coordinator.retry()
    XCTAssertEqual(coordinator.state, .retryMembership(canContinueSetup: true))

    coordinator.continueSetup()

    XCTAssertEqual(coordinator.state, .normal(recheckArmed: true))
    XCTAssertTrue(StartupRecoveryStore(defaults: defaults).recheckPending)
    XCTAssertEqual(releaseCount, 1)
  }

  func testGivenRecheckArmed_WhenLaterMembershipIsConfirmed_ThenRecoveryRuns() async {
    let (defaults, suiteName) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = StartupRecoveryStore(defaults: defaults)
    store.markRecheckPending()
    var membership = StartupRecoveryMembershipResult.indeterminate
    var restoredRole: FamilyRole?
    let coordinator = makeCoordinator(
      store: store,
      membership: { membership },
      profileCount: { _ in .confirmed(0) },
      restoreRole: { restoredRole = $0 })

    await coordinator.start(classification: .existing)
    XCTAssertEqual(coordinator.state, .normal(recheckArmed: true))

    membership = .member(role: .parent, ownerUserRecordName: "owner-A")
    await coordinator.recheckIfNeeded()

    XCTAssertEqual(restoredRole, .parent)
    XCTAssertEqual(coordinator.state, .offer(role: .parent, profileCount: 0))
    XCTAssertFalse(store.recheckPending)
  }

  func testGivenRecheckArmed_WhenNoMembershipIsConfirmed_ThenRecheckClears() async {
    let (defaults, suiteName) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = StartupRecoveryStore(defaults: defaults)
    store.markRecheckPending()
    let coordinator = makeCoordinator(
      store: store,
      membership: { .confirmedNone(ownerUserRecordName: "owner-A") })

    await coordinator.start(classification: .existing)
    await coordinator.recheckIfNeeded()

    XCTAssertFalse(store.recheckPending)
    XCTAssertEqual(coordinator.state, .normal(recheckArmed: false))
  }

  func testGivenPendingRoleWithoutCount_WhenRelaunching_ThenRoleAndProfileLookupResume() async {
    let (defaults, suiteName) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = StartupRecoveryStore(defaults: defaults)
    store.pendingOffer = .init(
      ownerUserRecordName: "owner-A",
      role: .child,
      profileCount: nil)
    var steps: [String] = []
    let coordinator = makeCoordinator(
      store: store,
      membership: {
        XCTFail("Pending offer bypasses membership lookup")
        return .indeterminate
      },
      profileCount: { ownerUserRecordName in
        XCTAssertEqual(ownerUserRecordName, "owner-A")
        steps.append("profiles")
        return .confirmed(1)
      },
      restoreRole: { _ in steps.append("role") },
      refreshLocks: { steps.append("locks") })

    await coordinator.start(classification: .existing)

    XCTAssertEqual(steps, ["role", "locks", "profiles"])
    XCTAssertEqual(coordinator.state, .offer(role: .child, profileCount: 1))
  }

  func testGivenPendingOfferWithCount_WhenRelaunching_ThenOfferReturnsWithoutCloudLookup() async {
    let (defaults, suiteName) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = StartupRecoveryStore(defaults: defaults)
    store.pendingOffer = .init(
      ownerUserRecordName: "owner-A",
      role: .parent,
      profileCount: 3)
    let coordinator = makeCoordinator(
      store: store,
      membership: {
        XCTFail("Stored offer bypasses membership lookup")
        return .indeterminate
      },
      profileCount: { _ in
        XCTFail("Stored count bypasses profile lookup")
        return .indeterminate
      })

    await coordinator.start(classification: .existing)

    XCTAssertEqual(coordinator.state, .offer(role: .parent, profileCount: 3))
  }

  func testGivenPositiveOffer_WhenRestoreChosen_ThenSyncEnablesAndPendingOfferClears() async {
    let (defaults, suiteName) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = StartupRecoveryStore(defaults: defaults)
    var syncValues: [Bool] = []
    var releaseCount = 0
    let coordinator = makeCoordinator(
      store: store,
      membership: { .member(role: .parent, ownerUserRecordName: "owner-A") },
      profileCount: { _ in .confirmed(2) },
      setSyncEnabled: { syncValues.append($0) },
      releaseStartup: { releaseCount += 1 })
    await coordinator.start(classification: .fresh)

    coordinator.restoreProfiles()

    XCTAssertEqual(syncValues, [true])
    XCTAssertNil(store.pendingOffer)
    XCTAssertEqual(coordinator.state, .normal(recheckArmed: false))
    XCTAssertEqual(releaseCount, 1)
  }

  func testGivenPositiveOffer_WhenNotNowChosen_ThenSyncStaysDisabledAndPendingOfferClears() async {
    let (defaults, suiteName) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = StartupRecoveryStore(defaults: defaults)
    var didEnableSync = false
    let coordinator = makeCoordinator(
      store: store,
      membership: { .member(role: .parent, ownerUserRecordName: "owner-A") },
      profileCount: { _ in .confirmed(2) },
      setSyncEnabled: { _ in didEnableSync = true })
    await coordinator.start(classification: .fresh)

    coordinator.declineProfiles()

    XCTAssertFalse(didEnableSync)
    XCTAssertNil(store.pendingOffer)
    XCTAssertEqual(coordinator.state, .normal(recheckArmed: false))
  }

  func testGivenZeroProfileOffer_WhenContinueChosen_ThenPendingOfferClearsWithoutSync() async {
    let (defaults, suiteName) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = StartupRecoveryStore(defaults: defaults)
    var didEnableSync = false
    let coordinator = makeCoordinator(
      store: store,
      membership: { .member(role: .child, ownerUserRecordName: "owner-A") },
      profileCount: { _ in .confirmed(0) },
      setSyncEnabled: { _ in didEnableSync = true })
    await coordinator.start(classification: .fresh)

    coordinator.continueWithoutProfiles()

    XCTAssertFalse(didEnableSync)
    XCTAssertNil(store.pendingOffer)
    XCTAssertEqual(coordinator.state, .normal(recheckArmed: false))
  }

  private func makeCoordinator(
    store: StartupRecoveryStore,
    membership: @escaping () async -> StartupRecoveryMembershipResult,
    profileCount: @escaping (String) async -> StartupRecoveryProfileCountResult = { _ in
      .confirmed(0)
    },
    restoreRole: @escaping (FamilyRole) -> Void = { _ in },
    refreshLocks: @escaping () async -> Void = {},
    setSyncEnabled: @escaping (Bool) -> Void = { _ in },
    releaseStartup: @escaping () -> Void = {}
  ) -> StartupRecoveryCoordinator {
    StartupRecoveryCoordinator(
      store: store,
      lookupMembership: membership,
      lookupSyncedProfileCount: profileCount,
      restoreFamilyRole: restoreRole,
      refreshChildLockCodes: refreshLocks,
      setSyncEnabled: setSyncEnabled,
      releaseStartup: releaseStartup)
  }

  private func makeDefaults() -> (UserDefaults, String) {
    let suiteName = "StartupRecoveryCoordinatorTests-\(UUID().uuidString)"
    return (UserDefaults(suiteName: suiteName)!, suiteName)
  }
}
