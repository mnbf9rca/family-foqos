import CloudKit
import Foundation

/// Handles migration from old per-device SyncedSession records to new ProfileSessionRecord format
class SessionSyncMigration {

  private let privateDatabase: CKDatabase
  private let syncZoneID: CKRecordZone.ID

  init(database: CKDatabase, zoneID: CKRecordZone.ID) {
    self.privateDatabase = database
    self.syncZoneID = zoneID
  }

  /// Check if migration is needed and perform it
  func migrateIfNeeded() async {
    // Check for legacy records
    let legacyQuery = CKQuery(
      recordType: SyncedSession.recordType,
      predicate: NSPredicate(value: true)
    )

    do {
      let (results, _) = try await privateDatabase.records(
        matching: legacyQuery,
        inZoneWith: syncZoneID
      )

      if results.isEmpty {
        print("SessionSyncMigration: No legacy records to migrate")
        return
      }

      print("SessionSyncMigration: Found \(results.count) legacy records")

      // Group by profile ID
      var profileSessions: [UUID: [(CKRecord.ID, SyncedSession)]] = [:]

      for (recordID, result) in results {
        if case .success(let record) = result,
          let session = SyncedSession(from: record)
        {
          profileSessions[session.profileId, default: []].append((recordID, session))
        }
      }

      // Create new ProfileSessionRecord for each profile
      for (profileId, sessions) in profileSessions {
        // Find the most recent session state
        let sorted = sessions.sorted { $0.1.lastModified > $1.1.lastModified }
        guard let latest = sorted.first?.1 else { continue }

        // Check if a ProfileSessionRecord already exists for this profile
        let existingResult = await SessionSyncService.shared.fetchSession(profileId: profileId)
        if case .found = existingResult {
          print(
            "SessionSyncMigration: ProfileSessionRecord already exists for \(profileId), deleting legacy records only"
          )
        } else {
          // Create new unified record
          var profileSession = ProfileSessionRecord(profileId: profileId)
          _ = profileSession.applyUpdate(
            isActive: latest.isActive,
            sequenceNumber: 1,  // Reset sequence
            deviceId: latest.originDeviceId,
            startTime: latest.startTime,
            endTime: latest.endTime
          )

          let newRecord = profileSession.toCKRecord(in: syncZoneID)

          // Save new record
          do {
            _ = try await privateDatabase.save(newRecord)
            print("SessionSyncMigration: Created ProfileSessionRecord for \(profileId)")
          } catch {
            print("SessionSyncMigration: Failed to create ProfileSessionRecord for \(profileId) - \(error)")
            continue
          }
        }

        // Delete legacy records for this profile
        for (recordID, _) in sessions {
          do {
            try await privateDatabase.deleteRecord(withID: recordID)
          } catch {
            print("SessionSyncMigration: Failed to delete legacy record \(recordID) - \(error)")
          }
        }
        print("SessionSyncMigration: Deleted \(sessions.count) legacy records for \(profileId)")
      }

      print("SessionSyncMigration: Migration complete")

    } catch let error as CKError {
      if error.code == .zoneNotFound || error.code == .unknownItem {
        print("SessionSyncMigration: No sync zone or legacy records found")
        return
      }
      print("SessionSyncMigration: Error during migration - \(error)")
    } catch {
      print("SessionSyncMigration: Error during migration - \(error)")
    }
  }
}
