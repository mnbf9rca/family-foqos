import Combine
import Foundation

enum StartupRecoveryMembershipResult: Equatable {
  case member(role: FamilyRole, ownerUserRecordName: String)
  case confirmedNone(ownerUserRecordName: String)
  case indeterminate
}

enum StartupRecoveryProfileCountResult: Equatable {
  case confirmed(Int)
  case indeterminate
}

enum StartupRecoveryPath: String, Codable {
  case freshMember
  case localStatePresentMember
}

struct StartupRecoveryOriginState: Codable, Equatable {
  let modeRawValue: String?
  let hasSelectedMode: Bool?
  let onboardingCompleted: Bool?
  let showIntro: Bool?
  let showModeSelection: Bool?
  let deviceSyncEnabled: Bool?
}

struct StartupRecoveryPendingOffer: Codable, Equatable {
  let ownerUserRecordName: String
  let role: FamilyRole
  let path: StartupRecoveryPath
  let profileCountHint: Int?
  let profileCountConfirmedAt: Date?
  let origin: StartupRecoveryOriginState
}

struct StartupRecoveryStore {
  private enum Key {
    static let pendingOffer = "startup_recovery_pending_offer"
    static let recheckPending = "startup_recovery_recheck_pending"
  }

  let defaults: UserDefaults

  var pendingOffer: StartupRecoveryPendingOffer? {
    get {
      guard let data = defaults.data(forKey: Key.pendingOffer) else { return nil }
      return try? JSONDecoder().decode(StartupRecoveryPendingOffer.self, from: data)
    }
    nonmutating set {
      guard let newValue else {
        defaults.removeObject(forKey: Key.pendingOffer)
        return
      }
      guard let data = try? JSONEncoder().encode(newValue) else { return }
      defaults.set(data, forKey: Key.pendingOffer)
    }
  }

  var recheckPending: Bool {
    defaults.bool(forKey: Key.recheckPending)
  }

  func markRecheckPending() {
    defaults.set(true, forKey: Key.recheckPending)
  }

  func clearRecheckPending() {
    defaults.removeObject(forKey: Key.recheckPending)
  }
}

enum StartupRecoveryState: Equatable {
  case checking
  case retryMembership(canContinueSetup: Bool)
  case retryProfiles(role: FamilyRole)
  case normal(recheckArmed: Bool)
  case checkingProfiles(role: FamilyRole)
  case offer(role: FamilyRole, profileCount: Int)
  case roleRestored(role: FamilyRole)
}

@MainActor
final class StartupRecoveryCoordinator: ObservableObject {
  @Published private(set) var state = StartupRecoveryState.checking

  private let store: StartupRecoveryStore
  private let captureLocalClassification: () -> StartupRecoveryLocalClassification
  private let captureOrigin: () -> StartupRecoveryOriginState
  private let restoreOrigin: (StartupRecoveryOriginState) -> Void
  private let lookupMembership: () async -> StartupRecoveryMembershipResult
  private let lookupSyncedProfileCount: (String) async -> StartupRecoveryProfileCountResult
  private let restoreFamilyRole: (FamilyRole) -> Void
  private let refreshChildLockCodes: () async -> Void
  private let setSyncEnabled: (Bool) -> Void
  private let releaseStartup: () -> Void
  private var didReleaseStartup = false
  private var membershipClassification = StartupRecoveryLocalClassification.fresh
  private var inFlightTask: Task<Void, Never>?
  private var inFlightID = 0
  private var acceptanceInFlight = false

