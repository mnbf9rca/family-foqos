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

struct StartupRecoveryPendingOffer: Codable, Equatable {
  let ownerUserRecordName: String
  let role: FamilyRole
  let profileCount: Int?
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
}

@MainActor
final class StartupRecoveryCoordinator: ObservableObject {
  @Published private(set) var state = StartupRecoveryState.checking

  private let store: StartupRecoveryStore
  private let lookupMembership: () async -> StartupRecoveryMembershipResult
  private let lookupSyncedProfileCount: (String) async -> StartupRecoveryProfileCountResult
  private let restoreFamilyRole: (FamilyRole) -> Void
  private let refreshChildLockCodes: () async -> Void
  private let setSyncEnabled: (Bool) -> Void
  private let releaseStartup: () -> Void
  private var didReleaseStartup = false

  init(
    store: StartupRecoveryStore,
    lookupMembership: @escaping () async -> StartupRecoveryMembershipResult,
    lookupSyncedProfileCount: @escaping (String) async -> StartupRecoveryProfileCountResult,
    restoreFamilyRole: @escaping (FamilyRole) -> Void,
    refreshChildLockCodes: @escaping () async -> Void,
    setSyncEnabled: @escaping (Bool) -> Void,
    releaseStartup: @escaping () -> Void
  ) {
    self.store = store
    self.lookupMembership = lookupMembership
    self.lookupSyncedProfileCount = lookupSyncedProfileCount
    self.restoreFamilyRole = restoreFamilyRole
    self.refreshChildLockCodes = refreshChildLockCodes
    self.setSyncEnabled = setSyncEnabled
    self.releaseStartup = releaseStartup
  }

  func start(classification: StartupRecoveryLocalClassification) async {
    if let pendingOffer = store.pendingOffer {
      if let profileCount = pendingOffer.profileCount {
        state = .offer(role: pendingOffer.role, profileCount: profileCount)
      } else {
        await recover(
          role: pendingOffer.role,
          ownerUserRecordName: pendingOffer.ownerUserRecordName)
      }
      return
    }

    if store.recheckPending {
      showNormal(recheckArmed: true)
      return
    }

    switch classification {
    case .existing:
      showNormal(recheckArmed: false)
    case .fresh:
      await checkMembership(canContinueAfterFailure: false, releasesStartup: true)
    case .indeterminate:
      state = .retryMembership(canContinueSetup: false)
    }
  }

  func retry() async {
    switch state {
    case .retryMembership:
      state = .checking
      await checkMembership(canContinueAfterFailure: true, releasesStartup: true)
    case .retryProfiles(let role):
      guard let ownerUserRecordName = store.pendingOffer?.ownerUserRecordName else {
        state = .retryMembership(canContinueSetup: true)
        return
      }
      await checkProfiles(for: role, ownerUserRecordName: ownerUserRecordName)
    default:
      break
    }
  }

  func continueSetup() {
    guard state == .retryMembership(canContinueSetup: true) else { return }
    store.markRecheckPending()
    showNormal(recheckArmed: true)
  }

  func recheckIfNeeded() async {
    guard store.recheckPending else { return }

    switch await lookupMembership() {
    case .member(let role, let ownerUserRecordName):
      await recover(role: role, ownerUserRecordName: ownerUserRecordName)
    case .confirmedNone:
      store.clearRecheckPending()
      state = .normal(recheckArmed: false)
    case .indeterminate:
      state = .normal(recheckArmed: true)
    }
  }

  func restoreProfiles() {
    guard case .offer(_, let profileCount) = state, profileCount > 0 else { return }
    setSyncEnabled(true)
    completeOffer()
  }

  func declineProfiles() {
    guard case .offer(_, let profileCount) = state, profileCount > 0 else { return }
    completeOffer()
  }

  func continueWithoutProfiles() {
    guard case .offer(_, let profileCount) = state, profileCount == 0 else { return }
    completeOffer()
  }

  private func checkMembership(canContinueAfterFailure: Bool, releasesStartup: Bool) async {
    switch await lookupMembership() {
    case .member(let role, let ownerUserRecordName):
      await recover(role: role, ownerUserRecordName: ownerUserRecordName)
    case .confirmedNone:
      store.clearRecheckPending()
      state = .normal(recheckArmed: false)
      if releasesStartup { releaseStartupIfNeeded() }
    case .indeterminate:
      state = .retryMembership(canContinueSetup: canContinueAfterFailure)
    }
  }

  private func recover(role: FamilyRole, ownerUserRecordName: String) async {
    store.pendingOffer = StartupRecoveryPendingOffer(
      ownerUserRecordName: ownerUserRecordName,
      role: role,
      profileCount: nil)
    store.clearRecheckPending()
    restoreFamilyRole(role)
    if role == .child {
      await refreshChildLockCodes()
    }
    await checkProfiles(for: role, ownerUserRecordName: ownerUserRecordName)
  }

  private func checkProfiles(for role: FamilyRole, ownerUserRecordName: String) async {
    state = .checkingProfiles(role: role)
    switch await lookupSyncedProfileCount(ownerUserRecordName) {
    case .confirmed(let profileCount):
      let confirmedCount = max(profileCount, 0)
      store.pendingOffer = StartupRecoveryPendingOffer(
        ownerUserRecordName: ownerUserRecordName,
        role: role,
        profileCount: confirmedCount)
      state = .offer(role: role, profileCount: confirmedCount)
    case .indeterminate:
      state = .retryProfiles(role: role)
    }
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
}
