import CloudKit
import CryptoKit
import Foundation

/// Scope for a lock code - can apply to all children or a specific child
enum LockCodeScope: Codable, Equatable {
    case allChildren
    case specificChild(childId: String)

    var displayName: String {
        switch self {
        case .allChildren:
            return "All Children"
        case .specificChild:
            return "Specific Child"
        }
    }
}

/// A lock code that parents set to protect managed profiles on child devices
struct FamilyLockCode: Codable, Identifiable, Equatable {
    var id: UUID
    var codeHash: String  // SHA256 hash of the PIN
    var codeSalt: String  // Salt used for hashing
    var scope: LockCodeScope
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        code: String,
        scope: LockCodeScope = .allChildren
    ) {
        self.id = id
        self.scope = scope
        self.createdAt = Date()
        self.updatedAt = Date()

        // Generate salt and hash
        self.codeSalt = FamilyLockCode.generateSalt()
        self.codeHash = FamilyLockCode.hashCode(code, salt: self.codeSalt)
    }

    /// Update the code
    mutating func updateCode(_ newCode: String) {
        self.codeSalt = FamilyLockCode.generateSalt()
        self.codeHash = FamilyLockCode.hashCode(newCode, salt: self.codeSalt)
        self.updatedAt = Date()
    }

    /// Verify if a provided code matches
    func verifyCode(_ code: String) -> Bool {
        let hashedInput = FamilyLockCode.hashCode(code, salt: codeSalt)
        return hashedInput == codeHash
    }

    // MARK: - Hashing Utilities

    private static func generateSalt() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }

    private static func hashCode(_ code: String, salt: String) -> String {
        let combined = code + salt
        let data = Data(combined.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - CloudKit Record Conversion

extension FamilyLockCode {
    static let recordType = "FamilyLockCode"

    private enum RecordKey {
        static let id = "id"
        static let codeHash = "codeHash"
        static let codeSalt = "codeSalt"
        static let scopeType = "scopeType"  // "all" or "specific"
        static let scopeChildId = "scopeChildId"  // Only set if scope is specific
        static let createdAt = "createdAt"
        static let updatedAt = "updatedAt"
    }

    /// Create a FamilyLockCode from a CKRecord
    init?(from record: CKRecord) {
        guard record.recordType == FamilyLockCode.recordType,
              let idString = record[RecordKey.id] as? String,
              let id = UUID(uuidString: idString),
              let codeHash = record[RecordKey.codeHash] as? String,
              let codeSalt = record[RecordKey.codeSalt] as? String,
              let createdAt = record[RecordKey.createdAt] as? Date,
              let updatedAt = record[RecordKey.updatedAt] as? Date
        else {
            return nil
        }

        self.id = id
        self.codeHash = codeHash
        self.codeSalt = codeSalt
        self.createdAt = createdAt
        self.updatedAt = updatedAt

        // Parse scope
        let scopeType = record[RecordKey.scopeType] as? String ?? "all"
        if scopeType == "specific", let childId = record[RecordKey.scopeChildId] as? String {
            self.scope = .specificChild(childId: childId)
        } else {
            self.scope = .allChildren
        }
    }

    /// Convert to a CKRecord for saving to CloudKit
    func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
        let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
        let record = CKRecord(recordType: FamilyLockCode.recordType, recordID: recordID)

        record[RecordKey.id] = id.uuidString
        record[RecordKey.codeHash] = codeHash
        record[RecordKey.codeSalt] = codeSalt
        record[RecordKey.createdAt] = createdAt
        record[RecordKey.updatedAt] = updatedAt

        // Set parent reference to FamilyRoot for share hierarchy
        let familyRootID = CKRecord.ID(recordName: "FamilyRoot", zoneID: zoneID)
        record.parent = CKRecord.Reference(recordID: familyRootID, action: .none)

        // Set scope
        switch scope {
        case .allChildren:
            record[RecordKey.scopeType] = "all"
        case .specificChild(let childId):
            record[RecordKey.scopeType] = "specific"
            record[RecordKey.scopeChildId] = childId
        }

        return record
    }
}
