import CloudKit
import Foundation

extension CloudKitNetworkService {

  // MARK: - Self Registration

  func registerSelfAsFamilyMember(role: FamilyRole, userRecordID: CKRecord.ID) async {
    guard let zone = await findSharedZoneByName() else {
      Log.error("No shared zone found for self-registration", category: .cloudKit)
      return
    }

    let userRecordName = userRecordID.recordName

    let query = CKQuery(
      recordType: FamilyMember.recordType,
      predicate: NSPredicate(format: "userRecordName == %@", userRecordName)
    )

    do {
      let (results, _) = try await sharedDatabase.records(
        matching: query,
        inZoneWith: zone.zoneID
      )

      for (_, result) in results {
        if case .success(let existingRecord) = result {
          let existingRole = existingRecord[FamilyMember.RecordKey.role] as? String
          if existingRole != role.rawValue {
            existingRecord[FamilyMember.RecordKey.role] = role.rawValue
            _ = try await sharedDatabase.save(existingRecord)
            Log.info("Updated self FamilyMember role to \(role.rawValue)", category: .cloudKit)
          } else {
            Log.debug("Self FamilyMember already exists with correct role", category: .cloudKit)
          }
          return
        }
      }

      let displayName =
        await fetchCurrentUserDisplayName(userRecordID: userRecordID, in: zone.zoneID)
        ?? "Family Member"
      let member = FamilyMember(
        userRecordName: userRecordName,
        displayName: displayName,
        role: role
      )

      let record = member.toCKRecord(in: zone.zoneID)
      _ = try await sharedDatabase.save(record)
      Log.info("Registered self as \(role.rawValue) FamilyMember", category: .cloudKit)
    } catch {
      Log.error("Failed to register self as FamilyMember: \(error)", category: .cloudKit)
    }
  }

  // MARK: - Verification

  func verifySelfFamilyMember(
    cachedUserRecordID: CKRecord.ID?,
    localMode: AppMode
  ) async -> VerificationResult {
    let start = CFAbsoluteTimeGetCurrent()
    Log.info("verifySelfFamilyMember: starting", category: .cloudKit)

    guard let zone = await findSharedZoneByName() else {
      // No shared zone, but still check if iCloud account is available
      // so the UI doesn't show "iCloud Not Available" for signed-in users.
      let accountResult = await checkAccountStatus()
      Log.info(
        "verifySelfFamilyMember: no shared zone, signed in: \(accountResult.isSignedIn) (\(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - start))s)",
        category: .cloudKit)
      return VerificationResult(
        isConnected: false,
        userRecordID: accountResult.userRecordID ?? cachedUserRecordID,
        isSignedIn: accountResult.isSignedIn,
        enforcedMode: nil)
    }
    Log.info(
      "verifySelfFamilyMember: found zone (\(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - start))s)",
      category: .cloudKit)

    let userRecordID: CKRecord.ID
    if let cached = cachedUserRecordID {
      userRecordID = cached
    } else {
      do {
        userRecordID = try await ensureUserRecordID(cached: cachedUserRecordID)
        Log.info(
          "verifySelfFamilyMember: fetched user record ID (\(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - start))s)",
          category: .cloudKit)
      } catch CloudKitError.notSignedIn {
        Log.error(
          "User not signed in during verification", category: .cloudKit)
        return VerificationResult(
          isConnected: true, userRecordID: nil, isSignedIn: false, enforcedMode: nil)
      } catch {
        Log.error(
          "Could not fetch user record ID for verification: \(error)", category: .cloudKit)
        return VerificationResult(
          isConnected: true, userRecordID: nil, isSignedIn: nil, enforcedMode: nil)
      }
    }
    let userRecordName = userRecordID.recordName

    let query = CKQuery(
      recordType: FamilyMember.recordType,
      predicate: NSPredicate(format: "userRecordName == %@", userRecordName)
    )

    do {
      let (results, _) = try await sharedDatabase.records(
        matching: query,
        inZoneWith: zone.zoneID
      )
      Log.info(
        "verifySelfFamilyMember: queried FamilyMember (\(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - start))s)",
        category: .cloudKit)

      for (_, result) in results {
        if case .success(let record) = result {
          guard let recordRoleString = record[FamilyMember.RecordKey.role] as? String,
            let recordRole = FamilyRole(rawValue: recordRoleString)
          else {
            Log.error("FamilyMember record has missing/invalid role", category: .cloudKit)
            return VerificationResult(
              isConnected: true, userRecordID: userRecordID, isSignedIn: true, enforcedMode: nil)
          }

          let cloudKitMode: AppMode = recordRole == .parent ? .parent : .child

          if localMode != cloudKitMode {
            Log.info(
              "Enforced app mode from CloudKit: \(localMode.rawValue) -> \(cloudKitMode.rawValue)",
              category: .cloudKit)
            Log.info(
              "verifySelfFamilyMember: complete (\(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - start))s)",
              category: .cloudKit)
            return VerificationResult(
              isConnected: true, userRecordID: userRecordID, isSignedIn: true,
              enforcedMode: cloudKitMode)
          }

          Log.info(
            "verifySelfFamilyMember: complete (\(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - start))s)",
            category: .cloudKit)
          return VerificationResult(
            isConnected: true, userRecordID: userRecordID, isSignedIn: true, enforcedMode: nil)
        }
      }

      // No FamilyMember record found
      if localMode == .parent || localMode == .child {
        Log.info("No self FamilyMember record found, re-registering", category: .cloudKit)
        let expectedRole: FamilyRole = localMode == .parent ? .parent : .child
        await registerSelfAsFamilyMember(role: expectedRole, userRecordID: userRecordID)
      } else {
        Log.debug(
          "No self FamilyMember record found, staying in individual mode", category: .cloudKit)
      }

      Log.info(
        "verifySelfFamilyMember: complete (\(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - start))s)",
        category: .cloudKit)
      return VerificationResult(
        isConnected: true, userRecordID: userRecordID, isSignedIn: true, enforcedMode: nil)
    } catch {
      Log.error("Failed to verify self FamilyMember record: \(error)", category: .cloudKit)
      Log.info(
        "verifySelfFamilyMember: failed (\(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - start))s)",
        category: .cloudKit)
      return VerificationResult(
        isConnected: true, userRecordID: userRecordID, isSignedIn: true, enforcedMode: nil)
    }
  }

  func fetchCurrentUserDisplayName(
    userRecordID: CKRecord.ID, in zoneID: CKRecordZone.ID
  ) async -> String? {
    do {
      let rootRecordID = CKRecord.ID(recordName: familyRootRecordName, zoneID: zoneID)
      let rootRecord = try await sharedDatabase.record(for: rootRecordID)
      guard let shareRef = rootRecord.share else { return nil }
      let shareRecord = try await sharedDatabase.record(for: shareRef.recordID)
      guard let share = shareRecord as? CKShare else {
        Log.error(
          "Expected CKShare but received \(type(of: shareRecord)) for share reference \(shareRef)",
          category: .cloudKit)
        return nil
      }

      let me = share.participants.first {
        $0.userIdentity.userRecordID?.recordName == userRecordID.recordName
      }
      return me?.userIdentity.nameComponents?.formatted()
    } catch {
      Log.debug("Could not fetch user display name from share: \(error)", category: .cloudKit)
      return nil
    }
  }
}
