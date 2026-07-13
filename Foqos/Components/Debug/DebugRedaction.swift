import Foundation

/// #247: child-mode redaction for Debug Mode values that are replayable credentials.
enum DebugRedaction {
  private static let shortNFCTagMask = "••••••"

  /// Masks only the physical-unblock NFC UID in Child mode. The QR value is deliberately not
  /// handled here: the stored QR value is a SHA-256 digest, and scanner code compares
  /// `sha256(scanned) == digest`, so the displayed digest is preimage-resistant and non-replayable.
  static func physicalUnblockNFCTagIdForDisplay(_ raw: String?, mode: AppMode) -> String? {
    guard let raw else { return nil }
    guard mode == .child else { return raw }
    guard raw.count >= 8 else { return shortNFCTagMask }

    return "\(raw.prefix(2))…\(raw.suffix(2))"
  }
}
