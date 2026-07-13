import CloudKit
import Foundation
import SwiftData

/// Inbound apply (§5.1/§5.2): routes fetched modifications/deletions by recordType and reuses
/// SyncCoordinator's merge semantics (I9 gate + E-1 + N6) minus deletion reconciliation and the
/// own-origin apply skip. Not wired into any engine in Phase B.
@MainActor
final class SyncApplyService {
  enum ApplyOutcome { case applied, skippedPendingDelete, skippedStaleDelete, ignored, failed }
  enum DeletionOutcome { case deleted, notPresent, ignored }

  private let modelContext: ModelContext
  private let store: SyncEngineStore
  private let sessionController: SessionController
  private let emergencyManager: EmergencyUnblockManager
  private let deviceId: String
  private let scheduleProfileDeleteCommit: (@escaping @MainActor () -> Void) -> Void
  private var zoneID: CKRecordZone.ID {
    CKRecordZone.ID(zoneName: CloudKitConstants.syncZoneName, ownerName: CKCurrentUserDefaultName)
  }

  /// In-memory confirmed-delete echo guard (§5.1). Populated by the controller on §5.3 confirmation.
  var recentlyConfirmedDeletes: Set<String> = []

  /// Record IDs the controller must re-enqueue as `.saveRecord` (I2 exceptions:
  /// I9 older-schema auto-heal, §5.1 equal-version divergence).
  private(set) var pendingReenqueues: [CKRecord.ID] = []

  /// Test seam: overrides the durable save so §5.1 rollback (S-30) is exercisable.
  var saveOverride: (() throws -> Void)?

  /// Called only after a deferred remote profile delete has been durably committed.
  var profileDeleteCommitObserver: ((String) -> Void)?

  init(
    modelContext: ModelContext,
    store: SyncEngineStore,
    sessionController: SessionController,
    emergencyManager: EmergencyUnblockManager,
    deviceId: String,
    scheduleProfileDeleteCommit: @escaping (@escaping @MainActor () -> Void) -> Void =
      BlockedProfiles.scheduleProfileDeleteCommit
  ) {
    self.modelContext = modelContext
    self.store = store
    self.sessionController = sessionController
    self.emergencyManager = emergencyManager
    self.deviceId = deviceId
    self.scheduleProfileDeleteCommit = scheduleProfileDeleteCommit
  }

  func drainReenqueues() -> [CKRecord.ID] {
    let ids = pendingReenqueues
    pendingReenqueues.removeAll()
    return ids
  }

  // MARK: - Fetched modifications (§5.1)

  func applyFetchedModification(
    _ record: CKRecord, isPendingDeleteOrTombstoned: (String) -> Bool
  ) -> ApplyOutcome {
    let recordName = record.recordID.recordName
    // Pending-delete-wins (§5.1): a modification shadowed by a pending delete, a live
    // tombstone, or the in-memory confirmed-delete echo guard is skipped.
    if isPendingDeleteOrTombstoned(recordName) || recentlyConfirmedDeletes.contains(recordName) {
      SyncDiagnostics.modificationSkippedPendingDelete(
        recordType: record.recordType, recordName: recordName)
      return .skippedPendingDelete
    }
    switch record.recordType {
    case SyncedProfile.recordType:
      return applyProfileModification(record)
    case SyncedLocation.recordType:
      return applyLocationModification(record)
    case SyncedEmergencySettings.recordType:
      return applyEmergencyModification(record)
    case SyncedEmergencyUnblockEvent.recordType:
      return applyUnblockEventModification(record)
    case SyncedEmergencyEpoch.recordType:
      return applyEmergencyEpochModification(record)
    case ProfileSessionRecord.recordType:
      return applySessionModification(record)
    default:
      Log.info(
        "Ignoring fetched modification of type \(record.recordType)", category: .sync)
      return .ignored
    }
  }

  // MARK: - Fetched deletions (§5.2)

  func applyFetchedDeletion(
    recordID: CKRecord.ID, recordType: CKRecord.RecordType
  ) -> DeletionOutcome {
    let recordName = recordID.recordName
    switch recordType {
    case SyncedProfile.recordType:
      return deleteLocalProfile(recordName: recordName)
    case SyncedLocation.recordType:
      return deleteLocalLocation(recordName: recordName)
    case SyncedEmergencyUnblockEvent.recordType:
      emergencyManager.removeUnblockEvent(recordName: recordName)
      clearDeletionBookkeeping(recordName: recordName)
      return .deleted
    case ProfileSessionRecord.recordType:
      return stopSessionForDeletedRecord(recordName: recordName)
    default:
      // Command / legacy / unknown ⇒ no-op (§5.2).
      return .ignored
    }
  }

