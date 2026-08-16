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
          .init(
            ownerUserRecordName: "owner-A",
            role: .child,
            path: .freshMember,
            profileCountHint: nil,
            profileCountConfirmedAt: nil,
            origin: self.emptyOrigin()))
        steps.append("role")
      },
      refreshChildLockCodes: { steps.append("locks") },
      setSyncEnabled: { _ in XCTFail("Sync requires an explicit decision") },
      releaseStartup: { XCTFail("Offer must hold startup") })

    await coordinator.start(classification: .fresh)

    XCTAssertEqual(steps, ["membership", "role", "locks", "profiles"])
    XCTAssertEqual(coordinator.state, .offer(role: .child, profileCount: 2))
    XCTAssertEqual(store.pendingOffer?.ownerUserRecordName, "owner-A")
    XCTAssertEqual(store.pendingOffer?.role, .child)
    XCTAssertEqual(store.pendingOffer?.path, .freshMember)
    XCTAssertEqual(store.pendingOffer?.profileCountHint, 2)
    XCTAssertNotNil(store.pendingOffer?.profileCountConfirmedAt)
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

    await coordinator.start(classification: .localStatePresent)
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

    await coordinator.start(classification: .localStatePresent)
    await coordinator.recheckIfNeeded()

    XCTAssertFalse(store.recheckPending)
    XCTAssertEqual(coordinator.state, .normal(recheckArmed: false))
  }

  func testGivenPendingRoleWithoutCount_WhenRelaunching_ThenOwnerAndProfileLookupResume() async {
    let (defaults, suiteName) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = StartupRecoveryStore(defaults: defaults)
    store.pendingOffer = .init(
      ownerUserRecordName: "owner-A",
      role: .child,
      path: .freshMember,
      profileCountHint: nil,
      profileCountConfirmedAt: nil,
      origin: emptyOrigin())
    var steps: [String] = []
    let coordinator = makeCoordinator(
      store: store,
      membership: {
        steps.append("membership")
        return .member(role: .child, ownerUserRecordName: "owner-A")
      },
      profileCount: { ownerUserRecordName in
        XCTAssertEqual(ownerUserRecordName, "owner-A")
        steps.append("profiles")
        return .confirmed(1)
      },
      restoreRole: { _ in XCTFail("Durable role restoration must be idempotent") },
      refreshLocks: { XCTFail("Durable role restoration must not repeat lock refresh") })

    await coordinator.start(classification: .localStatePresent)

    XCTAssertEqual(steps, ["membership", "profiles"])
    XCTAssertEqual(coordinator.state, .offer(role: .child, profileCount: 1))
  }

  func testGivenPendingOfferWithCount_WhenRelaunching_ThenOwnerAndCountAreRevalidated() async {
    let (defaults, suiteName) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = StartupRecoveryStore(defaults: defaults)
    store.pendingOffer = .init(
      ownerUserRecordName: "owner-A",
      role: .parent,
      path: .freshMember,
      profileCountHint: 3,
      profileCountConfirmedAt: Date(timeIntervalSince1970: 1),
      origin: emptyOrigin())
    let coordinator = makeCoordinator(
      store: store,
      membership: {
        return .member(role: .parent, ownerUserRecordName: "owner-A")
      },
      profileCount: { _ in .confirmed(3) })

    await coordinator.start(classification: .localStatePresent)

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

    await coordinator.restoreProfiles()

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

    await coordinator.declineProfiles()

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

    await coordinator.continueWithoutProfiles()

    XCTAssertFalse(didEnableSync)
    XCTAssertNil(store.pendingOffer)
    XCTAssertEqual(coordinator.state, .normal(recheckArmed: false))
  }

  func testGivenStoredOffer_WhenOwnerMatches_ThenMembershipAndCountAreRevalidated() async {
    let (defaults, suiteName) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = StartupRecoveryStore(defaults: defaults)
    let origin = StartupRecoveryOriginState(
      modeRawValue: nil,
      hasSelectedMode: false,
      onboardingCompleted: false,
      showIntro: true,
      showModeSelection: true,
      deviceSyncEnabled: false)
    store.pendingOffer = .init(
      ownerUserRecordName: "owner-A",
      role: .parent,
      path: .freshMember,
      profileCountHint: 2,
      profileCountConfirmedAt: Date(timeIntervalSince1970: 1),
      origin: origin)
    var membershipCalls = 0
    var countCalls = 0
    let coordinator = makeAccountScopedCoordinator(
      store: store,
      membership: {
        membershipCalls += 1
        return .member(role: .parent, ownerUserRecordName: "owner-A")
      },
      profileCount: { ownerUserRecordName in
        XCTAssertEqual(ownerUserRecordName, "owner-A")
        countCalls += 1
        return .confirmed(2)
      })

    await coordinator.start(classification: .fresh)

    XCTAssertEqual(membershipCalls, 1)
    XCTAssertEqual(countCalls, 1)
    XCTAssertEqual(coordinator.state, .offer(role: .parent, profileCount: 2))
  }

  func testGivenStoredOffer_WhenAccountChangedToConfirmedNonmember_ThenOriginRollsBack() async {
    let (defaults, suiteName) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = StartupRecoveryStore(defaults: defaults)
    let origin = StartupRecoveryOriginState(
      modeRawValue: nil,
      hasSelectedMode: false,
      onboardingCompleted: false,
      showIntro: true,
      showModeSelection: true,
      deviceSyncEnabled: nil)
    store.pendingOffer = .init(
      ownerUserRecordName: "owner-A",
      role: .child,
      path: .freshMember,
      profileCountHint: 1,
      profileCountConfirmedAt: Date(timeIntervalSince1970: 1),
      origin: origin)
    var restoredOrigin: StartupRecoveryOriginState?
    var releaseCount = 0
    let coordinator = makeAccountScopedCoordinator(
      store: store,
      membership: { .confirmedNone(ownerUserRecordName: "owner-B") },
      restoreOrigin: { restoredOrigin = $0 },
      releaseStartup: { releaseCount += 1 })

    await coordinator.start(classification: .fresh)

    XCTAssertEqual(restoredOrigin, origin)
    XCTAssertNil(store.pendingOffer)
    XCTAssertEqual(coordinator.state, .normal(recheckArmed: false))
    XCTAssertEqual(releaseCount, 1)
  }

  func testGivenChangedCountBeforeRestore_WhenTapped_ThenOfferUpdatesAndRequiresSecondTap() async {
    let (defaults, suiteName) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = StartupRecoveryStore(defaults: defaults)
    var counts = [2, 3, 3]
    var syncValues: [Bool] = []
    let coordinator = makeAccountScopedCoordinator(
      store: store,
      membership: { .member(role: .parent, ownerUserRecordName: "owner-A") },
      profileCount: { _ in .confirmed(counts.removeFirst()) },
      setSyncEnabled: { syncValues.append($0) })
    await coordinator.start(classification: .fresh)

    await coordinator.restoreProfiles()
    XCTAssertEqual(coordinator.state, .offer(role: .parent, profileCount: 3))
    XCTAssertTrue(syncValues.isEmpty)
    XCTAssertNotNil(store.pendingOffer)

    await coordinator.restoreProfiles()
    XCTAssertEqual(syncValues, [true])
    XCTAssertNil(store.pendingOffer)
    XCTAssertEqual(coordinator.state, .normal(recheckArmed: false))
  }

  func testGivenRecheckFindsLocalStateAndMembership_WhenRunning_ThenOnlyRoleIsRestored() async {
    let (defaults, suiteName) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = StartupRecoveryStore(defaults: defaults)
    store.markRecheckPending()
    var profileCalls = 0
    var syncValues: [Bool] = []
    let coordinator = StartupRecoveryCoordinator(
      store: store,
      captureLocalClassification: { .localStatePresent },
      lookupMembership: {
        .member(role: .child, ownerUserRecordName: "owner-A")
      },
      lookupSyncedProfileCount: { _ in
        profileCalls += 1
        return .confirmed(4)
      },
      restoreFamilyRole: { _ in },
      refreshChildLockCodes: {},
      setSyncEnabled: { syncValues.append($0) },
      releaseStartup: {})
    await coordinator.start(classification: .localStatePresent)

    await coordinator.recheckIfNeeded()

    XCTAssertEqual(profileCalls, 0)
    XCTAssertEqual(syncValues, [false])
    XCTAssertEqual(coordinator.state, .roleRestored(role: .child))
    XCTAssertEqual(store.pendingOffer?.path, .localStatePresentMember)
  }

  func testGivenOverlappingStarts_WhenMembershipIsSuspended_ThenLookupIsSingleFlight() async {
    let (defaults, suiteName) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = StartupRecoveryStore(defaults: defaults)
    var membershipCalls = 0
    var continuations: [CheckedContinuation<StartupRecoveryMembershipResult, Never>] = []
    let coordinator = makeAccountScopedCoordinator(
      store: store,
      membership: {
        membershipCalls += 1
        return await withCheckedContinuation { continuations.append($0) }
      })

    let first = Task { @MainActor in await coordinator.start(classification: .fresh) }
    while continuations.isEmpty { await Task.yield() }
    let second = Task { @MainActor in await coordinator.start(classification: .fresh) }
    for _ in 0..<10 { await Task.yield() }

    XCTAssertEqual(membershipCalls, 1)
    for continuation in continuations {
      continuation.resume(returning: .confirmedNone(ownerUserRecordName: "owner-A"))
    }
    await first.value
    await second.value
  }

  func testGivenRoleOnlyNotice_WhenDismissed_ThenOwnerBoundPayloadClears() async {
    let (defaults, suiteName) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = StartupRecoveryStore(defaults: defaults)
    store.pendingOffer = .init(
      ownerUserRecordName: "owner-A",
      role: .parent,
      path: .localStatePresentMember,
      profileCountHint: nil,
      profileCountConfirmedAt: nil,
      origin: emptyOrigin())
    let coordinator = makeAccountScopedCoordinator(
      store: store,
      membership: { .member(role: .parent, ownerUserRecordName: "owner-A") })
    await coordinator.start(classification: .localStatePresent)
    XCTAssertEqual(coordinator.state, .roleRestored(role: .parent))

    coordinator.dismissRoleRestoredNotice()

    XCTAssertNil(store.pendingOffer)
    XCTAssertEqual(coordinator.state, .normal(recheckArmed: false))
  }

  private func makeAccountScopedCoordinator(
    store: StartupRecoveryStore,
    membership: @escaping () async -> StartupRecoveryMembershipResult,
    profileCount: @escaping (String) async -> StartupRecoveryProfileCountResult = { _ in
      .confirmed(0)
    },
    restoreOrigin: @escaping (StartupRecoveryOriginState) -> Void = { _ in },
    setSyncEnabled: @escaping (Bool) -> Void = { _ in },
    releaseStartup: @escaping () -> Void = {}
  ) -> StartupRecoveryCoordinator {
    StartupRecoveryCoordinator(
      store: store,
      captureLocalClassification: { .fresh },
      captureOrigin: {
        StartupRecoveryOriginState(
          modeRawValue: nil,
          hasSelectedMode: false,
          onboardingCompleted: false,
          showIntro: true,
          showModeSelection: true,
          deviceSyncEnabled: false)
      },
      restoreOrigin: restoreOrigin,
      lookupMembership: membership,
      lookupSyncedProfileCount: profileCount,
      restoreFamilyRole: { _ in },
      refreshChildLockCodes: {},
      setSyncEnabled: setSyncEnabled,
      releaseStartup: releaseStartup)
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

  private func emptyOrigin() -> StartupRecoveryOriginState {
    StartupRecoveryOriginState(
      modeRawValue: nil,
      hasSelectedMode: nil,
      onboardingCompleted: nil,
      showIntro: nil,
      showModeSelection: nil,
      deviceSyncEnabled: nil)
  }
}
