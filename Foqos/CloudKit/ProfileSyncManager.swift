import CloudKit
import Combine
import Foundation
import SwiftData

/// Manages same-user multi-device profile sync via iCloud private database.
/// UI facade over the CKSyncEngine transport (`SyncEngineController`) — see
/// `attachEngine(...)` for the composition root and the "Engine facade" section
/// below for the verbs the rest of the app calls.
@MainActor
class ProfileSyncManager: ObservableObject {
  static let shared = ProfileSyncManager()

  // MARK: - CloudKit Configuration

  private lazy var container: CKContainer = {
    CKContainer(identifier: CloudKitConstants.containerIdentifier)
  }()

  /// Used by `attachEngine(...)` to hand the engine driver its `CKDatabase`.
  private var privateDatabase: CKDatabase {
    container.privateCloudDatabase
  }

  // MARK: - Published State

  @Published var isEnabled: Bool = false
  @Published private(set) var syncStatusSnapshot = SyncStatusSnapshot(status: .disabled, lastSyncDate: nil)
  /// Set to true when legacy records were cleaned up and user should be notified
  @Published var shouldShowSyncUpgradeNotice = false
  @Published private(set) var syncPausedReason: SyncPausedReason?
  @Published private(set) var accountChangeConflict: AccountChangeConflict?
  private(set) var pendingConflictName: String?

  /// The engine owner (I10). Wired in `attachEngine(...)` once a ModelContext exists.
  weak var engineController: (any SyncEngineControlling)? {
    didSet {
      engineController?.onStatusChanged = { [weak self] in self?.recomputeSyncStatus() }
      recomputeSyncStatus()
    }
  }

  /// True once the engine is attached AND startup, including the AB-4 T1 strip, has completed.
  /// Gates send-on-enqueue so a send can never flush restored state before T1 (#286 poison).
  var isSyncReady = false

  /// Test-injectable defaults for the non-user-namespaced pre-attach delete buffer (#305).
  var bufferDefaults: UserDefaults = .standard
  private let reachabilityMonitor = NetworkReachabilityMonitor()

  // MARK: - Private State

  private var cancellables = Set<AnyCancellable>()

  // Mutations that could not be enqueued because the engine was not attached yet (#294).
  // Drained on attach so a mutation in the pre-attach window is retried instead of lost.
  private var deferredProfileSaveIds: Set<UUID> = []
  private var deferredLocationSaveIds: Set<UUID> = []
  private var deferredDeleteRecordNames: Set<String> = []
  private var deferredEmergencySave = false
  private var deferredEmergencyUnblockEvents: [String: SyncedEmergencyUnblockEvent] = [:]
  private var deferredEmergencyEpochSave = false
  private(set) var attachedUserRecordName: String?
  private var attachedModelContext: ModelContext?
  private var attachedEmergencyManager: EmergencyUnblockManager?
  private var attachedDriverFactory: ((Data?) -> SyncEngineDriver)?
  private var attachedStoreDefaults: UserDefaults = .standard
  private var didRetryAccountResolution = false
  private var accountResolutionRetryTask: Task<Void, Never>?
  // ProfileSyncManager is @MainActor; adoption coalescing state is serialized by actor isolation.
  private var isAdoptingEstablishmentGeneration = false
  private var pendingAdoptionGeneration: Int?

  private static let accountResolutionRetryDelayNanoseconds: UInt64 = 5_000_000_000

  #if DEBUG
    private(set) var didCallStartForTest = false
    private(set) var didTearDownForTest = false
    private(set) var lastReattachForceSeedForTest = false
    private(set) var establishmentAdoptionNoticeCountForTest = 0
    private(set) var reattachCountForTest = 0
    private(set) var maxConcurrentReattachCountForTest = 0
    private var concurrentReattachCountForTest = 0
    var disableAccountResolutionRetryForTest = false
    var accountResolutionRetryDelayNanosecondsForTest: UInt64?
    var failNextSwitchWipeFinalSaveForTest = false
    var failNextGenerationWipeFinalSaveForTest = false

    var isReachabilityMonitoringForTest: Bool {
      reachabilityMonitor.isMonitoringForTest
    }

    func handleReachabilityPathUpdateForTest(isSatisfied: Bool) {
      reachabilityMonitor.handlePathUpdate(isSatisfied: isSatisfied)
    }
  #endif

  /// Test seam: true when nothing is pending re-enqueue.
  var hasNoDeferredMutations: Bool {
    deferredProfileSaveIds.isEmpty && deferredLocationSaveIds.isEmpty
      && deferredDeleteRecordNames.isEmpty && !deferredEmergencySave
      && deferredEmergencyUnblockEvents.isEmpty && !deferredEmergencyEpochSave
  }

