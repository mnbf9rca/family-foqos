// Foqos/Utils/QRCodeHasher.swift
import CryptoKit
import Foundation

/// Normalizes QR payloads, then uses SHA-256 to reduce arbitrary-length scanned data
/// to a fixed 64-character hex string for storage and comparison across devices.
/// This is NOT a security measure — it's a size constraint (QR payloads can be large).
enum QRCodeHasher {
  static func hash(_ value: String) -> String {
    rawHash(normalized(value))
  }

  private static func normalized(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard var components = URLComponents(string: trimmed),
      let scheme = components.scheme, !scheme.isEmpty,
      let host = components.host, !host.isEmpty
    else { return trimmed }

    components.scheme = scheme.lowercased()
    components.host = host.lowercased()
    if components.percentEncodedPath == "/" && components.query == nil && components.fragment == nil {
      components.path = ""
    }
    return components.string ?? trimmed
  }

  static func rawHash(_ value: String) -> String {
    let data = Data(value.utf8)
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}