  init(
    store: StartupRecoveryStore,
    captureLocalClassification: @escaping () -> StartupRecoveryLocalClassification = { .fresh },
    captureOrigin: @escaping () -> StartupRecoveryOriginState = {
      StartupRecoveryOriginState(
        modeRawValue: nil,
        hasSelectedMode: nil,
        onboardingCompleted: nil,
        showIntro: nil,
        showModeSelection: nil,
        deviceSyncEnabled: nil)
    },
    restoreOrigin: @escaping (StartupRecoveryOriginState) -> Void = { _ in },
    lookupMembership: @escaping () async -> StartupRecoveryMembershipResult,
    lookupSyncedProfileCount: @escaping (String) async -> StartupRecoveryProfileCountResult,
    restoreFamilyRole: @escaping (FamilyRole) -> Void,
    refreshChildLockCodes: @escaping () async -> Void,
    setSyncEnabled: @escaping (Bool) -> Void,
    releaseStartup: @escaping () -> Void
  ) {
    self.store = store
    self.captureLocalClassification = captureLocalClassification
    self.captureOrigin = captureOrigin
    self.restoreOrigin = restoreOrigin
    self.lookupMembership = lookupMembership
    self.lookupSyncedProfileCount = lookupSyncedProfileCount
    self.restoreFamilyRole = restoreFamilyRole
    self.refreshChildLockCodes = refreshChildLockCodes
    self.setSyncEnabled = setSyncEnabled
    self.releaseStartup = releaseStartup
  }

  func start(classification: StartupRecoveryLocalClassification) async {
    await performSingleFlight { [weak self] in
      await self?.startWork(classification: classification)
    }
  }

  private func startWork(classification: StartupRecoveryLocalClassification) async {
    membershipClassification = classification
    if let pendingOffer = store.pendingOffer {
      state = .checking
      await resume(pendingOffer)
      return
    }

    if store.recheckPending {
      showNormal(recheckArmed: true)
      return
    }

    switch classification {
    case .localStatePresent:
      showNormal(recheckArmed: false)
    case .fresh:
      await checkMembership(
        classification: classification,
        canContinueAfterFailure: false,
        releasesStartup: true)
    case .indeterminate:
      state = .retryMembership(canContinueSetup: false)
    }
  }

  func retry() async {
    await performSingleFlight { [weak self] in
      await self?.retryWork()
    }
  }

  private func retryWork() async {
    switch state {
    case .retryMembership:
      state = .checking
      if let pendingOffer = store.pendingOffer {
        await resume(pendingOffer)
      } else {
        await checkMembership(
          classification: membershipClassification,
          canContinueAfterFailure: true,
          releasesStartup: true)
      }
    case .retryProfiles:
      guard let pendingOffer = store.pendingOffer else { return }
      await resume(pendingOffer)
    default:
      break
    }
  }

  func continueSetup() {
    guard state == .retryMembership(canContinueSetup: true) else { return }
    store.markRecheckPending()
    showNormal(recheckArmed: true)
  }

  func beginShareAcceptance() {
    guard !acceptanceInFlight else { return }
    acceptanceInFlight = true
    inFlightID += 1
    inFlightTask?.cancel()
    inFlightTask = nil
  }

  func failShareAcceptance() {
    guard acceptanceInFlight else { return }
    acceptanceInFlight = false
  }

  func completeShareAcceptanceAfterModeApplied() {
    guard acceptanceInFlight else { return }
    acceptanceInFlight = false
    store.pendingOffer = nil
    store.clearRecheckPending()
    showNormal(recheckArmed: false)
  }

  func dismissRoleRestoredNotice() {
    guard case .roleRestored = state,
      store.pendingOffer?.path == .localStatePresentMember
    else { return }
    store.pendingOffer = nil
    state = .normal(recheckArmed: false)
  }

  func recheckIfNeeded() async {
    await performSingleFlight { [weak self] in
      await self?.recheckWorkIfNeeded()
    }
  }

  private func recheckWorkIfNeeded() async {
    guard store.recheckPending else { return }
    let classification = captureLocalClassification()
    membershipClassification = classification
    guard classification != .indeterminate else { return }

    let membership = await lookupMembership()
    guard recoveryWorkMayCommit else { return }
    switch membership {
    case .member(let role, let ownerUserRecordName):
      await beginRecovery(
        role: role,
        ownerUserRecordName: ownerUserRecordName,
        classification: classification)
    case .confirmedNone:
      store.clearRecheckPending()
      state = .normal(recheckArmed: false)
    case .indeterminate:
      state = .normal(recheckArmed: true)
    }
  }

