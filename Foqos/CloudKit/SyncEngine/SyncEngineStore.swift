import FoqosShared
import Foundation

/// Origin reset intent (§2.1). Crash-resumable via `stage`.
struct ResetIntent: Codable, Equatable {
  var id: UUID
  var clear: Bool
  enum Stage: String, Codable { case deleting, recreating, seeding }
  var stage: Stage
  var priorCommandId: UUID?
}

/// A thrown apply persisted for §5.6 retry.
struct FailedApply: Codable, Hashable {
  var recordName: String
  var recordType: String  // CKRecord.RecordType raw
  enum Op: String, Codable { case upsert, delete }
  var op: Op
}

/// Per-userRecordID persisted state for the sync engine (§2.1, §7). All keys are
/// namespaced `family_foqos_syncengine_<field>_<userRecordName>` (legacyCleanupDone is
/// the one exception — it reuses the pre-existing key, Task 6). Compound read-modify-writes
/// run under `SharedData.withLock`; `transaction` is the single-lock batch (Task 6).
@MainActor
final class SyncEngineStore {
  private let userRecordName: String
  private let defaults: UserDefaults
  private var inTransaction = false

  init(userRecordName: String, defaults: UserDefaults = .standard) {
    self.userRecordName = userRecordName
    self.defaults = defaults
  }

  // MARK: - Key namespacing (§7)

  private func key(_ field: String) -> String {
    "family_foqos_syncengine_\(field)_\(userRecordName)"
  }

  // MARK: - Non-reentrant compound-write lock

  /// Run a compound read-modify-write under the process-wide lock. When already inside
  /// a `transaction` the body runs directly — `SharedData.withLock` is non-reentrant.
  private func locked(_ body: () -> Void) {
    if inTransaction {
      body()
      return
    }
    SharedData.withLock { body() }
  }

  // MARK: - Codable helpers

  private func decoded<T: Decodable>(_ type: T.Type, _ field: String) -> T? {
    guard let data = defaults.data(forKey: key(field)) else { return nil }
    return try? JSONDecoder().decode(T.self, from: data)
  }

  private func encodeStore<T: Encodable>(_ value: T, _ field: String) {
    guard let data = try? JSONEncoder().encode(value) else { return }
    defaults.set(data, forKey: key(field))
  }

  // MARK: - Engine state (§2.1 engineState)

  var engineState: Data? {
    get { defaults.data(forKey: key("engine_state")) }
    set {
      if let newValue {
        defaults.set(newValue, forKey: key("engine_state"))
      } else {
        defaults.removeObject(forKey: key("engine_state"))
      }
    }
  }

  // MARK: - System-fields cache (§2.1 systemFields — scoped types only)

  private var systemFieldsMap: [String: Data] {
    decoded([String: Data].self, "system_fields") ?? [:]
  }

  func systemFields(for recordName: String) -> Data? {
    systemFieldsMap[recordName]
  }

  func setSystemFields(_ data: Data?, for recordName: String) {
    locked {
      var all = self.systemFieldsMap
      if let data {
        all[recordName] = data
      } else {
        all.removeValue(forKey: recordName)
      }
      self.encodeStore(all, "system_fields")
    }
  }

  /// I6: zone events purge the change-tag cache (not data/tombstones/processed ids).
  func purgeAllSystemFields() {
    locked { self.defaults.removeObject(forKey: self.key("system_fields")) }
  }

  // MARK: - Reset-command idempotency (§2.1 — never pruned, I3/C-6)

  var processedResetCommandIds: Set<UUID> {
    decoded(Set<UUID>.self, "processed_reset_ids") ?? []
  }

  func markProcessed(_ id: UUID) {
    locked {
      var all = self.processedResetCommandIds
      all.insert(id)
      self.encodeStore(all, "processed_reset_ids")
    }
  }

  var lastAppliedResetCommandId: UUID? {
    get { decoded(UUID.self, "last_applied_reset_id") }
    set {
      if let newValue {
        encodeStore(newValue, "last_applied_reset_id")
      } else {
        defaults.removeObject(forKey: key("last_applied_reset_id"))
      }
    }
  }

  // MARK: - Intents (§2.1)

  var resetIntent: ResetIntent? {
    get { decoded(ResetIntent.self, "reset_intent") }
    set {
      if let newValue {
        encodeStore(newValue, "reset_intent")
      } else {
        defaults.removeObject(forKey: key("reset_intent"))
      }
    }
  }

  var pendingSeedIntent: Bool {
    get { defaults.bool(forKey: key("pending_seed_intent")) }
    set { defaults.set(newValue, forKey: key("pending_seed_intent")) }
  }

  var establishmentGeneration: Int {
    get { defaults.integer(forKey: key("establishment_generation")) }
    set { locked { self.defaults.set(newValue, forKey: self.key("establishment_generation")) } }
  }

  // MARK: - Delete tombstones (§2.1 deleteTombstones, I12)

  private struct TombstoneEntry: Codable {
    var recordName: String
    var changeTag: String?
  }