  private func clearDeletionBookkeeping(recordName: String) {
    store.setSystemFields(nil, for: recordName)
    store.clearTombstone(recordName: recordName)
    store.removeFailedApply(recordName: recordName)
  }

  private func deleteLocalProfile(recordName: String) -> DeletionOutcome {
    guard let id = UUID(uuidString: recordName) else { return .ignored }
    do {
      guard let profile = try BlockedProfiles.findProfile(byID: id, in: modelContext) else {
        clearDeletionBookkeeping(recordName: recordName)  // intent already satisfied
        SyncDiagnostics.profileDeletionApplied(
          profileId: id, existed: false, stoppedActiveSession: false, outcome: .notPresent)
        return .notPresent
      }
      store.setDeleteWatermark(recordName: recordName, value: Double(profile.syncVersion))
      // §5.2 / #203: if the deleted profile owns the active session, stop it first so
      // restrictions are deactivated and the manager does not retain a deleted model.
      let stoppedActiveSession = sessionController.activeSession?.blockedProfile.id == id
      if stoppedActiveSession {
        sessionController.stopRemoteSession(context: modelContext, profileId: id)
      }
      try BlockedProfiles.deleteProfile(profile, in: modelContext)  // defers save
      let saveOverride = saveOverride
      let profileDeleteCommitObserver = profileDeleteCommitObserver
      scheduleProfileDeleteCommit {
        [modelContext, store, id, recordName, saveOverride, profileDeleteCommitObserver] in
        do {
          // Remote apply failures are persisted as failedApplies and retried by the sync
          // controller, not surfaced as UI action errors. Controller side effects wait until
          // this deferred commit succeeds.
          if let saveOverride {
            try saveOverride()
          } else {
            try modelContext.save()
          }
          guard try BlockedProfiles.findProfile(byID: id, in: modelContext) == nil else {
            store.addFailedApply(
              FailedApply(
                recordName: recordName, recordType: SyncedProfile.recordType, op: .delete)
            )
            Log.error(
              "Deferred remote profile delete save completed but \(recordName) is still present",
              category: .sync
            )
            return
          }
          store.setSystemFields(nil, for: recordName)
          store.clearTombstone(recordName: recordName)
          store.removeFailedApply(recordName: recordName)
          profileDeleteCommitObserver?(recordName)
        } catch {
          modelContext.rollback()
          store.clearDeleteWatermark(recordName: recordName)
          store.addFailedApply(
            FailedApply(
              recordName: recordName, recordType: SyncedProfile.recordType, op: .delete))
          Log.error(
            "Failed to apply profile deletion \(recordName): \(error.localizedDescription)",
            category: .sync)
        }
      }
      SyncDiagnostics.profileDeletionApplied(
        profileId: id, existed: true, stoppedActiveSession: stoppedActiveSession,
        outcome: .deleted)
      return .deleted
    } catch {
      modelContext.rollback()
      store.clearDeleteWatermark(recordName: recordName)
      store.addFailedApply(
        FailedApply(
          recordName: recordName, recordType: SyncedProfile.recordType, op: .delete))
      Log.error(
        "Failed to apply profile deletion \(recordName): \(error.localizedDescription)",
        category: .sync)
      return .ignored
    }
  }

