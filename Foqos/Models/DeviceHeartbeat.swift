import CloudKit
import Foundation

/// Heartbeat record written by child devices on profile activation.
/// Parent monitors freshness to detect permission revocation or app removal.
struct DeviceHeartbeat: Codable, Identifiable {
  var id: String {
    DeviceHeartbeat.recordName(
      childUserRecordName: childUserRecordName, deviceIdentifier: deviceIdentifier)
  }
  var childUserRecordName: String
  var deviceIdentifier: String
  var deviceName: String
  var lastHeartbeatAt: Date
  var authorizationStatus: String

  static let recordType = "DeviceHeartbeat"

  static func recordName(childUserRecordName: String, deviceIdentifier: String) -> String {
    "heartbeat-\(childUserRecordName)-\(deviceIdentifier)"
  }
}

// MARK: - CloudKit Record Conversion

extension DeviceHeartbeat {
  private enum RecordKey {
    static let childUserRecordName = "childUserRecordName"
    static let deviceIdentifier = "deviceIdentifier"
    static let deviceName = "deviceName"
    static let lastHeartbeatAt = "lastHeartbeatAt"
    static let authorizationStatus = "authorizationStatus"
  }

  init?(from record: CKRecord) {
    guard record.recordType == DeviceHeartbeat.recordType,
      let childUserRecordName = record[RecordKey.childUserRecordName] as? String,
      let deviceIdentifier = record[RecordKey.deviceIdentifier] as? String,
      let deviceName = record[RecordKey.deviceName] as? String,
      let lastHeartbeatAt = record[RecordKey.lastHeartbeatAt] as? Date,
      let authorizationStatus = record[RecordKey.authorizationStatus] as? String
    else {
      return nil
    }

    self.childUserRecordName = childUserRecordName
    self.deviceIdentifier = deviceIdentifier
    self.deviceName = deviceName
    self.lastHeartbeatAt = lastHeartbeatAt
    self.authorizationStatus = authorizationStatus
  }

  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordName = DeviceHeartbeat.recordName(
      childUserRecordName: childUserRecordName, deviceIdentifier: deviceIdentifier)
    let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
    let record = CKRecord(recordType: DeviceHeartbeat.recordType, recordID: recordID)

    record[RecordKey.childUserRecordName] = childUserRecordName
    record[RecordKey.deviceIdentifier] = deviceIdentifier
    record[RecordKey.deviceName] = deviceName
    record[RecordKey.lastHeartbeatAt] = lastHeartbeatAt
    record[RecordKey.authorizationStatus] = authorizationStatus

    let familyRootID = CKRecord.ID(recordName: "FamilyRoot", zoneID: zoneID)
    record.parent = CKRecord.Reference(recordID: familyRootID, action: .none)

    return record
  }
}
