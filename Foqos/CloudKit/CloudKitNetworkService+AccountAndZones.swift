import CloudKit
import Foundation

extension CloudKitNetworkService {

  // MARK: - Account Status

  func accountStatusDetailed() async -> (
    status: CKAccountStatus, userRecordID: CKRecord.ID?, error: Error?
  ) {
    do {
      let status = try await container.accountStatus()
      guard status == .available else {
        return (status: status, userRecordID: nil, error: nil)
      }

      do {
        let recordID = try await container.userRecordID()
        return (status: status, userRecordID: recordID, error: nil)
      } catch {
        Log.error("Failed to fetch user record ID: \(error)", category: .cloudKit)
        return (status: status, userRecordID: nil, error: nil)
      }
    } catch {
      Log.error("Account status detail error: \(error)", category: .cloudKit)
      return (status: .couldNotDetermine, userRecordID: nil, error: error)
    }
  }

  func checkAccountStatus() async -> (isSignedIn: Bool, userRecordID: CKRecord.ID?) {
    let start = CFAbsoluteTimeGetCurrent()
    Log.info("checkAccountStatus: starting", category: .cloudKit)
    do {
      let status = try await container.accountStatus()
      Log.info(
        "checkAccountStatus: got status (\(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - start))s)",
        category: .cloudKit)
      let signedIn = (status == .available)

      if signedIn {
        do {
          let recordID = try await container.userRecordID()
          Log.info(
            "checkAccountStatus: complete (\(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - start))s)",
            category: .cloudKit)
          return (isSignedIn: true, userRecordID: recordID)
        } catch {
          Log.error("Failed to fetch user record ID: \(error)", category: .cloudKit)
          return (isSignedIn: true, userRecordID: nil)
        }
      }

      Log.info(
        "checkAccountStatus: not signed in (\(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - start))s)",
        category: .cloudKit)
      return (isSignedIn: false, userRecordID: nil)
    } catch {
      Log.error("Account status error: \(error)", category: .cloudKit)
      return (isSignedIn: false, userRecordID: nil)
    }
  }

  // MARK: - User Record

  func ensureUserRecordID(cached: CKRecord.ID?) async throws -> CKRecord.ID {
    if let recordID = cached {
      return recordID
    }

    let result = await checkAccountStatus()

    guard result.isSignedIn else {
      throw CloudKitError.notSignedIn
    }

    guard let recordID = result.userRecordID else {
      throw CloudKitError.notSignedIn
    }

    return recordID
  }

  // MARK: - Zone Management

  func createPolicyZoneIfNeeded() async throws {
    if policyZoneVerified { return }

    let zone = CKRecordZone(zoneID: policyZoneID)

    do {
      _ = try await privateDatabase.save(zone)
      policyZoneVerified = true
      Log.info("Created policy zone: \(policyZoneID.zoneName)", category: .cloudKit)
    } catch _ as CKError {
      do {
        _ = try await privateDatabase.recordZone(for: policyZoneID)
        policyZoneVerified = true
        Log.debug("Policy zone already exists: \(policyZoneID.zoneName)", category: .cloudKit)
        return
      } catch {
        throw CloudKitError.zoneCreationFailed(error)
      }
    }
  }
}