  private func deleteLocalLocation(recordName: String) -> DeletionOutcome {
    guard let id = UUID(uuidString: recordName) else { return .ignored }
    do {
      let location = try SavedLocation.find(byID: id, in: modelContext)
      if let location {
        store.setDeleteWatermark(
          recordName: recordName,
          value: location.updatedAt.timeIntervalSinceReferenceDate
        )
        try SavedLocation.delete(location, in: modelContext)  // saves internally
      }

      let repaired = try BlockedProfiles.removeLocationReference(id, in: modelContext)
      for profileId in repaired {
        guard let profile = try BlockedProfiles.findProfile(byID: profileId, in: modelContext)
        else {
          continue
        }
        profile.syncVersion += 1
        pendingReenqueues.append(CKRecord.ID(recordName: profileId.uuidString, zoneID: zoneID))
      }
      if !repaired.isEmpty {
        try commit()
      }

      clearDeletionBookkeeping(recordName: recordName)
      let outcome: DeletionOutcome = (location == nil && repaired.isEmpty) ? .notPresent : .deleted
      SyncDiagnostics.locationDeletionApplied(
        locationId: id, existed: location != nil, repairedProfileIds: repaired, outcome: outcome)
      return outcome
    } catch {
      modelContext.rollback()
      store.clearDeleteWatermark(recordName: recordName)
      store.addFailedApply(
        FailedApply(
          recordName: recordName, recordType: SyncedLocation.recordType, op: .delete))
      Log.error(
        "Failed to apply location deletion \(recordName): \(error.localizedDescription)",
        category: .sync)
      return .ignored
    }
  }

  private func stopSessionForDeletedRecord(recordName: String) -> DeletionOutcome {
    let prefix = "ProfileSession_"
    guard recordName.hasPrefix(prefix),
      let id = UUID(uuidString: String(recordName.dropFirst(prefix.count)))
    else {
      return .ignored
    }
    sessionController.setRemoteSessionActive(false, profileId: id)
    // §5.2: an explicit deletion stops the matching remote-started session (#203).
    if sessionController.activeSession?.blockedProfile.id == id {
      sessionController.stopRemoteSession(context: modelContext, profileId: id)
      return .deleted
    }
    return .notPresent
  }

  // MARK: - Profile apply (I9 gate + E-1 + equal-version divergence)

  /// #218 deterministic tie-break for equal-version, payload-differing conflicts. Both devices
  /// choose the same winner: newer `updatedAt`, then lexicographically lower `originDeviceId`.
  static func remoteWinsProfileTie(remote: SyncedProfile, local: SyncedProfile) -> Bool {
    if remote.updatedAt != local.updatedAt {
      return remote.updatedAt > local.updatedAt
    }
    return remote.originDeviceId < local.originDeviceId
  }

  private func applyProfileModification(_ record: CKRecord) -> ApplyOutcome {
    guard let synced = SyncedProfile(from: record) else {
      Log.info("Ignoring undecodable SyncedProfile record", category: .sync)
      return .ignored
    }
    let recordName = record.recordID.recordName
    do {
      let outcome = try applyDecodedProfile(synced, record: record)
      store.removeFailedApply(recordName: recordName)  // supersession (§5.6)
      return outcome
    } catch {
      modelContext.rollback()
      store.addFailedApply(
        FailedApply(
          recordName: recordName, recordType: SyncedProfile.recordType, op: .upsert))
      Log.error(
        "Failed to apply SyncedProfile \(recordName): \(error.localizedDescription)",
        category: .sync)
      return .failed
    }
  }