  private var tombstoneEntries: [TombstoneEntry] {
    decoded([TombstoneEntry].self, "delete_tombstones") ?? []
  }

  var deleteTombstones: [String: String?] {
    var result: [String: String?] = [:]
    for entry in tombstoneEntries {
      result[entry.recordName] = entry.changeTag  // key present; value may be nil
    }
    return result
  }

  func setTombstone(recordName: String, changeTag: String?) {
    locked {
      var all = self.tombstoneEntries.filter { $0.recordName != recordName }
      all.append(TombstoneEntry(recordName: recordName, changeTag: changeTag))
      self.encodeStore(all, "delete_tombstones")
    }
  }

  func clearTombstone(recordName: String) {
    locked {
      let all = self.tombstoneEntries.filter { $0.recordName != recordName }
      self.encodeStore(all, "delete_tombstones")
    }
  }

  // MARK: - Delete version watermark (#315)

  /// Guard value captured at delete time: `Double(syncVersion)` for profiles,
  /// `updatedAt.timeIntervalSinceReferenceDate` for locations. Unlike the I12 tombstone, this
  /// survives confirmation to gate locally-absent create branches against stale delete echoes.
  static let deleteWatermarkWarningThreshold = 512

  private struct DeleteWatermarkEntry: Codable {
    var recordName: String
    var value: Double
  }

  private var deleteWatermarkEntries: [DeleteWatermarkEntry] {
    decoded([DeleteWatermarkEntry].self, "delete_watermarks") ?? []
  }

  func deleteWatermark(for recordName: String) -> Double? {
    deleteWatermarkEntries.first { $0.recordName == recordName }?.value
  }

  func setDeleteWatermark(recordName: String, value: Double) {
    locked {
      var all = self.deleteWatermarkEntries.filter { $0.recordName != recordName }
      all.append(DeleteWatermarkEntry(recordName: recordName, value: value))
      if all.count > Self.deleteWatermarkWarningThreshold {
        Log.warning(
          "Delete watermark count \(all.count) exceeds telemetry threshold "
            + "\(Self.deleteWatermarkWarningThreshold)",
          category: .sync)
      }
      self.encodeStore(all, "delete_watermarks")
    }
  }

  func clearDeleteWatermark(recordName: String) {
    locked {
      let all = self.deleteWatermarkEntries.filter { $0.recordName != recordName }
      self.encodeStore(all, "delete_watermarks")
    }
  }

  // MARK: - Failed applies (§2.1 failedApplies, §5.6)

  var failedApplies: Set<FailedApply> {
    decoded(Set<FailedApply>.self, "failed_applies") ?? []
  }

  func addFailedApply(_ entry: FailedApply) {
    locked {
      var all = self.failedApplies
      all.insert(entry)
      self.encodeStore(all, "failed_applies")
    }
  }

  /// Supersession: a later successful apply for a recordName clears its entry (§5.6),
  /// regardless of op — clear by name.
  func removeFailedApply(recordName: String) {
    locked {
      let all = self.failedApplies.filter { $0.recordName != recordName }
      self.encodeStore(all, "failed_applies")
    }
  }

  func clearGenerationScopedBookkeeping() {
    locked {
      self.defaults.removeObject(forKey: self.key("system_fields"))
      self.defaults.removeObject(forKey: self.key("delete_tombstones"))
      self.defaults.removeObject(forKey: self.key("delete_watermarks"))
      self.defaults.removeObject(forKey: self.key("failed_applies"))
    }
  }

  // MARK: - Legacy cleanup one-shot (§2.1, §11)

  /// Reuses the pre-existing per-user key `family_foqos_legacy_session_cleanup_complete_<user>`.
  private func legacyCleanupDoneKey() -> String {
    "family_foqos_legacy_session_cleanup_complete_\(userRecordName)"
  }

  var legacyCleanupDone: Bool {
    get { defaults.bool(forKey: legacyCleanupDoneKey()) }
    set { defaults.set(newValue, forKey: legacyCleanupDoneKey()) }
  }

  var legacyCleanupIds: Set<String> {
    decoded(Set<String>.self, "legacy_cleanup_ids") ?? []
  }

  func addLegacyCleanupIds(_ ids: Set<String>) {
    locked {
      var all = self.legacyCleanupIds
      all.formUnion(ids)
      self.encodeStore(all, "legacy_cleanup_ids")
    }
  }

  func removeLegacyCleanupId(_ id: String) {
    locked {
      var all = self.legacyCleanupIds
      all.remove(id)
      self.encodeStore(all, "legacy_cleanup_ids")
    }
  }

  // MARK: - Compound transaction (single withLock — never nest)

  /// Runs `body` under one `SharedData.withLock`; individual mutators called inside
  /// detect `inTransaction` and skip re-locking (the primitive is non-reentrant).
  func transaction(_ body: (SyncEngineStore) -> Void) {
    SharedData.withLock {
      self.inTransaction = true
      defer { self.inTransaction = false }
      body(self)
    }
  }
}
