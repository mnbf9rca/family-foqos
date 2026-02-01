import CloudKit
import Foundation

/// Represents the authoritative session state for a single profile.
/// There is exactly ONE of these records per profile in CloudKit.
/// All devices read/write to this same record using CAS for consistency.
struct ProfileSessionRecord: Codable, Equatable {

  // MARK: - Identity

  let profileId: UUID

  /// Deterministic record name based on profile ID
  var recordName: String {
    "ProfileSession_\(profileId.uuidString)"
  }

  // MARK: - Session State

  private(set) var isActive: Bool = false
  private(set) var sequenceNumber: Int = 0
  private(set) var startTime: Date?
  private(set) var endTime: Date?
  private(set) var breakStartTime: Date?
  private(set) var breakEndTime: Date?

  // MARK: - Tracking

  /// Device that last modified this record
  private(set) var lastModifiedBy: String = ""

  /// Device that started the current session (nil if not active)
  private(set) var sessionOriginDevice: String?

  /// When this record was last updated
  private(set) var lastModified: Date = Date()

  // MARK: - CloudKit

  static let recordType = "ProfileSession"

  enum FieldKey: String {
    case profileId
    case isActive
    case sequenceNumber
    case startTime
    case endTime
    case breakStartTime
    case breakEndTime
    case lastModifiedBy
    case sessionOriginDevice
    case lastModified
  }

  // MARK: - Initialization

  init(profileId: UUID) {
    self.profileId = profileId
  }

  init?(from record: CKRecord) {
    guard record.recordType == Self.recordType,
      let profileIdString = record[FieldKey.profileId.rawValue] as? String,
      let profileId = UUID(uuidString: profileIdString)
    else {
      return nil
    }

    self.profileId = profileId
    self.isActive = record[FieldKey.isActive.rawValue] as? Bool ?? false
    self.sequenceNumber = record[FieldKey.sequenceNumber.rawValue] as? Int ?? 0
    self.startTime = record[FieldKey.startTime.rawValue] as? Date
    self.endTime = record[FieldKey.endTime.rawValue] as? Date
    self.breakStartTime = record[FieldKey.breakStartTime.rawValue] as? Date
    self.breakEndTime = record[FieldKey.breakEndTime.rawValue] as? Date
    self.lastModifiedBy = record[FieldKey.lastModifiedBy.rawValue] as? String ?? ""
    self.sessionOriginDevice = record[FieldKey.sessionOriginDevice.rawValue] as? String
    self.lastModified = record[FieldKey.lastModified.rawValue] as? Date ?? Date()
  }

  // MARK: - State Updates

  /// Apply an update to this record. Returns true if applied, false if rejected (stale).
  @discardableResult
  mutating func applyUpdate(
    isActive: Bool,
    sequenceNumber: Int,
    deviceId: String,
    startTime: Date? = nil,
    endTime: Date? = nil,
    breakStartTime: Date? = nil,
    breakEndTime: Date? = nil
  ) -> Bool {
    // Reject stale updates
    guard sequenceNumber > self.sequenceNumber else {
      return false
    }

    self.isActive = isActive
    self.sequenceNumber = sequenceNumber
    self.lastModifiedBy = deviceId
    self.lastModified = Date()

    if isActive && self.startTime == nil {
      // New session starting
      self.startTime = startTime ?? Date()
      self.endTime = nil
      self.sessionOriginDevice = deviceId
      self.breakStartTime = nil
      self.breakEndTime = nil
    } else if !isActive {
      // Session ending
      self.endTime = endTime ?? Date()
    }

    // Update break times if provided
    if let breakStart = breakStartTime {
      self.breakStartTime = breakStart
    }
    if let breakEnd = breakEndTime {
      self.breakEndTime = breakEnd
    }

    return true
  }

  /// Reset for a new session (clears previous session data)
  mutating func resetForNewSession() {
    self.startTime = nil
    self.endTime = nil
    self.breakStartTime = nil
    self.breakEndTime = nil
    self.sessionOriginDevice = nil
  }

  // MARK: - CloudKit Conversion

  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    updateCKRecord(record)
    return record
  }

  func updateCKRecord(_ record: CKRecord) {
    record[FieldKey.profileId.rawValue] = profileId.uuidString
    record[FieldKey.isActive.rawValue] = isActive
    record[FieldKey.sequenceNumber.rawValue] = sequenceNumber
    record[FieldKey.startTime.rawValue] = startTime
    record[FieldKey.endTime.rawValue] = endTime
    record[FieldKey.breakStartTime.rawValue] = breakStartTime
    record[FieldKey.breakEndTime.rawValue] = breakEndTime
    record[FieldKey.lastModifiedBy.rawValue] = lastModifiedBy
    record[FieldKey.sessionOriginDevice.rawValue] = sessionOriginDevice
    record[FieldKey.lastModified.rawValue] = lastModified
  }
}