  private func applyDecodedProfile(
    _ synced: SyncedProfile, record: CKRecord
  ) throws -> ApplyOutcome {
    let recordName = record.recordID.recordName
    guard
      let existing = try BlockedProfiles.findProfile(byID: synced.profileId, in: modelContext)
    else {
      if let watermark = store.deleteWatermark(for: recordName),
        Double(synced.version) <= watermark
      {
        SyncDiagnostics.profileApply(
          profileId: synced.profileId, branch: "stale_delete_echo_skipped",
          remoteVersion: synced.version, localVersion: nil,
          remoteSchema: synced.profileSchemaVersion, localSchema: nil,
          remoteGeofenceRefCount: synced.geofenceRule?.locationReferences.count,
          localGeofenceRefCount: nil)
        return .skippedStaleDelete
      }
      createLocalProfile(from: synced)
      try commit()
      storeSystemFields(record)
      store.clearDeleteWatermark(recordName: recordName)
      SyncDiagnostics.profileApply(
        profileId: synced.profileId, branch: "created", remoteVersion: synced.version,
        localVersion: nil, remoteSchema: synced.profileSchemaVersion, localSchema: nil,
        remoteGeofenceRefCount: synced.geofenceRule?.locationReferences.count,
        localGeofenceRefCount: nil)
      return .applied
    }

    let localVersion = existing.syncVersion
    let localSchema = existing.profileSchemaVersion
    let localGeofenceRefCount = existing.geofenceRule?.locationReferences.count
    let remoteGeofenceRefCount = synced.geofenceRule?.locationReferences.count

    // I9 schema-version gate (verbatim from SyncCoordinator.swift:126-166, own-origin skip removed).
    if synced.profileSchemaVersion < existing.profileSchemaVersion {
      SyncConflictManager.shared.addConflict(
        profileId: existing.id, profileName: existing.name)
      // Auto-heal (I2 exception): bump + signal controller to re-enqueue the V2 payload.
      existing.syncVersion += 1
      try commit()
      pendingReenqueues.append(record.recordID)
      SyncDiagnostics.profileApply(
        profileId: existing.id, branch: "local_schema_newer_reenqueue",
        remoteVersion: synced.version, localVersion: localVersion,
        remoteSchema: synced.profileSchemaVersion, localSchema: localSchema,
        remoteGeofenceRefCount: remoteGeofenceRefCount,
        localGeofenceRefCount: localGeofenceRefCount)
      return .applied
    } else if synced.profileSchemaVersion > BlockedProfiles.currentSchemaVersion {
      SyncConflictManager.shared.addNewerVersionConflict(
        profileId: existing.id, profileName: existing.name)
      existing.profileSchemaVersion = synced.profileSchemaVersion
      existing.syncVersion = synced.version
      try commit()
      SyncDiagnostics.profileApply(
        profileId: existing.id, branch: "remote_schema_newer_marker",
        remoteVersion: synced.version, localVersion: localVersion,
        remoteSchema: synced.profileSchemaVersion, localSchema: localSchema,
        remoteGeofenceRefCount: remoteGeofenceRefCount,
        localGeofenceRefCount: localGeofenceRefCount)
      return .applied
    } else if synced.version > existing.syncVersion {
      updateLocalProfile(existing, from: synced)
      try commit()
      SyncConflictManager.shared.clearConflict(profileId: existing.id)
      storeSystemFields(record)
      SyncDiagnostics.profileApply(
        profileId: existing.id, branch: "remote_newer_applied",
        remoteVersion: synced.version, localVersion: localVersion,
        remoteSchema: synced.profileSchemaVersion, localSchema: localSchema,
        remoteGeofenceRefCount: remoteGeofenceRefCount,
        localGeofenceRefCount: localGeofenceRefCount)
      return .applied
    } else if synced.version == existing.syncVersion {
      // Equal-version divergence (§5.1): payload-differing => deterministic tie-break (#218).
      let localSynced = SyncedProfile(from: existing, originDeviceId: deviceId)
      if SyncPayloadEquality.profilesPayloadEqual(synced, localSynced) {
        SyncDiagnostics.profileApply(
          profileId: existing.id, branch: "equal_payload_noop",
          remoteVersion: synced.version, localVersion: localVersion,
          remoteSchema: synced.profileSchemaVersion, localSchema: localSchema,
          remoteGeofenceRefCount: remoteGeofenceRefCount,
          localGeofenceRefCount: localGeofenceRefCount)
        return .applied  // payload-equal echo ⇒ no-op
      }
      if Self.remoteWinsProfileTie(remote: synced, local: localSynced) {
        // Remote wins: adopt its already-published payload without re-enqueuing.
        updateLocalProfile(existing, from: synced)
        try commit()
        storeSystemFields(record)
        SyncConflictManager.shared.addDivergenceConflict(
          profileId: existing.id, profileName: existing.name)
        SyncDiagnostics.profileApply(
          profileId: existing.id, branch: "equal_divergence_remote_wins",
          remoteVersion: synced.version, localVersion: localVersion,
          remoteSchema: synced.profileSchemaVersion, localSchema: localSchema,
          remoteGeofenceRefCount: remoteGeofenceRefCount,
          localGeofenceRefCount: localGeofenceRefCount)
        return .applied
      } else {
        // Local wins: bump above the tie and re-enqueue through the existing I2 exception.
        existing.syncVersion += 1
        try commit()
        pendingReenqueues.append(record.recordID)
        SyncConflictManager.shared.addDivergenceConflict(
          profileId: existing.id, profileName: existing.name)
        SyncDiagnostics.profileApply(
          profileId: existing.id, branch: "equal_divergence_local_wins_reenqueue",
          remoteVersion: synced.version, localVersion: localVersion,
          remoteSchema: synced.profileSchemaVersion, localSchema: localSchema,
          remoteGeofenceRefCount: remoteGeofenceRefCount,
          localGeofenceRefCount: localGeofenceRefCount)
        return .applied
      }
    } else {
      // Older incoming version ⇒ no-op.
      SyncDiagnostics.profileApply(
        profileId: existing.id, branch: "older_remote_noop", remoteVersion: synced.version,
        localVersion: localVersion, remoteSchema: synced.profileSchemaVersion,
        localSchema: localSchema, remoteGeofenceRefCount: remoteGeofenceRefCount,
        localGeofenceRefCount: localGeofenceRefCount)
      return .applied
    }
  }

