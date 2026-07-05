import CloudKit
import Foundation

/// Archives / restores a CKRecord's system fields (recordID + server change tag) as Data
/// for the `systemFields[user]` cache (§2.1). Reader: RecordProvider. Writer: SyncApplyService.
enum CKRecordSystemFieldsCodec {
  static func encode(_ record: CKRecord) -> Data {
    let coder = NSKeyedArchiver(requiringSecureCoding: true)
    record.encodeSystemFields(with: coder)
    coder.finishEncoding()
    return coder.encodedData
  }

  static func decode(_ data: Data) -> CKRecord? {
    guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else {
      return nil
    }
    coder.requiresSecureCoding = true
    let record = CKRecord(coder: coder)
    coder.finishDecoding()
    return record
  }
}