  // Device identifier for this device
  var deviceId: String {
    SharedData.deviceSyncId.uuidString
  }

  private var preAttachBufferUserRecordName: String? {
    CloudKitManager.shared.currentUserRecordID?.recordName
  }

  // MARK: - Initialization

  private init() {
    // Load enabled state from SharedData
    isEnabled = SharedData.deviceSyncEnabled
    recomputeSyncStatus()

    reachabilityMonitor.$isOnline
      .dropFirst()
      .removeDuplicates()
      .sink { [weak self] _ in self?.recomputeSyncStatus() }
      .store(in: &cancellables)
    reachabilityMonitor.onReconnect = { [weak self] in self?.reconnectDrivenSync() }
    if isEnabled { reachabilityMonitor.start() }

    // Observe changes to sync enabled setting
    $isEnabled
      .dropFirst()
      .removeDuplicates()
      .sink { [weak self] enabled in
        SharedData.deviceSyncEnabled = enabled
        self?.recomputeSyncStatus(isEnabledOverride: enabled)
        if enabled {
          self?.reachabilityMonitor.start()
          self?.startEngineAndMarkReadyWhenStartupCompletes()
        } else {
          self?.reachabilityMonitor.stop()
          self?.cancelAccountResolutionRetry()
          self?.isSyncReady = false
          self?.engineController?.stop()
        }
      }
      .store(in: &cancellables)
  }

  // MARK: - Sync Status

  enum SyncDisplayStatus: Equatable {
    case disabled
    case synced
    case waiting(Int)
    case syncing
    case offline
    case paused(SyncPausedReason)
  }

  struct SyncStatusSnapshot: Equatable {
    let status: SyncDisplayStatus
    let lastSyncDate: Date?

    var isSyncing: Bool { status == .syncing }
  }

  static func deriveStatus(
    isEnabled: Bool,
    pausedReason: SyncPausedReason?,
    isInFlight: Bool,
    isOnline: Bool,
    pendingCount: Int
  ) -> SyncDisplayStatus {
    guard isEnabled else { return .disabled }
    if let pausedReason { return .paused(pausedReason) }
    if isInFlight { return .syncing }
    if !isOnline && pendingCount > 0 { return .offline }
    if pendingCount > 0 { return .waiting(pendingCount) }
    return .synced
  }

  private var totalPendingCount: Int {
    let deferred =
      deferredProfileSaveIds.count + deferredLocationSaveIds.count
      + deferredDeleteRecordNames.count + (deferredEmergencySave ? 1 : 0)
      + deferredEmergencyUnblockEvents.count + (deferredEmergencyEpochSave ? 1 : 0)
    return (engineController?.pendingChangeCount ?? 0) + deferred
  }

  func recomputeSyncStatus(isEnabledOverride: Bool? = nil) {
    let effectiveIsEnabled = isEnabledOverride ?? isEnabled
    let status = Self.deriveStatus(
      isEnabled: effectiveIsEnabled,
      pausedReason: syncPausedReason,
      isInFlight: engineController?.isInFlight ?? false,
      isOnline: reachabilityMonitor.isOnline,
      pendingCount: totalPendingCount)
    let next = SyncStatusSnapshot(
      status: status, lastSyncDate: engineController?.lastSuccessfulSyncDate)
    if next != syncStatusSnapshot { syncStatusSnapshot = next }
  }

  enum SyncPausedReason: Equatable {
    case signedOut
    case accountChanged
  }

  struct AccountChangeConflict: Equatable {
    let newUserRecordName: String
  }

  // MARK: - Sync Errors

  enum SyncError: LocalizedError {
    case notSignedIn
    case zoneCreationFailed(Error)
    case subscriptionFailed(Error)
    case fetchFailed(Error)
    case saveFailed(Error)
    case deleteFailed(Error)
    case profileNotFound
    case syncDisabled

    var errorDescription: String? {
      switch self {
      case .notSignedIn:
        return "Please sign in to iCloud to sync profiles across devices."
      case .zoneCreationFailed(let error):
        return "Failed to set up sync: \(error.localizedDescription)"
      case .subscriptionFailed(let error):
        return "Failed to set up notifications: \(error.localizedDescription)"
      case .fetchFailed(let error):
        return "Failed to fetch synced data: \(error.localizedDescription)"
      case .saveFailed(let error):
        return "Failed to save synced data: \(error.localizedDescription)"
      case .deleteFailed(let error):
        return "Failed to delete synced data: \(error.localizedDescription)"
      case .profileNotFound:
        return "Profile not found."
      case .syncDisabled:
        return "Profile sync is disabled."
      }
    }
  }

  #if DEBUG
    private enum ProfileSyncManagerTestError: LocalizedError {
      case injectedSwitchWipeFinalSaveFailure
      case injectedGenerationWipeFinalSaveFailure

