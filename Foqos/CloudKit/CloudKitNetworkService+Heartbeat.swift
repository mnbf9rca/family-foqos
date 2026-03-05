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
          Log.warning("Failed to write heartbeat: \(error)", category: .cloudKit)
          continuation.resume(throwing: error)
        }
      }
      database.add(operation)
    }
  }

  // MARK: - Parent: Fetch Heartbeats

  /// Fetch all heartbeat records from the private database. Called by parent device.
  func fetchHeartbeats() async -> [DeviceHeartbeat] {
    let query = CKQuery(
      recordType: DeviceHeartbeat.recordType,
      predicate: NSPredicate(value: true)
    )

    var allHeartbeats: [DeviceHeartbeat] = []

    if policyZoneVerified {
      do {
        let (results, _) = try await privateDatabase.records(
          matching: query, inZoneWith: policyZoneID)

        for (_, result) in results {
          if case .success(let record) = result,
            let heartbeat = DeviceHeartbeat(from: record)
          {
            allHeartbeats.append(heartbeat)
          }
        }
      } catch {
        Log.error("Failed to fetch heartbeats from private DB: \(error)", category: .cloudKit)
      }
    }

    return allHeartbeats
  }

  // MARK: - Parent: Delete Heartbeat

  /// Delete a heartbeat record (when parent removes a device).
  func deleteHeartbeat(childUserRecordName: String, deviceIdentifier: String) async throws {
    let recordName = DeviceHeartbeat.recordName(
      childUserRecordName: childUserRecordName, deviceIdentifier: deviceIdentifier)
    let recordID = CKRecord.ID(recordName: recordName, zoneID: policyZoneID)

    do {
      try await privateDatabase.deleteRecord(withID: recordID)
      Log.info("Deleted heartbeat record: \(recordName)", category: .cloudKit)
    } catch {
      Log.error("Failed to delete heartbeat: \(error)", category: .cloudKit)
      throw CloudKitError.deleteFailed(error)
    }
  }
}