  // Verbatim from SyncCoordinator.updateLocalProfile (SyncCoordinator.swift:211-265),
  // adapted to use self.modelContext (the original `context` param was unused).
  private func updateLocalProfile(_ profile: BlockedProfiles, from synced: SyncedProfile) {
    profile.name = synced.name
    profile.blockingStrategyId = synced.blockingStrategyId
    profile.strategyData = synced.strategyData
    profile.order = synced.order
    profile.enableLiveActivity = synced.enableLiveActivity
    profile.reminderTimeInSeconds = synced.reminderTimeInSeconds
    profile.customReminderMessage = synced.customReminderMessage
    profile.enableBreaks = synced.enableBreaks
    profile.breakTimeInMinutes = synced.breakTimeInMinutes
    profile.enableStrictMode = synced.enableStrictMode
    profile.enableAllowMode = synced.enableAllowMode
    profile.enableAllowModeDomains = synced.enableAllowModeDomains
    profile.enableSafariBlocking = synced.enableSafariBlocking
    profile.physicalUnblockNFCTagId = synced.physicalUnblockNFCTagId
    profile.physicalUnblockQRCodeId = synced.physicalUnblockQRCodeId
    profile.domains = synced.domains
    profile.schedule = synced.schedule
    profile.geofenceRule = synced.geofenceRule
    profile.disableBackgroundStops = synced.disableBackgroundStops
    profile.preActivationReminderTimes = synced.preActivationReminderTimes
    profile.isManaged = synced.isManaged
    profile.managedByChildId = synced.managedByChildId
    profile.syncVersion = synced.version
    profile.updatedAt = synced.updatedAt
    if let startTriggers = synced.startTriggers {
      profile.startTriggers = startTriggers
    }
    if let stopConditions = synced.stopConditions {
      profile.stopConditions = stopConditions
    }
    if synced.startScheduleData != nil {
      profile.startSchedule = synced.startSchedule
    }
    if synced.stopScheduleData != nil {
      profile.stopSchedule = synced.stopSchedule
    }
    profile.startNFCTagId = synced.startNFCTagId
    profile.startQRCodeId = synced.startQRCodeId
    profile.stopNFCTagId = synced.stopNFCTagId
    profile.stopQRCodeId = synced.stopQRCodeId
    profile.profileSchemaVersion = max(
      profile.profileSchemaVersion, synced.profileSchemaVersion)
    profile.scheduleLastStoppedAt = synced.scheduleLastStoppedAt
    BlockedProfiles.updateSnapshot(for: profile)
  }

