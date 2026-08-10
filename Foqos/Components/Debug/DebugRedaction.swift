import Foundation

/// #247: child-mode redaction for Debug Mode values that are replayable credentials.
enum DebugRedaction {
  private static let shortNFCTagMask = "••••••"

  /// Masks the physical-unblock NFC UID in Child mode because the stored UID is replayable.
  static func physicalUnblockNFCTagIdForDisplay(_ raw: String?, mode: AppMode) -> String? {
    guard let raw else { return nil }
    guard mode == .child else { return raw }
    return maskCredential(raw)
  }

  /// Log files can be exported later, so replayable NFC credentials are always masked.
  static func physicalUnblockNFCTagIdForLog(_ raw: String) -> String {
    maskCredential(raw)
  }

  /// Masks physical-unblock QR values in Child mode, including stored SHA-256 digests.
  static func physicalUnblockQRCodeIdForDisplay(_ raw: String?, mode: AppMode) -> String? {
    guard let raw else { return nil }
    guard mode == .child else { return raw }

    return maskCredential(raw)
  }

  private static func maskCredential(_ raw: String) -> String {
    guard raw.count >= 8 else { return shortNFCTagMask }

    return "\(raw.prefix(2))…\(raw.suffix(2))"
  }
}