  func restoreProfiles() async {
    await performSingleFlight { [weak self] in
      await self?.restoreProfilesWork()
    }
  }

  private func restoreProfilesWork() async {
    guard case .offer(_, let profileCount) = state, profileCount > 0 else { return }
    guard await validateOffer(expectedProfileCount: profileCount) else { return }
    setSyncEnabled(true)
    completeOffer()
  }

  func declineProfiles() async {
    await performSingleFlight { [weak self] in
      await self?.declineProfilesWork()
    }
  }

  private func declineProfilesWork() async {
    guard case .offer(_, let profileCount) = state, profileCount > 0 else { return }
    guard await validateOffer(expectedProfileCount: profileCount) else { return }
    completeOffer()
  }

  func continueWithoutProfiles() async {
    await performSingleFlight { [weak self] in
      await self?.continueWithoutProfilesWork()
    }
  }

  private func continueWithoutProfilesWork() async {
    guard case .offer(_, let profileCount) = state, profileCount == 0 else { return }
    guard await validateOffer(expectedProfileCount: profileCount) else { return }
    completeOffer()
  }

  private func checkMembership(
    classification: StartupRecoveryLocalClassification,
    canContinueAfterFailure: Bool,
    releasesStartup: Bool
  ) async {
    let membership = await lookupMembership()
    guard recoveryWorkMayCommit else { return }
    switch membership {
    case .member(let role, let ownerUserRecordName):
      await beginRecovery(
        role: role,
        ownerUserRecordName: ownerUserRecordName,
        classification: classification)
    case .confirmedNone:
      store.clearRecheckPending()
      state = .normal(recheckArmed: false)
      if releasesStartup { releaseStartupIfNeeded() }
    case .indeterminate:
      state = .retryMembership(canContinueSetup: canContinueAfterFailure)
    }
  }

  private func beginRecovery(
    role: FamilyRole,
    ownerUserRecordName: String,
    classification: StartupRecoveryLocalClassification
  ) async {
    let path: StartupRecoveryPath
    switch classification {
    case .fresh:
      path = .freshMember
    case .localStatePresent:
      path = .localStatePresentMember
    case .indeterminate:
      state = .retryMembership(canContinueSetup: true)
      return
    }

    let pendingOffer = StartupRecoveryPendingOffer(
      ownerUserRecordName: ownerUserRecordName,
      role: role,
      path: path,
      profileCountHint: nil,
      profileCountConfirmedAt: nil,
      origin: captureOrigin())
    store.pendingOffer = pendingOffer
    store.clearRecheckPending()
    restoreFamilyRole(role)
    if role == .child {
      await refreshChildLockCodes()
      guard recoveryWorkMayCommit else { return }
    }
    switch path {
    case .freshMember:
      await checkProfiles(for: pendingOffer)
    case .localStatePresentMember:
      setSyncEnabled(false)
      state = .roleRestored(role: role)
      releaseStartupIfNeeded()
    }
  }

  private func resume(_ pendingOffer: StartupRecoveryPendingOffer) async {
    let membership = await lookupMembership()
    guard recoveryWorkMayCommit else { return }
    switch membership {
    case .member(let role, let ownerUserRecordName):
      guard ownerUserRecordName == pendingOffer.ownerUserRecordName, role == pendingOffer.role else {
        rollback(pendingOffer)
        await beginRecovery(
          role: role,
          ownerUserRecordName: ownerUserRecordName,
          classification: captureLocalClassification())
        return
      }
      switch pendingOffer.path {
      case .freshMember:
        await checkProfiles(for: pendingOffer)
      case .localStatePresentMember:
        setSyncEnabled(false)
        state = .roleRestored(role: role)
        releaseStartupIfNeeded()
      }
    case .confirmedNone:
      rollback(pendingOffer)
      showNormal(recheckArmed: false)
    case .indeterminate:
      state = .retryMembership(canContinueSetup: true)
    }
  }