      var errorDescription: String? {
        switch self {
        case .injectedSwitchWipeFinalSaveFailure:
          return "Injected switch wipe final save failure"
        case .injectedGenerationWipeFinalSaveFailure:
          return "Injected generation wipe final save failure"
        }
      }
    }
  #endif

  // MARK: - Composition Root (I10, Phase F)

  /// Strong owner of the engine (the weak `engineController` seam points at the same object).
  private var ownedEngineController: SyncEngineController?

  /// I10 composition root: builds the per-user engine with a live ModelContext and starts
  /// it iff sync is enabled. Called once from `FoqosApp` `.onAppear`. Seams are injectable
  /// for tests; production defaults hit CloudKit for the user id and the real driver.
  func attachEngine(
    modelContext: ModelContext,
    emergencyManager: EmergencyUnblockManager,
    userRecordNameProvider: @Sendable () async -> String = ProfileSyncManager.fetchUserRecordName,
    driverFactory: ((Data?) -> SyncEngineDriver)? = nil,
    storeDefaults: UserDefaults = .standard
  ) async {
    // Idempotency is keyed on the public `engineController` facade (not the private strong
    // owner) so a test that resets `engineController` between runs (as `SyncEngineFacadeTests`
    // and `SyncEngineAttachTests` both do in tearDown/setUp) can re-attach a fresh engine;
    // in production nothing else ever nils `engineController`, so this only ever fires once.
    guard engineController == nil else { return }
    let userRecordName = await userRecordNameProvider()
    attachedModelContext = modelContext
    attachedEmergencyManager = emergencyManager
    attachedDriverFactory = driverFactory
    attachedStoreDefaults = storeDefaults
    await buildEngine(
      userRecordName: userRecordName, modelContext: modelContext, emergencyManager: emergencyManager,
      driverFactory: driverFactory, storeDefaults: storeDefaults, forceSeed: false)
  }

  private func buildEngine(
    userRecordName: String,
    modelContext: ModelContext,
    emergencyManager: EmergencyUnblockManager,
    driverFactory: ((Data?) -> SyncEngineDriver)?,
    storeDefaults: UserDefaults,
    forceSeed: Bool
  ) async {
    attachedUserRecordName = userRecordName
    let deviceId = SharedData.deviceSyncId.uuidString
    let store = SyncEngineStore(userRecordName: userRecordName, defaults: storeDefaults)
    if forceSeed { store.pendingSeedIntent = true }
    let apply = SyncApplyService(
      modelContext: modelContext, store: store, sessionController: StrategyManager.shared,
      emergencyManager: emergencyManager, deviceId: deviceId)
    let provider = RecordProvider(
      modelContext: modelContext, store: store, emergencyManager: emergencyManager, deviceId: deviceId)
    // `CKSyncEngineDriver` needs the controller itself as its delegate, but the controller
    // isn't constructed until after `factory` exists — this box breaks the cycle: it is
    // captured by reference and filled in immediately after `controller` is created, well
    // before `start()` ever invokes the factory.
    var pendingController: SyncEngineController?
    let database = privateDatabase
    let factory: (Data?) -> SyncEngineDriver =
      driverFactory ?? { engineState in
        CKSyncEngineDriver(database: database, stateSerialization: engineState, delegate: pendingController!)
      }
    let controller = SyncEngineController(
      modelContext: modelContext, store: store, driverFactory: factory,
      apply: apply, provider: provider, sessionSync: SessionSyncCacheFlusher(), deviceId: deviceId,
      wipeLocalSyncedEntitiesForGeneration: { [weak self] in
        try self?.wipeLocalSyncedEntitiesForGeneration()
        self?.attachedEmergencyManager?.clearLedgerForGenerationAdoption()
      })
    pendingController = controller
    controller.onAccountChange = { [weak self] kind in self?.handleEngineAccountChange(kind) }
    controller.onFetchedEstablishment = { [weak self] record in
      guard let establishment = SyncedEstablishment(from: record) else { return }
      Task { await self?.adoptEstablishmentGeneration(establishment.generation) }
    }
    ownedEngineController = controller
    engineController = controller
    for entry in PreAttachDeleteBuffer.pending(defaults: bufferDefaults) {
      guard entry.userRecordName == nil || entry.userRecordName == userRecordName else {
        continue
      }
      controller.recordDisabledDeleteTombstone(recordName: entry.recordName)
      PreAttachDeleteBuffer.acknowledge(
        entry.recordName, userRecordName: entry.userRecordName, defaults: bufferDefaults)
    }
    if isEnabled {
      controller.start()
      // Wait for the bounded startup sequence (I12 recovery, §5.6 retry sweep, T1 seed
      // decision) so a caller awaiting `attachEngine` observes a fully bootstrapped engine —
      // mirrors the `await controller.startupTask?.value` pattern used by the controller's
      // own tests.
      await controller.startupTask?.value
      markSyncReadyAndFlushIfStillEnabled(for: controller)
    }
  }

