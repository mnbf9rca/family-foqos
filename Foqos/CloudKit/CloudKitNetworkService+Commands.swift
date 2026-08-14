import CloudKit
import Foundation

extension CloudKitNetworkService {

  // MARK: - Family Commands

  /// Outcome of attempting to save a FamilyCommand. `.alreadyPending` means the deterministic
  /// recordName collided with a still-pending identical command, an idempotent success (#222).
  enum CommandSaveOutcome: Equatable { case alreadyPending, failed }

  static func classifyCommandSave(error: Error) -> CommandSaveOutcome {
    if let ckError = error as? CKError, ckError.code == .serverRecordChanged {
      return .alreadyPending
    }
    return .failed
  }

  static func resolvePendingCommandFetch(
    commands: [FamilyCommand],
    hasFailures: Bool
  ) -> (commands: [FamilyCommand], isConnected: Bool) {
    (commands: commands, isConnected: !hasFailures)
  }

  func sendCommand(_ command: FamilyCommand) async throws {
    Log.info("Sending command: \(command.commandType.rawValue) to child", category: .cloudKit)

    try await createPolicyZoneIfNeeded()
    try await ensureFamilyRootExists()

    let record = command.toCKRecord(in: policyZoneID)

    do {
      _ = try await privateDatabase.save(record)
      Log.info("Command sent successfully", category: .cloudKit)
    } catch {
      switch Self.classifyCommandSave(error: error) {
      case .alreadyPending:
        // #222: the deterministic recordName means an identical command is already queued.
        Log.info(
          "Command already pending (serverRecordChanged) - idempotent success",
          category: .cloudKit)
      case .failed:
        Log.error("Failed to send command: \(redactedErrorForLog(error))", category: .cloudKit)
        throw CloudKitError.saveFailed(error)
      }
    }
  }

  /// #331: true while the parent's queued command record still exists in the private DB. A V2 child
  /// deletes it after processing; a V1 child never does, so the parent honestly keeps waiting.
  func commandIsPending(_ command: FamilyCommand) async throws -> Bool {
    let recordID = CKRecord.ID(
      recordName: FamilyCommand.recordName(
        commandType: command.commandType,
        targetChildId: command.targetChildId,
        parentId: command.createdBy
      ),
      zoneID: policyZoneID
    )

    do {
      _ = try await privateDatabase.record(for: recordID)
      return true
    } catch let error as CKError where error.code == .unknownItem {
      return false
    }
  }

  func fetchPendingCommands(
    currentUserRecordID: CKRecord.ID?
  ) async throws -> (commands: [FamilyCommand], isConnected: Bool) {
    let zones = try await sharedDatabase.allRecordZones()

    var allCommands: [FamilyCommand] = []
    var hasFailures = false

    guard let userRecordID = currentUserRecordID else {
      Log.debug("No user record ID, skipping command fetch", category: .cloudKit)
      return Self.resolvePendingCommandFetch(commands: [], hasFailures: false)
    }
    let currentUserRecordName = userRecordID.recordName

    for zone in zones {
      let query = CKQuery(
        recordType: FamilyCommand.recordType,
        predicate: NSPredicate(format: "targetChildId == %@", currentUserRecordName)
      )

      do {
        let (results, _) = try await sharedDatabase.records(
          matching: query,
          inZoneWith: zone.zoneID
        )

        for (_, result) in results {
          switch result {
          case .success(let record):
            guard let command = FamilyCommand(from: record) else {
              hasFailures = true
              Log.error("Failed to decode pending command", category: .cloudKit)
              continue
            }
            allCommands.append(command)
          case .failure(let error):
            hasFailures = true
            Log.error(
              "Failed to fetch pending command: \(redactedErrorForLog(error))",
              category: .cloudKit)
          }
        }
      } catch {
        hasFailures = true
        Log.error(
          "Failed to fetch commands from zone \(zone.zoneID): \(redactedErrorForLog(error))", category: .cloudKit)
      }
    }

    return Self.resolvePendingCommandFetch(
      commands: allCommands,
      hasFailures: hasFailures)
  }

  func deleteCommand(_ command: FamilyCommand) async throws {
    let zones = try await sharedDatabase.allRecordZones()

    for zone in zones {
      let recordName = FamilyCommand.recordName(
        commandType: command.commandType, targetChildId: command.targetChildId,
        parentId: command.createdBy)
      let recordID = CKRecord.ID(recordName: recordName, zoneID: zone.zoneID)

      do {
        try await sharedDatabase.deleteRecord(withID: recordID)
        Log.info("Deleted command: \(command.commandType.rawValue)", category: .cloudKit)
        return
      } catch let error as CKError where error.code == .unknownItem {
        continue
      } catch {
        Log.error("Failed to delete command: \(redactedErrorForLog(error))", category: .cloudKit)
        throw CloudKitError.deleteFailed(error)
      }
    }
  }

  func cleanupStaleCommands(maxAgeDays: Int = CloudKitNetworkService.staleCommandMaxAgeDays) async {
    let maxAge: TimeInterval = Double(maxAgeDays) * CloudKitNetworkService.secondsPerDay
    let cutoffDate = Date().addingTimeInterval(-maxAge)

    do {
      let zones = try await sharedDatabase.allRecordZones()
      for zone in zones {
        await cleanupStaleCommandsInZone(
          zone.zoneID, database: sharedDatabase, cutoffDate: cutoffDate)
      }
    } catch {
      Log.debug("No shared zones to cleanup: \(redactedErrorForLog(error))", category: .cloudKit)
    }

    if policyZoneVerified {
      await cleanupStaleCommandsInZone(
        policyZoneID, database: privateDatabase, cutoffDate: cutoffDate)
    }
  }

  private func cleanupStaleCommandsInZone(
    _ zoneID: CKRecordZone.ID, database: CKDatabase, cutoffDate: Date
  ) async {
    let query = CKQuery(
      recordType: FamilyCommand.recordType,
      predicate: NSPredicate(format: "createdAt < %@", cutoffDate as NSDate)
    )

    do {
      let (results, _) = try await database.records(matching: query, inZoneWith: zoneID)

      for (recordID, result) in results {
        if case .success = result {
          do {
            try await database.deleteRecord(withID: recordID)
            Log.info("Cleaned up stale command: \(recordID.recordName)", category: .cloudKit)
          } catch {
            Log.error("Failed to delete stale command: \(redactedErrorForLog(error))", category: .cloudKit)
          }
        }
      }
    } catch {
      Log.debug("No stale commands to cleanup in zone \(zoneID): \(redactedErrorForLog(error))", category: .cloudKit)
    }
  }
}