  private func checkProfiles(for pendingOffer: StartupRecoveryPendingOffer) async {
    state = .checkingProfiles(role: pendingOffer.role)
    let countResult = await lookupSyncedProfileCount(pendingOffer.ownerUserRecordName)
    guard recoveryWorkMayCommit else { return }
    switch countResult {
    case .confirmed(let profileCount):
      let confirmedCount = max(profileCount, 0)
      store.pendingOffer = StartupRecoveryPendingOffer(
        ownerUserRecordName: pendingOffer.ownerUserRecordName,
        role: pendingOffer.role,
        path: pendingOffer.path,
        profileCountHint: confirmedCount,
        profileCountConfirmedAt: Date(),
        origin: pendingOffer.origin)
      state = .offer(role: pendingOffer.role, profileCount: confirmedCount)
    case .indeterminate:
      state = .retryProfiles(role: pendingOffer.role)
    }
  }

  private func validateOffer(expectedProfileCount: Int) async -> Bool {
    guard let pendingOffer = store.pendingOffer, pendingOffer.path == .freshMember else {
      return false
    }
    state = .checkingProfiles(role: pendingOffer.role)

    let membership = await lookupMembership()
    guard recoveryWorkMayCommit else { return false }
    switch membership {
    case .member(let role, let ownerUserRecordName):
      guard ownerUserRecordName == pendingOffer.ownerUserRecordName, role == pendingOffer.role else {
        rollback(pendingOffer)
        await beginRecovery(
          role: role,
          ownerUserRecordName: ownerUserRecordName,
          classification: captureLocalClassification())
        return false
      }
    case .confirmedNone:
      rollback(pendingOffer)
      showNormal(recheckArmed: false)
      return false
    case .indeterminate:
      state = .retryProfiles(role: pendingOffer.role)
      return false
    }

    let countResult = await lookupSyncedProfileCount(pendingOffer.ownerUserRecordName)
    guard recoveryWorkMayCommit else { return false }
    switch countResult {
    case .confirmed(let count):
      let confirmedCount = max(count, 0)
      let refreshedOffer = StartupRecoveryPendingOffer(
        ownerUserRecordName: pendingOffer.ownerUserRecordName,
        role: pendingOffer.role,
        path: pendingOffer.path,
        profileCountHint: confirmedCount,
        profileCountConfirmedAt: Date(),
        origin: pendingOffer.origin)
      store.pendingOffer = refreshedOffer
      if confirmedCount != expectedProfileCount {
        state = .offer(role: pendingOffer.role, profileCount: confirmedCount)
        return false
      }
      return true
    case .indeterminate:
      state = .retryProfiles(role: pendingOffer.role)
      return false
    }
  }

  private func rollback(_ pendingOffer: StartupRecoveryPendingOffer) {
    restoreOrigin(pendingOffer.origin)
    store.pendingOffer = nil
    store.clearRecheckPending()
  }

  private func completeOffer() {
    store.pendingOffer = nil
    showNormal(recheckArmed: false)
  }

  private func showNormal(recheckArmed: Bool) {
    state = .normal(recheckArmed: recheckArmed)
    releaseStartupIfNeeded()
  }

  private func releaseStartupIfNeeded() {
    guard !didReleaseStartup else { return }
    didReleaseStartup = true
    releaseStartup()
  }

  private func performSingleFlight(
    _ operation: @escaping @MainActor () async -> Void
  ) async {
    guard !acceptanceInFlight else { return }
    if let inFlightTask {
      await inFlightTask.value
      return
    }

    inFlightID += 1
    let operationID = inFlightID
    let task = Task { @MainActor in
      await operation()
    }
    inFlightTask = task
    await task.value
    if inFlightID == operationID {
      inFlightTask = nil
    }
  }

  private var recoveryWorkMayCommit: Bool {
    !acceptanceInFlight && !Task.isCancelled
  }
}