  /// Production user-id resolver (§7 namespace key). Falls back offline.
  static func fetchUserRecordName() async -> String {
    do {
      let id = try await CKContainer(identifier: CloudKitConstants.containerIdentifier).userRecordID()
      return id.recordName
    } catch {
      Log.warning("userRecordID unavailable, using default namespace", category: .sync)
      return CloudKitConstants.defaultUserRecordName
    }
  }

  func handleEngineAccountChange(_ kind: SyncEngineAccountChangeKind) {
    if kind == .signOut || kind == .switchAccounts {
      cancelAccountResolutionRetry()
    }

    Task { @MainActor [weak self] in
      guard let self else { return }
      let availability = await CloudKitManager.shared.accountAvailability()
      var newName: String?
      if case .available = availability {
        newName = await ProfileSyncManager.fetchUserRecordName()
      }
      self.resolveAccountChange(availability: availability, newName: newName)
    }
  }

  func resolveAccountChange(availability: AccountAvailability, newName: String?) {
    let sentinel = CloudKitConstants.defaultUserRecordName

    switch availability {
    case .noAccount:
      cancelAccountResolutionRetry()
      pauseSync(reason: .signedOut)
    case .ambiguous:
      resumeAfterAmbiguity()
    case .available:
      guard let newName, newName != sentinel,
        let attached = attachedUserRecordName, attached != sentinel
      else {
        resumeAfterAmbiguity()
        return
      }

      if newName == attached {
        cancelAccountResolutionRetry()
        clearPause()
        if let controller = engineController as? SyncEngineController {
          if controller.state == .disabled {
            if controller.hasLiveDriver {
              controller.prepareForAccountSwitch()
              #if DEBUG
                didTearDownForTest = true
              #endif
            } else {
              controller.endAccountResolution()
            }
            startEngineAndMarkReadyWhenStartupCompletes()
          } else {
            controller.endAccountResolution()
            controller.requestSync()
          }
        } else {
          engineController?.endAccountResolution()
          engineController?.requestSync()
        }
      } else {
        cancelAccountResolutionRetry()
        engineController?.prepareForAccountSwitch()
        #if DEBUG
          didTearDownForTest = true
        #endif
        isSyncReady = false
        pendingConflictName = newName
        accountChangeConflict = AccountChangeConflict(newUserRecordName: newName)
        syncPausedReason = .accountChanged
      }
    }
  }

  func reattachEngine(userRecordName: String, forceSeed: Bool) async {
    guard let modelContext = attachedModelContext,
      let emergencyManager = attachedEmergencyManager
    else { return }

    #if DEBUG
      lastReattachForceSeedForTest = forceSeed
      reattachCountForTest += 1
      concurrentReattachCountForTest += 1
      maxConcurrentReattachCountForTest = max(
        maxConcurrentReattachCountForTest, concurrentReattachCountForTest)
      defer { concurrentReattachCountForTest -= 1 }
    #endif
    engineController?.prepareForAccountSwitch()
    #if DEBUG
      didTearDownForTest = true
    #endif
    ownedEngineController = nil
    engineController = nil
    isSyncReady = false
    await buildEngine(
      userRecordName: userRecordName,
      modelContext: modelContext,
      emergencyManager: emergencyManager,
      driverFactory: attachedDriverFactory,
      storeDefaults: attachedStoreDefaults,
      forceSeed: forceSeed)
  }

  func resolveConflictSwitchToCloud() async {
    guard let conflict = accountChangeConflict else { return }
    cancelAccountResolutionRetry()
    do {
      try wipeLocalSyncedDataDirectly()
    } catch {
      attachedModelContext?.rollback()
      Log.error(
        "Account switch local wipe failed: \(error.localizedDescription)", category: .sync)
      return
    }
    await reattachEngine(userRecordName: conflict.newUserRecordName, forceSeed: false)
    clearPause()
  }

  func resolveConflictCombine() async {
    guard let conflict = accountChangeConflict else { return }
    cancelAccountResolutionRetry()
    StrategyManager.shared.clearAllRemoteSessionActive()
    await reattachEngine(userRecordName: conflict.newUserRecordName, forceSeed: true)
    clearPause()
  }

  func resolveConflictNotNow() {
    cancelAccountResolutionRetry()
    accountChangeConflict = nil
  }

  func reopenPendingAccountChangeConflict() {
    guard let pendingConflictName else { return }
    accountChangeConflict = AccountChangeConflict(newUserRecordName: pendingConflictName)
  }

