import SwiftData
import XCTest

@testable import FamilyFoqos

final class PhysicalKeyTests: XCTestCase {
  private let keys = [PhysicalKey(name: "Home", value: "X"), PhysicalKey(name: "Spare", value: "Y")]

  func testLegacyReadIsDeterministic() {
    let profile = BlockedProfiles(name: "Legacy")
    profile.stopNFCTagId = "X"
    XCTAssertEqual(profile.physicalKeys, ProfilePhysicalKeys(stopNFC: [PhysicalKey(name: "NFC tag", value: "X")]))
    XCTAssertEqual(profile.physicalKeys, profile.physicalKeys)
  }

  func testSetterPersistsBothKeysAndMirrorsPrimaryThenClears() throws {
    let profile = BlockedProfiles(name: "Keys")
    profile.physicalKeys = ProfilePhysicalKeys(stopNFC: keys)
    XCTAssertEqual(profile.stopNFCTagId, "X")
    let path = try physicalKeysStoragePath()
    let data = try XCTUnwrap(profile[keyPath: path])
    XCTAssertEqual(try JSONDecoder().decode(ProfilePhysicalKeys.self, from: data).stopNFC, keys)
    profile.physicalKeys = ProfilePhysicalKeys()
    XCTAssertNil(profile.stopNFCTagId)
    XCTAssertEqual(profile.physicalKeys.stopNFC, [])
  }

  func testMalformedBlobFallsBackToLegacy() throws {
    let profile = BlockedProfiles(name: "Legacy")
    profile.stopNFCTagId = "X"
    let path = try physicalKeysStoragePath()
    profile[keyPath: path] = Data("invalid".utf8)
    XCTAssertEqual(profile.physicalKeys, ProfilePhysicalKeys(stopNFC: [PhysicalKey(name: "NFC tag", value: "X")]))
  }

  func testNormalizationDropsBlankValuesAndLaterDuplicates() {
    let list = keys + [PhysicalKey(name: "Duplicate", value: "X"), PhysicalKey(name: "Blank", value: " \n"), PhysicalKey(name: "Empty", value: "")]
    XCTAssertEqual(ProfilePhysicalKeys(startNFC: list, startQR: list, stopNFC: list, stopQR: list).normalized(), ProfilePhysicalKeys(startNFC: keys, startQR: keys, stopNFC: keys, stopQR: keys))
  }

  func testReconcilePreservesSparesAndPromotesPrimary() {
    XCTAssertEqual(ProfilePhysicalKeys.reconcile(base: [], legacy: nil, defaultName: "NFC tag"), [])
    XCTAssertEqual(ProfilePhysicalKeys.reconcile(base: keys, legacy: nil, defaultName: "NFC tag"), keys)
    XCTAssertEqual(ProfilePhysicalKeys.reconcile(base: keys, legacy: "X", defaultName: "NFC tag"), keys)
    XCTAssertEqual(ProfilePhysicalKeys.reconcile(base: keys, legacy: "Y", defaultName: "NFC tag"), [keys[1], keys[0]])
    XCTAssertEqual(ProfilePhysicalKeys.reconcile(base: keys, legacy: "Z", defaultName: "NFC tag"), [PhysicalKey(name: "NFC tag", value: "Z")] + keys)
    XCTAssertEqual(ProfilePhysicalKeys.reconcile(base: [], legacy: "Z", defaultName: "QR code"), [PhysicalKey(name: "QR code", value: "Z")])
  }

  func testEncodingRoundTrip() throws {
    let value = ProfilePhysicalKeys(startNFC: keys, startQR: keys.reversed(), stopNFC: keys, stopQR: keys)
    XCTAssertEqual(try JSONDecoder().decode(ProfilePhysicalKeys.self, from: JSONEncoder().encode(value)), value)
  }
  // Exercise corrupt persisted data without exposing the model's private storage in production.
  private func physicalKeysStoragePath() throws -> ReferenceWritableKeyPath<BlockedProfiles, Data?> {
    for metadata in BlockedProfiles.schemaMetadata {
      let fields = Mirror(reflecting: metadata).children
      if fields.first(where: { $0.label == "name" })?.value as? String == "physicalKeysData" {
        return try XCTUnwrap(fields.first(where: { $0.label == "keypath" })?.value as? ReferenceWritableKeyPath<BlockedProfiles, Data?>)
      }
    }
    throw NSError(domain: "PhysicalKeyTests.missingStorage", code: 1)
  }

}
