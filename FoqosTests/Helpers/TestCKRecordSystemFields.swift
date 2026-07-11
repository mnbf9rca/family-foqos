import CloudKit

@testable import FamilyFoqos

enum TestCKRecordSystemFields {
  static func encodedProfile(recordName: String) -> Data {
    let zoneID = CKRecordZone.ID(
      zoneName: CloudKitConstants.syncZoneName,
      ownerName: CKCurrentUserDefaultName
    )
    let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
    let record = CKRecord(recordType: SyncedProfile.recordType, recordID: recordID)
    return CKRecordSystemFieldsCodec.encode(record)
  }
}
