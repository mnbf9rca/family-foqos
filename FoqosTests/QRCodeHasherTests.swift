// FoqosTests/QRCodeHasherTests.swift
import CryptoKit
import XCTest

@testable import FamilyFoqos

final class QRCodeHasherTests: XCTestCase {

  func testGivenString_WhenHashing_ThenReturns64CharHexString() {
    let hash = QRCodeHasher.hash("https://example.com/unlock")
    XCTAssertEqual(hash.count, 64)
    XCTAssertTrue(hash.allSatisfy { $0.isHexDigit })
  }

  func testGivenSameInput_WhenHashedTwice_ThenReturnsSameResult() {
    let hash1 = QRCodeHasher.hash("test-qr-value")
    let hash2 = QRCodeHasher.hash("test-qr-value")
    XCTAssertEqual(hash1, hash2)
  }

  func testGivenDifferentInputs_WhenHashing_ThenReturnsDifferentResults() {
    let hash1 = QRCodeHasher.hash("code-a")
    let hash2 = QRCodeHasher.hash("code-b")
    XCTAssertNotEqual(hash1, hash2)
  }

  func testGivenEmptyString_WhenHashing_ThenReturnsValidHash() {
    let hash = QRCodeHasher.hash("")
    XCTAssertEqual(hash.count, 64)
  }

  func testGivenKnownInput_WhenHashing_ThenMatchesExpectedSHA256() {
    let hash = QRCodeHasher.hash("hello")
    XCTAssertEqual(hash, "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
  }
  func testNormalizationPreservesEverythingExceptWhitespaceSchemeHostAndBareSlash() {
    let cases = [
      (" \nHTTPS://EXAMPLE.COM/\t", "https://example.com"),
      ("HTTPS://EXAMPLE.COM", "https://example.com"),
      ("  plain Text  ", "plain Text"),
      (" \n\t", ""),
      ("  /Relative/Path/ ", "/Relative/Path/"),
      (" MAILTO:Name@EXAMPLE.COM ", "MAILTO:Name@EXAMPLE.COM"),
      (" HTTPS:///Path/ ", "HTTPS:///Path/"),
      ("HTTPS://User:Pass@EXAMPLE.COM:8443/Path/", "https://User:Pass@example.com:8443/Path/"),
      ("HTTPS://EXAMPLE.COM/%2f/%2F?Q=%2b#Frag%2f", "https://example.com/%2f/%2F?Q=%2b#Frag%2f"),
      ("HTTPS://EXAMPLE.COM/?", "https://example.com/?"),
      ("HTTPS://EXAMPLE.COM/#", "https://example.com/#"),
      ("HTTPS://EXAMPLE.COM/?#", "https://example.com/?#"),
      ("HTTPS://EXAMPLE.COM/?Q=Value", "https://example.com/?Q=Value"),
      ("HTTPS://EXAMPLE.COM/#Fragment", "https://example.com/#Fragment"),
    ]
    for (payload, normalized) in cases {
      let expected = SHA256.hash(data: Data(normalized.utf8))
        .map { String(format: "%02x", $0) }.joined()
      XCTAssertEqual(QRCodeHasher.hash(payload), expected, payload)
    }
  }

}