  private func wipeLocalSyncedDataDirectly(cleanup: BlockedProfiles.DeleteCleanup? = nil) throws {
    guard let context = attachedModelContext else { throw SyncError.syncDisabled }

    let profiles = try context.fetch(FetchDescriptor<BlockedProfiles>())
    StrategyManager.shared.forceClearEnforcementForSyncedDataWipe(context: context)
    for profile in profiles {
      try BlockedProfiles.deleteProfile(profile, in: context, cleanup: cleanup)
    }

    let locations = try context.fetch(FetchDescriptor<SavedLocation>())
    for location in locations {
      try SavedLocation.delete(location, in: context)
    }

    #if DEBUG
      if failNextSwitchWipeFinalSaveForTest {
        failNextSwitchWipeFinalSaveForTest = false
        throw SyncError.deleteFailed(ProfileSyncManagerTestError.injectedSwitchWipeFinalSaveFailure)
      }
    #endif

    try context.save()
    attachedEmergencyManager?.resetAllStateForAccountSwitch()
  }

  func wipeLocalSyncedEntitiesForGeneration(
    cleanup: BlockedProfiles.DeleteCleanup? = nil,
    stopRemoteSession: (ModelContext, UUID) -> Void = { context, profileId in
      StrategyManager.shared.stopRemoteSession(context: context, profileId: profileId)
    },
    clearResidualEnforcement: (ModelContext) -> Void = { context in
      StrategyManager.shared.forceClearEnforcementForSyncedDataWipe(context: context)
    },
    endLiveActivity: () -> Void = {
      LiveActivityManager.shared.endSessionActivity()
    }
  ) throws {
    guard let context = attachedModelContext else { throw SyncError.syncDisabled }

    let profiles = try context.fetch(FetchDescriptor<BlockedProfiles>())
    for profile in profiles {
      stopRemoteSession(context, profile.id)
    }
    clearResidualEnforcement(context)
    endLiveActivity()

    for profile in profiles {
      try BlockedProfiles.deleteProfile(profile, in: context, cleanup: cleanup)
    }

    let locations = try context.fetch(FetchDescriptor<SavedLocation>())
    for location in locations {
      try SavedLocation.delete(location, in: context)
    }

    #if DEBUG
      if failNextGenerationWipeFinalSaveForTest {
        failNextGenerationWipeFinalSaveForTest = false
        throw SyncError.deleteFailed(ProfileSyncManagerTestError.injectedGenerationWipeFinalSaveFailure)
      }
    #endif

    try context.save()
  }

  func adoptEstablishmentGeneration(_ newGeneration: Int) async {
    guard let userRecordName = attachedUserRecordName else { return }
    let store = SyncEngineStore(userRecordName: userRecordName, defaults: attachedStoreDefaults)
    guard newGeneration > store.establishmentGeneration else { return }

    engineController?.cancelDeletingWipeForEstablishmentAdoption()

    if isAdoptingEstablishmentGeneration {
      pendingAdoptionGeneration = max(pendingAdoptionGeneration ?? newGeneration, newGeneration)
      return
    }

    isAdoptingEstablishmentGeneration = true
    defer { isAdoptingEstablishmentGeneration = false }
    var targetGeneration = newGeneration
    var didAdoptGeneration = false

    while targetGeneration > store.establishmentGeneration {
      do {
        try wipeLocalSyncedEntitiesForGeneration()
      } catch {
        attachedModelContext?.rollback()
        Log.error(
          "Establishment generation adoption local wipe failed: \(error.localizedDescription)",
          category: .sync)
        break
      }

      store.transaction { s in
        s.clearGenerationScopedBookkeeping()
        s.establishmentGeneration = targetGeneration
        s.engineState = nil
      }
      didAdoptGeneration = true
      attachedEmergencyManager?.clearLedgerForGenerationAdoption()

      await reattachEngine(userRecordName: userRecordName, forceSeed: false)

      if let pending = pendingAdoptionGeneration, pending > store.establishmentGeneration {
        pendingAdoptionGeneration = nil
        targetGeneration = pending
      } else {
        pendingAdoptionGeneration = nil
        break
      }
    }

    if didAdoptGeneration {
      #if DEBUG
        establishmentAdoptionNoticeCountForTest += 1
      #endif
      NotificationCenter.default.post(name: .syncEstablishmentGenerationAdopted, object: nil)
    }
  }

  private func pauseSync(reason: SyncPausedReason) {
    isSyncReady = false
    engineController?.prepareForAccountSwitch()
    #if DEBUG
      didTearDownForTest = true
    #endif
    syncPausedReason = reason
    recomputeSyncStatus()
  }

  private func clearPause() {
    syncPausedReason = nil
    accountChangeConflict = nil
    pendingConflictName = nil
    recomputeSyncStatus()
  }

