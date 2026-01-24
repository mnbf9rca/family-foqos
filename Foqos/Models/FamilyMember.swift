import CloudKit
import Foundation

/// Role of a family member in the Family Foqos system
enum FamilyRole: String, Codable, CaseIterable, Identifiable {
    case parent
    case child

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .parent:
            return "Parent"
        case .child:
            return "Child"
        }
    }

    var iconName: String {
        switch self {
        case .parent:
            return "person.fill"
        case .child:
            return "face.smiling.fill"
        }
    }

    var description: String {
        switch self {
        case .parent:
            return "Can view and manage lock codes, create managed profiles on children's devices"
        case .child:
            return "Subject to managed profiles, needs lock code to edit them"
        }
    }
}

/// Represents a family member enrolled in the Family Foqos system
struct FamilyMember: Codable, Identifiable, Equatable {
    var id: UUID
    var userRecordName: String  // CKRecord.ID.recordName of the member
    var displayName: String     // Name (e.g., "Emma", "Dad")
    var role: FamilyRole        // Parent or child
    var enrolledAt: Date
    var isActive: Bool

    init(
        id: UUID = UUID(),
        userRecordName: String,
        displayName: String,
        role: FamilyRole,
        enrolledAt: Date = Date(),
        isActive: Bool = true
    ) {
        self.id = id
        self.userRecordName = userRecordName
        self.displayName = displayName
        self.role = role
        self.enrolledAt = enrolledAt
        self.isActive = isActive
    }

}

// MARK: - CloudKit Record Conversion

extension FamilyMember {
    static let recordType = "FamilyMember"

    private enum RecordKey {
        static let id = "id"
        static let userRecordName = "userRecordName"
        static let displayName = "displayName"
        static let role = "role"
        static let enrolledAt = "enrolledAt"
        static let isActive = "isActive"
    }

    /// Create a FamilyMember from a CKRecord
    init?(from record: CKRecord) {
        guard record.recordType == FamilyMember.recordType,
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

        // Parse role, default to child for backwards compatibility
        if let roleString = record[RecordKey.role] as? String,
           let role = FamilyRole(rawValue: roleString) {
            self.role = role
        } else {
            self.role = .child
        }
    }

    /// Convert to a CKRecord for saving to CloudKit
    func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
        let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
        let record = CKRecord(recordType: FamilyMember.recordType, recordID: recordID)

        record[RecordKey.id] = id.uuidString
        record[RecordKey.userRecordName] = userRecordName
        record[RecordKey.displayName] = displayName
        record[RecordKey.role] = role.rawValue
        record[RecordKey.enrolledAt] = enrolledAt
        record[RecordKey.isActive] = isActive ? 1 : 0

        // Set parent reference to FamilyRoot for share hierarchy
        let familyRootID = CKRecord.ID(recordName: "FamilyRoot", zoneID: zoneID)
        record.parent = CKRecord.Reference(recordID: familyRootID, action: .none)

        return record
    }
}

// MARK: - Convenience Extensions

extension Array where Element == FamilyMember {
    /// Filter to only parents
    var parents: [FamilyMember] {
        filter { $0.role == .parent }
    }

    /// Filter to only children
    var children: [FamilyMember] {
        filter { $0.role == .child }
    }
}
