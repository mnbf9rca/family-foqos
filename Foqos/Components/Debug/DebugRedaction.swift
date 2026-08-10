import Foundation

/// #247: child-mode redaction for Debug Mode values that are replayable credentials.
enum DebugRedaction {
  private static let shortNFCTagMask = "••••••"
  private static let lowercaseHexDigits = CharacterSet(charactersIn: "0123456789abcdef")

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

  /// #247 deliberate asymmetry: QR values have three forms. A 64-lowercase-hex value is the
  /// SHA-256 digest and stays visible; legacy plaintext is replayable and gets the same mask as NFC.
  static func physicalUnblockQRCodeIdForDisplay(_ raw: String?, mode: AppMode) -> String? {
    guard let raw else { return nil }
    guard mode == .child else { return raw }
    guard !isLowercaseHexDigest(raw) else { return raw }

    return maskCredential(raw)
  }

  private static func maskCredential(_ raw: String) -> String {
    guard raw.count >= 8 else { return shortNFCTagMask }

    return "\(raw.prefix(2))…\(raw.suffix(2))"
  }

  private static func isLowercaseHexDigest(_ raw: String) -> Bool {
    guard raw.count == 64 else { return false }
    return raw.unicodeScalars.allSatisfy { lowercaseHexDigits.contains($0) }
  }
}
