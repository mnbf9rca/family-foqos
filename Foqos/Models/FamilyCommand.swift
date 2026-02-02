import CloudKit
import Foundation

/// Command types that can be sent from parent to child
enum FamilyCommandType: String, Codable {
  case resetEmergencyCount
}

/// Represents a command from parent to child device via CloudKit
struct FamilyCommand: Codable, Identifiable {
  var id: UUID
  var commandType: FamilyCommandType
  var targetChildId: String  // userRecordName of the target child
  var createdAt: Date
  var createdBy: String  // userRecordName of the parent who created it

  init(
    id: UUID = UUID(),
    commandType: FamilyCommandType,
    targetChildId: String,
    createdBy: String,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.commandType = commandType
    self.targetChildId = targetChildId
    self.createdBy = createdBy
    self.createdAt = createdAt
  }

  /// Generate deterministic record name for idempotent commands
  /// Using this prevents duplicate commands when parent taps button multiple times
  /// Includes parentId to allow multiple parents to send commands to the same child
  static func recordName(commandType: FamilyCommandType, targetChildId: String, parentId: String) -> String {
    "\(commandType.rawValue)-\(targetChildId)-\(parentId)"
  }
}

// MARK: - CloudKit Record Conversion

extension FamilyCommand {
  static let recordType = "FamilyCommand"

  private enum RecordKey {
    static let id = "id"
    static let commandType = "commandType"
    static let targetChildId = "targetChildId"
    static let createdAt = "createdAt"
    static let createdBy = "createdBy"
  }

  /// Create a FamilyCommand from a CKRecord
  init?(from record: CKRecord) {
    guard record.recordType == FamilyCommand.recordType,
      let idString = record[RecordKey.id] as? String,
      let id = UUID(uuidString: idString),
      let commandTypeString = record[RecordKey.commandType] as? String,
      let commandType = FamilyCommandType(rawValue: commandTypeString),
      let targetChildId = record[RecordKey.targetChildId] as? String,
      let createdAt = record[RecordKey.createdAt] as? Date,
      let createdBy = record[RecordKey.createdBy] as? String
    else {
      return nil
    }

    self.id = id
    self.commandType = commandType
    self.targetChildId = targetChildId
    self.createdAt = createdAt
    self.createdBy = createdBy
  }

  /// Convert to a CKRecord for saving to CloudKit
  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordName = FamilyCommand.recordName(
      commandType: commandType, targetChildId: targetChildId, parentId: createdBy)
    let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
    let record = CKRecord(recordType: FamilyCommand.recordType, recordID: recordID)

    record[RecordKey.id] = id.uuidString
    record[RecordKey.commandType] = commandType.rawValue
    record[RecordKey.targetChildId] = targetChildId
    record[RecordKey.createdAt] = createdAt
    record[RecordKey.createdBy] = createdBy

    // Set parent reference to FamilyRoot for share hierarchy
    let familyRootID = CKRecord.ID(recordName: "FamilyRoot", zoneID: zoneID)
    record.parent = CKRecord.Reference(recordID: familyRootID, action: .none)

    return record
  }
}
