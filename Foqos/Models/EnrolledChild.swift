import CloudKit
import Foundation

/// Represents a child enrolled in the parent's family policy system
struct EnrolledChild: Codable, Identifiable, Equatable {
    var id: UUID
    var userRecordName: String  // CKRecord.ID.recordName of the child
    var displayName: String     // Parent-assigned name (e.g., "Emma", "Jake")
    var enrolledAt: Date
    var isActive: Bool

    init(
        id: UUID = UUID(),
        userRecordName: String,
        displayName: String,
        enrolledAt: Date = Date(),
        isActive: Bool = true
    ) {
        self.id = id
        self.userRecordName = userRecordName
        self.displayName = displayName
        self.enrolledAt = enrolledAt
        self.isActive = isActive
    }
}

// MARK: - CloudKit Record Conversion

extension EnrolledChild {
    static let recordType = "EnrolledChild"

    private enum RecordKey {
        static let id = "id"
        static let userRecordName = "userRecordName"
        static let displayName = "displayName"
        static let enrolledAt = "enrolledAt"
        static let isActive = "isActive"
    }

    /// Create an EnrolledChild from a CKRecord
    init?(from record: CKRecord) {
        guard record.recordType == EnrolledChild.recordType,
              let idString = record[RecordKey.id] as? String,
              let id = UUID(uuidString: idString),
              let userRecordName = record[RecordKey.userRecordName] as? String,
              let displayName = record[RecordKey.displayName] as? String,
              let enrolledAt = record[RecordKey.enrolledAt] as? Date
        else {
            return nil
        }

        self.id = id
        self.userRecordName = userRecordName
        self.displayName = displayName
        self.enrolledAt = enrolledAt
        self.isActive = (record[RecordKey.isActive] as? Int ?? 1) == 1
    }

    /// Convert to a CKRecord for saving to CloudKit
    func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
        let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
        let record = CKRecord(recordType: EnrolledChild.recordType, recordID: recordID)

        record[RecordKey.id] = id.uuidString
        record[RecordKey.userRecordName] = userRecordName
        record[RecordKey.displayName] = displayName
        record[RecordKey.enrolledAt] = enrolledAt
        record[RecordKey.isActive] = isActive ? 1 : 0

        // Set parent reference to FamilyRoot for share hierarchy
        let familyRootID = CKRecord.ID(recordName: "FamilyRoot", zoneID: zoneID)
        record.parent = CKRecord.Reference(recordID: familyRootID, action: .none)

        return record
    }
}
