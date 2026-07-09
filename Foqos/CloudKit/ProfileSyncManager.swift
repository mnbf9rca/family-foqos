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
  @Published var isSyncing: Bool = false
  @Published var syncStatus: SyncStatus = .disabled
  @Published var connectedDeviceCount: Int = 0
  @Published var lastSyncDate: Date?
  @Published var error: SyncError?
  /// Set to true when legacy records were cleaned up and user should be notified
  @Published var shouldShowSyncUpgradeNotice = false

  /// The engine owner (I10). Wired in `attachEngine(...)` once a ModelContext exists.
  weak var engineController: (any SyncEngineControlling)?

  /// True once the engine is attached AND startup, including the AB-4 T1 strip, has completed.
  /// Gates send-on-enqueue so a send can never flush restored state before T1 (#286 poison).
  var isSyncReady = false

  // MARK: - Private State

  private var cancellables = Set<AnyCancellable>()

  // Mutations that could not be enqueued because the engine was not attached yet (#294).
  // Drained on attach so a mutation in the pre-attach window is retried instead of lost.
  private var deferredProfileSaveIds: Set<UUID> = []
  private var deferredLocationSaveIds: Set<UUID> = []
  private var deferredDeleteRecordNames: Set<String> = []
  private var deferredEmergencySave = false

  /// Test seam: true when nothing is pending re-enqueue.
  var hasNoDeferredMutations: Bool {
    deferredProfileSaveIds.isEmpty && deferredLocationSaveIds.isEmpty
      && deferredDeleteRecordNames.isEmpty && !deferredEmergencySave
  }

  // Device identifier for this device
  var deviceId: String {
    SharedData.deviceSyncId.uuidString
  }

  // MARK: - Initialization

  private init() {
    // Load enabled state from SharedData
    isEnabled = SharedData.deviceSyncEnabled
    syncStatus = isEnabled ? .idle : .disabled

    // Observe changes to sync enabled setting
    $isEnabled
      .dropFirst()
      .removeDuplicates()
      .sink { [weak self] enabled in
        SharedData.deviceSyncEnabled = enabled
        self?.syncStatus = enabled ? .idle : .disabled
        if enabled {
          self?.engineController?.start()
        } else {
          self?.isSyncReady = false
          self?.engineController?.stop()
        }
      }
      .store(in: &cancellables)
  }

  // MARK: - Sync Status

  enum SyncStatus: Equatable {
    case disabled
    case idle
    case syncing
    case error(String)

    var displayText: String {
      switch self {
      case .disabled:
        return "Disabled"
      case .idle:
        return "Synced"
      case .syncing:
        return "Syncing..."
      case .error(let message):
        return "Error: \(message)"
      }
    }
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
    driverFactory: ((Data?) -> SyncEngineDriver)? = nil
  ) async {
    // Idempotency is keyed on the public `engineController` facade (not the private strong
    // owner) so a test that resets `engineController` between runs (as `SyncEngineFacadeTests`
    // and `SyncEngineAttachTests` both do in tearDown/setUp) can re-attach a fresh engine;
    // in production nothing else ever nils `engineController`, so this only ever fires once.
    guard engineController == nil else { return }
    let userRecordName = await userRecordNameProvider()
    let deviceId = SharedData.deviceSyncId.uuidString
    let store = SyncEngineStore(userRecordName: userRecordName)
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
      apply: apply, provider: provider, sessionSync: SessionSyncCacheFlusher(), deviceId: deviceId)
    pendingController = controller
    ownedEngineController = controller
    engineController = controller
    if isEnabled {
      controller.start()
      // Wait for the bounded startup sequence (I12 recovery, §5.6 retry sweep, T1 seed
      // decision) so a caller awaiting `attachEngine` observes a fully bootstrapped engine —
      // mirrors the `await controller.startupTask?.value` pattern used by the controller's
      // own tests.
      await controller.startupTask?.value
      markSyncReadyAndFlush()
    }
  }

  /// Production user-id resolver (§7 namespace key). Falls back offline.
  static func fetchUserRecordName() async -> String {
    do {
      let id = try await CKContainer(identifier: CloudKitConstants.containerIdentifier).userRecordID()
      return id.recordName
    } catch {
      Log.warning("userRecordID unavailable, using default namespace", category: .sync)
      return "__default_user__"
    }
  }

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
    guard let engineController else { throw SyncEngineControllingError.notAttached }
    engineController.beginReset(clearRemoteAppSelections: clearRemoteAppSelections)
  }

  /// Every verb below throws `SyncEngineControllingError.notAttached` when `engineController`
  /// is nil (rather than silently no-op'ing) and otherwise propagates whatever the engine
  /// itself throws (review findings #4–#6, #15). Delete call sites MUST fall back to a direct
  /// local delete on `.notAttached` so the item is never silently left behind.
  func enqueueProfileSave(_ id: UUID) throws {
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
    guard let engineController else { throw SyncEngineControllingError.notAttached }
    try engineController.enqueueProfileDelete(id)
    if isSyncReady { engineController.requestSync() }
  }
  func enqueueLocationSave(_ id: UUID) throws {
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
    guard let engineController else { throw SyncEngineControllingError.notAttached }
    try engineController.enqueueLocationDelete(id)
    if isSyncReady { engineController.requestSync() }
  }
  func enqueueEmergencySettingsSave() throws {
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

  /// Replay save-type mutations deferred while the engine was unattached (#294). Uses the
  /// controller-level enqueue verbs (which do not themselves send), so the single requestSync
  /// in `markSyncReadyAndFlush()` flushes them all at once.
  private func drainDeferredMutations() {
    guard let engineController else { return }
    for id in deferredProfileSaveIds { try? engineController.enqueueProfileSave(id) }
    for id in deferredLocationSaveIds { try? engineController.enqueueLocationSave(id) }
    if deferredEmergencySave { try? engineController.enqueueEmergencySettingsSave() }
    deferredProfileSaveIds.removeAll()
    deferredLocationSaveIds.removeAll()
    deferredEmergencySave = false
  }

  /// Called once the engine is attached AND startup, including the AB-4 T1 strip, has completed.
  /// Enables prompt sends and flushes anything enqueued while not ready, always post-T1.
  func markSyncReadyAndFlush() {
    isSyncReady = true
    drainDeferredMutations()
    engineController?.requestSync()
  }
}
