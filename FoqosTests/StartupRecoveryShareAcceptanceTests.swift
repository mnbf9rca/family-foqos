import XCTest

@testable import FamilyFoqos

@MainActor
final class StartupRecoveryShareAcceptanceTests: XCTestCase {
  func testGivenSuspendedLookup_WhenAcceptanceBeginsAndFails_ThenStaleWorkCannotChangeIntent() async {
    let (defaults, suiteName) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = StartupRecoveryStore(defaults: defaults)
    let pendingOffer = makePendingOffer()
    store.pendingOffer = pendingOffer
    var continuation: CheckedContinuation<StartupRecoveryMembershipResult, Never>?
    let coordinator = makeCoordinator(
      store: store,
      membership: {
        await withCheckedContinuation { continuation = $0 }
      })
    let runtime = StartupRecoveryRuntime()
    runtime.register(coordinator: coordinator)

    let start = Task { @MainActor in await coordinator.start(classification: .fresh) }
    while continuation == nil { await Task.yield() }
    runtime.beginShareAcceptance()
    continuation?.resume(
      returning: .member(role: .parent, ownerUserRecordName: "owner-A"))
    await start.value

    XCTAssertEqual(store.pendingOffer, pendingOffer)
    XCTAssertTrue(runtime.isHeld)

    runtime.failShareAcceptance()
    XCTAssertEqual(store.pendingOffer, pendingOffer)
    XCTAssertTrue(runtime.isHeld)
  }

  func testGivenPendingRecovery_WhenAcceptedModeApplied_ThenIntentClearsAndReleasesOnce() {
    let (defaults, suiteName) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = StartupRecoveryStore(defaults: defaults)
    store.pendingOffer = makePendingOffer()
    let runtime = StartupRecoveryRuntime()
    var releaseCount = 0
    let coordinator = makeCoordinator(
      store: store,
      releaseStartup: {
        releaseCount += 1
        runtime.release()
      })
    runtime.register(coordinator: coordinator)

    runtime.beginShareAcceptance()
    runtime.completeShareAcceptanceAfterModeApplied()
    runtime.completeShareAcceptanceAfterModeApplied()

    XCTAssertNil(store.pendingOffer)
    XCTAssertFalse(store.recheckPending)
    XCTAssertEqual(coordinator.state, .normal(recheckArmed: false))
    XCTAssertFalse(runtime.isHeld)
    XCTAssertEqual(releaseCount, 1)
  }

  private func makeCoordinator(
    store: StartupRecoveryStore,
    membership: @escaping () async -> StartupRecoveryMembershipResult = { .indeterminate },
    releaseStartup: @escaping () -> Void = {}
  ) -> StartupRecoveryCoordinator {
    StartupRecoveryCoordinator(
      store: store,
      lookupMembership: membership,
      lookupSyncedProfileCount: { _ in .confirmed(1) },
      restoreFamilyRole: { _ in },
      refreshChildLockCodes: {},
      setSyncEnabled: { _ in },
      releaseStartup: releaseStartup)
  }

  private func makePendingOffer() -> StartupRecoveryPendingOffer {
    StartupRecoveryPendingOffer(
      ownerUserRecordName: "owner-A",
      role: .parent,
      path: .freshMember,
      profileCountHint: 1,
      profileCountConfirmedAt: Date(timeIntervalSince1970: 1),
      origin: StartupRecoveryOriginState(
        modeRawValue: nil,
        hasSelectedMode: false,
        onboardingCompleted: false,
        showIntro: true,
        showModeSelection: true,
        deviceSyncEnabled: false))
  }

  private func makeDefaults() -> (UserDefaults, String) {
    let suiteName = "StartupRecoveryShareAcceptanceTests-\(UUID().uuidString)"
    return (UserDefaults(suiteName: suiteName)!, suiteName)
  }
}
