// Foqos/Utils/QRCodeHasher.swift
import CryptoKit
import Foundation

/// Hashes QR code values using SHA-256 so they're stored as opaque identifiers
enum QRCodeHasher {
  static func hash(_ value: String) -> String {
    let data = Data(value.utf8)
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}
