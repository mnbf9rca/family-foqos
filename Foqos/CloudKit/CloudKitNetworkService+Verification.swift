import CloudKit
import Foundation

extension CloudKitNetworkService {

  enum SharedPolicyZoneLookup: Equatable, Sendable {
    case present(CKRecordZone.ID)
    case confirmedAbsent
    case indeterminate
  }

  static func resolveSharedPolicyZoneLookup(
    zoneIDsFromSuccessfulLookup zoneIDs: [CKRecordZone.ID]?
  ) -> SharedPolicyZoneLookup {
    guard let zoneIDs else { return .indeterminate }
    guard
      let policyZoneID = zoneIDs.first(where: {
        $0.zoneName == CloudKitConstants.policyZoneName
      })
    else {
      return .confirmedAbsent
    }
    return .present(policyZoneID)
  }

  static func enforcedMode(
    for lookup: SharedPolicyZoneLookup,
    localMode: AppMode,
    accountIsSignedIn: Bool
  ) -> AppMode? {
    guard case .confirmedAbsent = lookup,
      localMode == .child,
      accountIsSignedIn
    else {
      return nil
    }
    return .individual
  }

  private func lookupSharedPolicyZoneForVerification() async -> SharedPolicyZoneLookup {
    do {
      let zones = try await sharedDatabase.allRecordZones()
      return Self.resolveSharedPolicyZoneLookup(
        zoneIDsFromSuccessfulLookup: zones.map(\.zoneID))
    } catch {
      Log.error(
        "Failed to fetch shared zones during verification: \(redactedErrorForLog(error))",
        category: .cloudKit)
      return .indeterminate
    }
  }

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
      Log.error("Failed to register self as FamilyMember: \(redactedErrorForLog(error))", category: .cloudKit)
    }
  }

  // MARK: - Verification

  func verifySelfFamilyMember(
    cachedUserRecordID: CKRecord.ID?,
    localMode: AppMode,
    accountIsSignedIn: Bool
  ) async -> VerificationResult {
    let start = CFAbsoluteTimeGetCurrent()
    Log.info("verifySelfFamilyMember: starting", category: .cloudKit)

    let zoneLookup = await lookupSharedPolicyZoneForVerification()
    guard case .present(let zoneID) = zoneLookup else {
      let enforcedMode = Self.enforcedMode(
        for: zoneLookup,
        localMode: localMode,
        accountIsSignedIn: accountIsSignedIn)
      if enforcedMode == .individual {
        Log.info(
          "verifySelfFamilyMember: shared zone revocation confirmed",
          category: .cloudKit)
      } else {
        Log.info(
          "verifySelfFamilyMember: shared zone unavailable",
          category: .cloudKit)
      }
      return VerificationResult(
        isConnected: false,
        userRecordID: cachedUserRecordID,
        isSignedIn: nil,
        enforcedMode: enforcedMode)
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
          "Could not fetch user record ID for verification: \(redactedErrorForLog(error))", category: .cloudKit)
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
        inZoneWith: zoneID
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
      Log.error("Failed to verify self FamilyMember record: \(redactedErrorForLog(error))", category: .cloudKit)
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
      Log.debug("Could not fetch user display name from share: \(redactedErrorForLog(error))", category: .cloudKit)
      return nil
    }
  }
}
