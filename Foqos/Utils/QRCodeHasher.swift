// Foqos/Utils/QRCodeHasher.swift
import CryptoKit
import Foundation

/// Hashes QR code values using SHA-256 to normalize arbitrary-length scanned data
/// to a fixed 64-character hex string for storage and comparison across devices.
/// This is NOT a security measure — it's a size constraint (QR payloads can be large).
enum QRCodeHasher {
  static func hash(_ value: String) -> String {
    let data = Data(value.utf8)
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}
