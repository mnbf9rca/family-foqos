import CloudKit
import XCTest

@testable import FamilyFoqos

final class SyncEngineEventTests: XCTestCase {
  private func zoneID() -> CKRecordZone.ID {
    CKRecordZone.ID(zoneName: CloudKitConstants.syncZoneName, ownerName: CKCurrentUserDefaultName)
  }

  func testGivenAllEventShapes_WhenConstructed_ThenAssociatedValuesReadBack() {
    let zid = zoneID()
    let recordID = CKRecord.ID(recordName: "p1", zoneID: zid)
    let record = CKRecord(recordType: SyncedProfile.recordType, recordID: recordID)
    let ckError = CKError(.serverRecordChanged)
    let data = Data([0x01, 0x02])

    let events: [SyncEngineEvent] = [
      .stateUpdate(serialization: data),
      .accountChange(kind: .switchAccounts),
      .fetchedDatabaseChanges(
        modifiedZoneIDs: [zid],
        deletedZones: [(zoneID: zid, reason: .purged)]),
      .fetchedRecordZoneChanges(
        modifications: [record],
        deletions: [(recordID: recordID, recordType: SyncedProfile.recordType)]),
      .sentRecordZoneChanges(
        savedRecords: [record],
        failedRecordSaves: [(record: record, error: ckError)],
        deletedRecordIDs: [recordID],
        failedRecordDeletes: [(recordID: recordID, error: ckError)]),
      .sentDatabaseChanges(
        savedZones: [zid],
        failedZoneSaves: [(zone: CKRecordZone(zoneName: CloudKitConstants.syncZoneName), error: ckError)],
        deletedZoneIDs: [zid],
        failedZoneDeletes: [(zoneID: zid, error: ckError)]),
      .willFetchChanges,
      .didFetchChanges,
    ]
    XCTAssertEqual(events.count, 8)

    guard case .stateUpdate(let serialization) = events[0] else { return XCTFail() }
    XCTAssertEqual(serialization, data)

    guard case .fetchedRecordZoneChanges(let mods, let dels) = events[3] else { return XCTFail() }
    XCTAssertEqual(mods.first?.recordID, recordID)
    XCTAssertEqual(dels.first?.recordType, SyncedProfile.recordType)

    guard case .fetchedDatabaseChanges(_, let deletedZones) = events[2] else { return XCTFail() }
    XCTAssertEqual(deletedZones.first?.reason, .purged)
  }

  func testGivenReasonEnums_WhenCompared_ThenCasesAreDistinct() {
    XCTAssertNotEqual(SyncEngineZoneDeletionReason.deleted, .purged)
    XCTAssertNotEqual(SyncEngineZoneDeletionReason.purged, .encryptedDataReset)
    XCTAssertNotEqual(SyncEngineAccountChangeKind.signIn, .switchAccounts)
    XCTAssertNotEqual(SyncEngineAccountChangeKind.signOut, .signIn)
  }
}
