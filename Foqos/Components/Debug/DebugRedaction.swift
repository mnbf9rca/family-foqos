import Foundation

/// Scanner log redaction; tag-list debug displays use names instead of scanned values.
enum DebugRedaction {
  static func physicalUnblockNFCTagIdForLog(_ raw: String) -> String {
    guard raw.count >= 8 else { return "••••••" }
    return "\(raw.prefix(2))…\(raw.suffix(2))"
  }
}