  // Verbatim from SyncCoordinator.createLocalProfile (SyncCoordinator.swift:267-318),
  // adapted to use self.modelContext. E-1: needsAppSelection = true.
  private func createLocalProfile(from synced: SyncedProfile) {
    let profile = BlockedProfiles(
      id: synced.profileId,
      name: synced.name,
      createdAt: synced.createdAt,
      updatedAt: synced.updatedAt,
      blockingStrategyId: synced.blockingStrategyId ?? NFCBlockingStrategy.id,
      strategyData: synced.strategyData,
      enableLiveActivity: synced.enableLiveActivity,
      reminderTimeInSeconds: synced.reminderTimeInSeconds,
      customReminderMessage: synced.customReminderMessage,
      enableBreaks: synced.enableBreaks,
      breakTimeInMinutes: synced.breakTimeInMinutes,
      enableStrictMode: synced.enableStrictMode,
      enableAllowMode: synced.enableAllowMode,
      enableAllowModeDomains: synced.enableAllowModeDomains,
      enableSafariBlocking: synced.enableSafariBlocking,
      order: synced.order,
      domains: synced.domains,
      physicalUnblockNFCTagId: synced.physicalUnblockNFCTagId,
      physicalUnblockQRCodeId: synced.physicalUnblockQRCodeId,
      schedule: synced.schedule,
      geofenceRule: synced.geofenceRule,
      disableBackgroundStops: synced.disableBackgroundStops,
      preActivationReminderTimes: synced.preActivationReminderTimes,
      isManaged: synced.isManaged,
      managedByChildId: synced.managedByChildId,
      syncVersion: synced.version,
      needsAppSelection: true
    )
    if let startTriggers = synced.startTriggers {
      profile.startTriggers = startTriggers
    }
    if let stopConditions = synced.stopConditions {
      profile.stopConditions = stopConditions
    }
    profile.startSchedule = synced.startSchedule
    profile.stopSchedule = synced.stopSchedule
    profile.startNFCTagId = synced.startNFCTagId
    profile.startQRCodeId = synced.startQRCodeId
    profile.stopNFCTagId = synced.stopNFCTagId
    profile.stopQRCodeId = synced.stopQRCodeId
    profile.profileSchemaVersion = synced.profileSchemaVersion
    profile.scheduleLastStoppedAt = synced.scheduleLastStoppedAt
    modelContext.insert(profile)
    BlockedProfiles.updateSnapshot(for: profile)
  }

  // MARK: - Location apply (N6 client-clock merge)

  private func applyLocationModification(_ record: CKRecord) -> ApplyOutcome {
    guard let synced = SyncedLocation(from: record) else {
      Log.info("Ignoring undecodable SyncedLocation record", category: .sync)
      return .ignored
    }
    let recordName = record.recordID.recordName
    do {
      if let existing = try SavedLocation.find(byID: synced.locationId, in: modelContext) {
        // N6 client-clock merge (verbatim from SyncCoordinator.swift:438-455).
        if synced.lastModified > existing.updatedAt {
          let localVersion = existing.syncVersion
          existing.syncVersion = max(existing.syncVersion, 1) + 1
          _ = try SavedLocation.update(
            existing,
            in: modelContext,
            name: synced.name,
            latitude: synced.latitude,
            longitude: synced.longitude,
            defaultRadiusMeters: synced.defaultRadiusMeters,
            isLocked: synced.isLocked
          )
          SyncDiagnostics.locationApply(
            locationId: synced.locationId, branch: "remote_newer_applied",
            localVersion: localVersion, newLocalVersion: existing.syncVersion)
        } else {
          let localVersion = existing.syncVersion
          existing.syncVersion = max(existing.syncVersion, 1)
          try commit()
          SyncDiagnostics.locationApply(
            locationId: synced.locationId, branch: "local_newer_or_equal_noop",
            localVersion: localVersion, newLocalVersion: existing.syncVersion)
        }
      } else {
        if let watermark = store.deleteWatermark(for: recordName),
          synced.lastModified.timeIntervalSinceReferenceDate <= watermark
        {
          SyncDiagnostics.locationApply(
            locationId: synced.locationId, branch: "stale_delete_echo_skipped",
            localVersion: nil, newLocalVersion: 0)
          store.removeFailedApply(recordName: recordName)
          return .skippedStaleDelete
        }
        let location = SavedLocation(
          id: synced.locationId,
          name: synced.name,
          latitude: synced.latitude,
          longitude: synced.longitude,
          defaultRadiusMeters: synced.defaultRadiusMeters,
          isLocked: synced.isLocked,
          syncVersion: 1
        )
        modelContext.insert(location)
        try commit()
        store.clearDeleteWatermark(recordName: recordName)
        SyncDiagnostics.locationApply(
          locationId: synced.locationId, branch: "created", localVersion: nil,
          newLocalVersion: location.syncVersion)
      }
      store.removeFailedApply(recordName: recordName)  // supersession (§5.6)
      storeSystemFields(record)
      return .applied
    } catch {
      modelContext.rollback()
      store.addFailedApply(
        FailedApply(
          recordName: recordName, recordType: SyncedLocation.recordType, op: .upsert))
      Log.error(
        "Failed to apply SyncedLocation \(recordName): \(error.localizedDescription)",
        category: .sync)
      return .failed
    }
  }

  // MARK: - Emergency apply (versioned last-write-wins)

