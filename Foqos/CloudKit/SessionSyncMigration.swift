import CloudKit
import Foundation

/// Handles migration from old per-device SyncedSession records to new ProfileSessionRecord format
class SessionSyncMigration {

  private let privateDatabase: CKDatabase
  private let syncZoneID: CKRecordZone.ID
  private let userRecordName: String

  private static let migrationCompleteKeyPrefix = "family_foqos_session_sync_migration_complete_"

  private var migrationCompleteKey: String {
    Self.migrationCompleteKeyPrefix + userRecordName
  }

  private var isMigrationComplete: Bool {
    get { UserDefaults.standard.bool(forKey: migrationCompleteKey) }
    set { UserDefaults.standard.set(newValue, forKey: migrationCompleteKey) }
  }

  init(database: CKDatabase, zoneID: CKRecordZone.ID, userRecordName: String) {
    self.privateDatabase = database
    self.syncZoneID = zoneID
    self.userRecordName = userRecordName
  }

  /// Check if migration is needed and perform it
  func migrateIfNeeded() async {
    // Skip if migration already completed for this account
    if isMigrationComplete {
      return
    }

    // Check for legacy records with pagination
    let legacyQuery = CKQuery(
      recordType: SyncedSession.recordType,
      predicate: NSPredicate(value: true)
    )

    do {
      var allResults: [(CKRecord.ID, Result<CKRecord, Error>)] = []
      var cursor: CKQueryOperation.Cursor? = nil

      // First batch
      let (initialResults, initialCursor) = try await privateDatabase.records(
        matching: legacyQuery,
        inZoneWith: syncZoneID
      )
      allResults.append(contentsOf: initialResults)
      cursor = initialCursor

      // Continue fetching while there are more results
      while let currentCursor = cursor {
        let (moreResults, nextCursor) = try await privateDatabase.records(
          continuingMatchFrom: currentCursor
        )
        allResults.append(contentsOf: moreResults)
        cursor = nextCursor
      }

      if allResults.isEmpty {
        print("SessionSyncMigration: No legacy records to migrate")
        isMigrationComplete = true
        return
      }

      print("SessionSyncMigration: Found \(allResults.count) legacy records")

      // Group by profile ID
      var profileSessions: [UUID: [(CKRecord.ID, SyncedSession)]] = [:]

      for (recordID, result) in allResults {
        if case .success(let record) = result,
          let session = SyncedSession(from: record)
        {
          profileSessions[session.profileId, default: []].append((recordID, session))
        }
      }

      // Track migration errors - only mark complete if all profiles migrate successfully
      var migrationErrors = 0

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
            migrationErrors += 1
            continue
          }
        }

        // Delete legacy records for this profile
        for (recordID, _) in sessions {
          do {
            try await privateDatabase.deleteRecord(withID: recordID)
          } catch {
            print("SessionSyncMigration: Failed to delete legacy record \(recordID) - \(error)")
            migrationErrors += 1
          }
        }
        print("SessionSyncMigration: Deleted \(sessions.count) legacy records for \(profileId)")
      }

      // Only mark migration complete if no errors occurred
      if migrationErrors == 0 {
        isMigrationComplete = true
        print("SessionSyncMigration: Migration complete")
      } else {
        print("SessionSyncMigration: Migration finished with \(migrationErrors) errors, will retry on next sync")
      }

    } catch let error as CKError {
      if error.code == .zoneNotFound || error.code == .unknownItem {
        print("SessionSyncMigration: No sync zone or legacy records found")
        isMigrationComplete = true
        return
      }
      print("SessionSyncMigration: Error during migration - \(error)")
    } catch {
      print("SessionSyncMigration: Error during migration - \(error)")
    }
  }
}
