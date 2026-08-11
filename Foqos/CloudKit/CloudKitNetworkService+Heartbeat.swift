import CloudKit
import Foundation

extension CloudKitNetworkService {

  // MARK: - Child: Write Heartbeat

  /// Write heartbeat to the shared zone. Called by child device on profile activation.
  /// Uses the shared database — child must have readWrite permission on the shared zone.
  func writeHeartbeat(_ heartbeat: DeviceHeartbeat) async throws {
    guard let zone = await findSharedZoneByName() else {
      throw CloudKitError.notConnectedToFamily
    }

    let record = heartbeat.toCKRecord(in: zone.zoneID)

    let operation = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
    operation.savePolicy = .changedKeys

    let database = self.sharedDatabase

    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      operation.modifyRecordsResultBlock = { result in
        switch result {
        case .success:
          Log.info("Heartbeat written successfully", category: .cloudKit)
          continuation.resume()
        case .failure(let error):
          Log.warning("Failed to write heartbeat: \(redactedErrorForLog(error))", category: .cloudKit)
          continuation.resume(throwing: error)
        }
      }
      database.add(operation)
    }
  }

  // MARK: - Parent: Fetch Heartbeats

  /// Fetch all heartbeat records. Called by parent device.
  /// Owner reads from private DB; co-parents read from shared DB.
  func fetchHeartbeats() async -> [DeviceHeartbeat] {
    var allHeartbeats: [DeviceHeartbeat] = []
    var seenRecordNames: Set<String> = []

    // Owner reads from private DB
    if policyZoneVerified {
      let query = CKQuery(
        recordType: DeviceHeartbeat.recordType,
        predicate: NSPredicate(value: true)
      )
      do {
        let (results, _) = try await privateDatabase.records(
          matching: query, inZoneWith: policyZoneID)
        for (_, result) in results {
          if case .success(let record) = result,
            let heartbeat = DeviceHeartbeat(from: record)
          {
            seenRecordNames.insert(record.recordID.recordName)
            allHeartbeats.append(heartbeat)
          }
        }
      } catch {
        Log.error("Failed to fetch heartbeats from private DB: \(redactedErrorForLog(error))", category: .cloudKit)
      }
    }

    // Co-parent reads from shared DB
    if let zone = await findSharedZoneByName() {
      let query = CKQuery(
        recordType: DeviceHeartbeat.recordType,
        predicate: NSPredicate(value: true)
      )
      do {
        let (results, _) = try await sharedDatabase.records(
          matching: query, inZoneWith: zone.zoneID)
        for (_, result) in results {
          if case .success(let record) = result,
            !seenRecordNames.contains(record.recordID.recordName),
            let heartbeat = DeviceHeartbeat(from: record)
          {
            allHeartbeats.append(heartbeat)
          }
        }
      } catch {
        Log.error("Failed to fetch heartbeats from shared DB: \(redactedErrorForLog(error))", category: .cloudKit)
      }
    }

    return allHeartbeats
  }

  // MARK: - Parent: Delete Heartbeat

  /// Delete a heartbeat record (when parent removes a device).
  /// Tries private DB first (share owner), falls back to shared DB (co-parent).
  func deleteHeartbeat(childUserRecordName: String, deviceIdentifier: String) async throws {
    let recordName = DeviceHeartbeat.recordName(
      childUserRecordName: childUserRecordName, deviceIdentifier: deviceIdentifier)

    // Try private DB first (share owner)
    if policyZoneVerified {
      let recordID = CKRecord.ID(recordName: recordName, zoneID: policyZoneID)
      do {
        try await privateDatabase.deleteRecord(withID: recordID)
        Log.info("Deleted heartbeat record from private DB: \(recordName)", category: .cloudKit)
        return
      } catch let error as CKError where error.code == .unknownItem {
        Log.debug("Heartbeat not in private DB, trying shared DB", category: .cloudKit)
      } catch {
        Log.error("Failed to delete heartbeat from private DB: \(redactedErrorForLog(error))", category: .cloudKit)
      }
    }

    // Fall back to shared DB (co-parent)
    guard let zone = await findSharedZoneByName() else {
      throw CloudKitError.notConnectedToFamily
    }
    let sharedRecordID = CKRecord.ID(recordName: recordName, zoneID: zone.zoneID)
    do {
      try await sharedDatabase.deleteRecord(withID: sharedRecordID)
      Log.info("Deleted heartbeat record from shared DB: \(recordName)", category: .cloudKit)
    } catch {
      Log.error("Failed to delete heartbeat from shared DB: \(redactedErrorForLog(error))", category: .cloudKit)
      throw CloudKitError.deleteFailed(error)
    }
  }
}