  private func applyEmergencyModification(_ record: CKRecord) -> ApplyOutcome {
    guard let remote = SyncedEmergencySettings(from: record) else {
      Log.info("Ignoring undecodable SyncedEmergencySettings record", category: .sync)
      return .ignored
    }
    // Last-write-wins version gate (verbatim from SyncCoordinator.swift:514-524).
    guard remote.version > emergencyManager.emergencySettingsVersion else {
      SyncDiagnostics.emergencySettingsApply(
        branch: "local_newer_or_equal_noop", remoteVersion: remote.version,
        localVersion: emergencyManager.emergencySettingsVersion)
      return .applied
    }
    let localVersion = emergencyManager.emergencySettingsVersion
    emergencyManager.applyRemoteEmergencySettings(remote)
    SyncDiagnostics.emergencySettingsApply(
      branch: "remote_newer_applied", remoteVersion: remote.version, localVersion: localVersion)
    store.removeFailedApply(recordName: record.recordID.recordName)  // supersession (§5.6)
    storeSystemFields(record)
    return .applied
  }

  // MARK: - Emergency unblock event apply

  private func applyUnblockEventModification(_ record: CKRecord) -> ApplyOutcome {
    guard let event = SyncedEmergencyUnblockEvent(from: record) else {
      Log.info("Ignoring undecodable EmergencyUnblockEvent record", category: .sync)
      return .ignored
    }
    emergencyManager.mergeRemoteUnblockEvent(event)
    SyncDiagnostics.emergencyUnblockEventApply(recordName: event.recordName)
    store.removeFailedApply(recordName: record.recordID.recordName)
    storeSystemFields(record)
    return .applied
  }

  private func applyEmergencyEpochModification(_ record: CKRecord) -> ApplyOutcome {
    guard let remote = SyncedEmergencyEpoch(from: record) else {
      Log.info("Ignoring undecodable EmergencyResetEpoch record", category: .sync)
      return .ignored
    }
    // #221 monotonic-max channel: no version gate. max() is order-independent, so a deferred
    // local epoch drain and a fetched remote epoch converge regardless of arrival order.
    emergencyManager.adoptRemoteEpoch(remote.epoch)
    SyncDiagnostics.emergencyEpochApply(epoch: remote.epoch)
    store.removeFailedApply(recordName: record.recordID.recordName)
    storeSystemFields(record)
    return .applied
  }

  // MARK: - Session apply (implemented in Task 26)

  private func applySessionModification(_ record: CKRecord) -> ApplyOutcome {
    guard let session = ProfileSessionRecord(from: record) else {
      Log.info("Ignoring undecodable ProfileSession record", category: .sync)
      return .ignored
    }
    applySessionState(session)
    return .applied
  }

  /// Verbatim from SyncCoordinator.applySessionState (SyncCoordinator.swift:368-405),
  /// keeping the lastModifiedBy self-echo filter. Sessions never enter systemFields.
  private func applySessionState(_ session: ProfileSessionRecord) {
    let profileId = session.profileId
    if session.lastModifiedBy == deviceId {
      SyncDiagnostics.sessionApply(profileId: profileId, branch: "own_origin_noop")
      return
    }
    sessionController.setRemoteSessionActive(session.isActive, profileId: profileId)
    let localActive = sessionController.activeSession?.blockedProfile.id == profileId
    if session.isActive && !localActive {
      if let startTime = session.startTime {
        sessionController.startRemoteSession(
          context: modelContext, profileId: profileId, sessionId: UUID(), startTime: startTime)
        SyncDiagnostics.sessionApply(profileId: profileId, branch: "remote_start_applied")
      }
    } else if !session.isActive && localActive {
      sessionController.stopRemoteSession(context: modelContext, profileId: profileId)
      SyncDiagnostics.sessionApply(profileId: profileId, branch: "remote_stop_applied")
    } else {
      SyncDiagnostics.sessionApply(profileId: profileId, branch: "state_already_matching_noop")
    }
  }

  // MARK: - Helpers

  private func commit() throws {
    if let saveOverride {
      try saveOverride()
    } else {
      try modelContext.save()
    }
  }

  /// Store change-tag system fields — scoped types only, only after a durable apply (§2.1/§5.1).
  private func storeSystemFields(_ record: CKRecord) {
    store.setSystemFields(
      CKRecordSystemFieldsCodec.encode(record), for: record.recordID.recordName)
  }
}