  private func cancelAccountResolutionRetry() {
    accountResolutionRetryTask?.cancel()
    accountResolutionRetryTask = nil
    didRetryAccountResolution = false
  }

  private func reconnectDrivenSync() {
    guard isEnabled, isSyncReady else {
      recomputeSyncStatus()
      return
    }
    do {
      try syncNow()
    } catch {
      Log.warning("reconnect syncNow skipped: \(error.localizedDescription)", category: .sync)
    }
    recomputeSyncStatus()
  }

  private func resumeAfterAmbiguity() {
    engineController?.endAccountResolution()
    engineController?.requestSync()
    scheduleAccountResolutionRetry()
  }

  private func scheduleAccountResolutionRetry() {
    guard !didRetryAccountResolution else { return }
    #if DEBUG
      guard !disableAccountResolutionRetryForTest else { return }
    #endif
    didRetryAccountResolution = true
    let delay: UInt64
    #if DEBUG
      delay =
        accountResolutionRetryDelayNanosecondsForTest
        ?? ProfileSyncManager.accountResolutionRetryDelayNanoseconds
    #else
      delay = ProfileSyncManager.accountResolutionRetryDelayNanoseconds
    #endif
    accountResolutionRetryTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(nanoseconds: delay)
      } catch {
        self?.accountResolutionRetryTask = nil
        return
      }
      guard let self else { return }
      guard self.isEnabled else {
        self.accountResolutionRetryTask = nil
        return
      }
      self.accountResolutionRetryTask = nil
      self.handleEngineAccountChange(.signIn)
    }
  }

  #if DEBUG
    var hasAccountResolutionRetryTaskForTest: Bool {
      accountResolutionRetryTask != nil
    }

    func resetAccountChangeDebugCountersForTest() {
      didCallStartForTest = false
      didTearDownForTest = false
      lastReattachForceSeedForTest = false
      establishmentAdoptionNoticeCountForTest = 0
      reattachCountForTest = 0
      maxConcurrentReattachCountForTest = 0
      concurrentReattachCountForTest = 0
      cancelAccountResolutionRetry()
      disableAccountResolutionRetryForTest = true
      accountResolutionRetryDelayNanosecondsForTest = nil
      failNextSwitchWipeFinalSaveForTest = false
      failNextGenerationWipeFinalSaveForTest = false
    }

    func clearAccountChangeStateForTest() {
      cancelAccountResolutionRetry()
      syncPausedReason = nil
      accountChangeConflict = nil
      pendingConflictName = nil
      attachedUserRecordName = nil
      attachedModelContext = nil
      attachedEmergencyManager = nil
      attachedDriverFactory = nil
      attachedStoreDefaults = .standard
      didCallStartForTest = false
      didTearDownForTest = false
      lastReattachForceSeedForTest = false
      establishmentAdoptionNoticeCountForTest = 0
      reattachCountForTest = 0
      maxConcurrentReattachCountForTest = 0
      concurrentReattachCountForTest = 0
      disableAccountResolutionRetryForTest = false
      accountResolutionRetryDelayNanosecondsForTest = nil
      failNextSwitchWipeFinalSaveForTest = false
      failNextGenerationWipeFinalSaveForTest = false
    }

    func makeAttachedEngineStateRestorerForTest() -> () -> Void {
      let userRecordName = attachedUserRecordName
      let modelContext = attachedModelContext
      let emergencyManager = attachedEmergencyManager
      let driverFactory = attachedDriverFactory
      let storeDefaults = attachedStoreDefaults
      return { [weak self] in
        self?.attachedUserRecordName = userRecordName
        self?.attachedModelContext = modelContext
        self?.attachedEmergencyManager = emergencyManager
        self?.attachedDriverFactory = driverFactory
        self?.attachedStoreDefaults = storeDefaults
      }
    }

    func wipeAndReattachForTest(cleanup: BlockedProfiles.DeleteCleanup, newName: String) async throws {
      try wipeLocalSyncedDataDirectly(cleanup: cleanup)
      await reattachEngine(userRecordName: newName, forceSeed: false)
      clearPause()
    }
  #endif

  // MARK: - Engine facade (Phase F)

  /// Manual "Sync Now" — schedules a fetch+send on the engine (replaces performFullSync).
  /// Throws `SyncEngineControllingError.notAttached` instead of silently no-op'ing when the
  /// engine hasn't attached yet (review finding #2) so the caller can surface it.
  func syncNow() throws {
    guard let engineController else { throw SyncEngineControllingError.notAttached }
    engineController.requestSync()
  }

  /// Reset Sync (§8.1). Delegates to the origin reset state machine. Throws
  /// `SyncEngineControllingError.notAttached` instead of silently no-op'ing when the engine
  /// hasn't attached yet (review finding #3) so the caller can surface it.
  func resetSync(clearRemoteAppSelections: Bool) throws {
    try resetSync(wipe: false, clearRemoteAppSelections: clearRemoteAppSelections)
  }

  func resetSync(wipe: Bool, clearRemoteAppSelections: Bool) throws {
    guard let engineController else { throw SyncEngineControllingError.notAttached }
    engineController.beginReset(wipe: wipe, clearRemoteAppSelections: clearRemoteAppSelections)
  }

  /// Every verb below throws `SyncEngineControllingError.notAttached` when `engineController`
  /// is nil (rather than silently no-op'ing) and otherwise propagates whatever the engine
  /// itself throws (review findings #4–#6, #15). Delete call sites MUST fall back to a direct
  /// local delete on `.notAttached` so the item is never silently left behind.
  func enqueueProfileSave(_ id: UUID) throws {
    defer { recomputeSyncStatus() }
    guard let engineController else {
      deferredProfileSaveIds.insert(id)
      throw SyncEngineControllingError.notAttached
    }
    do {
      try engineController.enqueueProfileSave(id)
    } catch SyncEngineControllingError.notAttached {
      deferredProfileSaveIds.insert(id)
      throw SyncEngineControllingError.notAttached
    }
    if isSyncReady { engineController.requestSync() }
  }
  func enqueueProfileDelete(_ id: UUID) throws {
    defer { recomputeSyncStatus() }
    guard let engineController else {
      deferredDeleteRecordNames.insert(id.uuidString)
      PreAttachDeleteBuffer.add(
        id.uuidString, userRecordName: preAttachBufferUserRecordName, defaults: bufferDefaults)
      throw SyncEngineControllingError.notAttached
    }
    do {
      try engineController.enqueueProfileDelete(id, requestSyncAfterPendingDelete: isSyncReady)
    } catch SyncEngineControllingError.notAttached {
      deferredDeleteRecordNames.insert(id.uuidString)
      PreAttachDeleteBuffer.add(
        id.uuidString, userRecordName: preAttachBufferUserRecordName, defaults: bufferDefaults)
      throw SyncEngineControllingError.notAttached
    }
  }
  func enqueueLocationSave(_ id: UUID) throws {
    defer { recomputeSyncStatus() }
    guard let engineController else {
      deferredLocationSaveIds.insert(id)
      throw SyncEngineControllingError.notAttached
    }
    do {
      try engineController.enqueueLocationSave(id)
    } catch SyncEngineControllingError.notAttached {
      deferredLocationSaveIds.insert(id)
      throw SyncEngineControllingError.notAttached
    }
    if isSyncReady { engineController.requestSync() }
  }
  func enqueueLocationDelete(_ id: UUID) throws {
    defer { recomputeSyncStatus() }
    guard let engineController else {
      deferredDeleteRecordNames.insert(id.uuidString)
      PreAttachDeleteBuffer.add(
        id.uuidString, userRecordName: preAttachBufferUserRecordName, defaults: bufferDefaults)
      throw SyncEngineControllingError.notAttached
    }
    do {
      try engineController.enqueueLocationDelete(id)
    } catch SyncEngineControllingError.notAttached {
      deferredDeleteRecordNames.insert(id.uuidString)
      PreAttachDeleteBuffer.add(
        id.uuidString, userRecordName: preAttachBufferUserRecordName, defaults: bufferDefaults)
      throw SyncEngineControllingError.notAttached
    }
    if isSyncReady { engineController.requestSync() }
  }
  func enqueueEmergencySettingsSave() throws {
    defer { recomputeSyncStatus() }
    guard let engineController else {
      deferredEmergencySave = true
      throw SyncEngineControllingError.notAttached
    }
    do {
      try engineController.enqueueEmergencySettingsSave()
    } catch SyncEngineControllingError.notAttached {
      deferredEmergencySave = true
      throw SyncEngineControllingError.notAttached
    }
    if isSyncReady { engineController.requestSync() }
  }
  func enqueueEmergencyUnblockEvent(_ event: SyncedEmergencyUnblockEvent) throws {
    defer { recomputeSyncStatus() }
    guard let engineController else {
      deferredEmergencyUnblockEvents[event.recordName] = event
      throw SyncEngineControllingError.notAttached
    }
    do {
      try engineController.enqueueEmergencyUnblockEvent(event)
    } catch SyncEngineControllingError.notAttached {
      deferredEmergencyUnblockEvents[event.recordName] = event
      throw SyncEngineControllingError.notAttached
    }
    if isSyncReady { engineController.requestSync() }
  }
  func enqueueEmergencyEpochSave() throws {
    defer { recomputeSyncStatus() }
    guard let engineController else {
      deferredEmergencyEpochSave = true
      throw SyncEngineControllingError.notAttached
    }
    do {
      try engineController.enqueueEmergencyEpochSave()
    } catch SyncEngineControllingError.notAttached {
      deferredEmergencyEpochSave = true
      throw SyncEngineControllingError.notAttached
    }
    if isSyncReady { engineController.requestSync() }
  }
  func enqueueEmergencyUnblockEventDelete(_ recordName: String) throws {
    defer { recomputeSyncStatus() }
    guard let engineController else {
      deferredDeleteRecordNames.insert(recordName)
      PreAttachDeleteBuffer.add(
        recordName, userRecordName: preAttachBufferUserRecordName, defaults: bufferDefaults)
      throw SyncEngineControllingError.notAttached
    }
    do {
      try engineController.enqueueEmergencyUnblockEventDelete(recordName)
    } catch SyncEngineControllingError.notAttached {
      deferredDeleteRecordNames.insert(recordName)
      PreAttachDeleteBuffer.add(
        recordName, userRecordName: preAttachBufferUserRecordName, defaults: bufferDefaults)
      throw SyncEngineControllingError.notAttached
    }
    if isSyncReady { engineController.requestSync() }
  }

  /// Records a disabled-sync delete after its local commit so I12 can replay it on re-enable.
  /// Best-effort because the caller is already on a committed local-delete path.
  func recordDisabledDeleteTombstone(recordName: String) {
    guard let engineController else {
      PreAttachDeleteBuffer.add(
        recordName, userRecordName: preAttachBufferUserRecordName, defaults: bufferDefaults)
      Log.info("Disabled-delete tombstone buffered pre-attach (\(recordName))", category: .sync)
      return
    }
    engineController.recordDisabledDeleteTombstone(recordName: recordName)
  }

  /// Replay save-type mutations deferred while the engine was unattached (#294). Uses the
  /// controller-level enqueue verbs (which do not themselves send), so the single requestSync
  /// in `markSyncReadyAndFlush()` flushes them all at once.
  private func drainDeferredMutations() {
    guard let engineController else { return }
    // #221 deferred safety: epoch saves are max-merged, event saves are write-once/idempotent
    // by recordName, and GC deletes drain through the existing tombstone path. These operations
    // need no sequencing guarantee relative to each other or to a fetched remote epoch.
    for id in deferredProfileSaveIds { try? engineController.enqueueProfileSave(id) }
    for id in deferredLocationSaveIds { try? engineController.enqueueLocationSave(id) }
    for name in deferredDeleteRecordNames { engineController.enqueueDeferredDelete(recordName: name) }
    if deferredEmergencySave { try? engineController.enqueueEmergencySettingsSave() }
    for name in deferredEmergencyUnblockEvents.keys.sorted() {
      if let event = deferredEmergencyUnblockEvents[name] {
        try? engineController.enqueueEmergencyUnblockEvent(event)
      }
    }
    if deferredEmergencyEpochSave { try? engineController.enqueueEmergencyEpochSave() }
    deferredProfileSaveIds.removeAll()
    deferredLocationSaveIds.removeAll()
    deferredDeleteRecordNames.removeAll()
    deferredEmergencySave = false
    deferredEmergencyUnblockEvents.removeAll()
    deferredEmergencyEpochSave = false
  }

  /// Called once the engine is attached AND startup, including the AB-4 T1 strip, has completed.
  /// Enables prompt sends and flushes anything enqueued while not ready, always post-T1.
  func markSyncReadyAndFlush() {
    isSyncReady = true
    drainDeferredMutations()
    recomputeSyncStatus()
    Log.debug("Sync ready; flushing deferred mutations", category: .sync)
    engineController?.requestSync()
  }

  /// Starts an already-attached engine after the user enables sync, then marks ready only
  /// after startup has completed. The ready mark is guarded so a concurrent disable cannot
  /// flush or leave sync marked ready after the engine has been stopped.
  private func startEngineAndMarkReadyWhenStartupCompletes() {
    guard let engineController else { return }
    isSyncReady = false
    #if DEBUG
      didCallStartForTest = true
    #endif
    engineController.start()
    guard let controller = engineController as? SyncEngineController else { return }
    Task { @MainActor [weak self, weak controller] in
      await controller?.startupTask?.value
      guard let controller else { return }
      self?.markSyncReadyAndFlushIfStillEnabled(for: controller)
    }
  }

  /// Complete startup only if sync is still enabled and the same attached controller is current.
  func markSyncReadyAndFlushIfStillEnabled(for controller: any SyncEngineControlling) {
    guard isEnabled, let engineController, engineController === controller else { return }
    markSyncReadyAndFlush()
  }
}
