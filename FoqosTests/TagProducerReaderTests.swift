import CoreImage
import CoreNFC
import FoqosShared
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class TagProducerReaderTests: XCTestCase {
  private func profile(type: TagType) -> BlockedProfiles {
    let profile = BlockedProfiles(name: "Focus")
    profile.startTriggers = type == .nfc ? .init(anyNFC: true) : .init(anyQR: true)
    profile.stopConditions = .init(manual: true)
    return profile
  }

  func testActualProducerPayloadsRoundTripThroughBothReaders() throws {
    let now = Date()
    for type in [TagType.nfc, .qr] {
      let profile = profile(type: type)
      let first = try type == .nfc ? NFCWriter.makePayload(for: profile) : QRCodeView.makePayload(for: profile)
      let second = try type == .nfc ? NFCWriter.makePayload(for: profile) : QRCodeView.makePayload(for: profile)
      XCTAssertNotEqual(first.key, second.key)
      XCTAssertEqual(first.key.count, 32)
      let parsed = try ProfileTagLink.parse(first.url)
      XCTAssertEqual(parsed.type, type)
      XCTAssertEqual(parsed.profileId, profile.id)
      XCTAssertEqual(parsed.key, first.key)
      let event: TagEvent
      if type == .nfc {
        event = try XCTUnwrap(NFCResult.read(id: "ABCD", message: NFCWriter.message(for: first), error: nil, now: now).event)
      } else {
        let image = try XCTUnwrap(QRCodeView.image(for: first.url.absoluteString))
        let ciImage = try XCTUnwrap(CIImage(image: image))
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: CIContext(), options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let feature = try XCTUnwrap(detector.features(in: ciImage).first as? CIQRCodeFeature)
        XCTAssertEqual(feature.messageString, first.url.absoluteString)
        event = try XCTUnwrap(QRScanResult.read(try XCTUnwrap(feature.messageString)).event)
        XCTAssertEqual(try QRScanResult.read(first.url.absoluteString).event, event)  // copied/shared payload
      }
      XCTAssertEqual(event.type, type)
      XCTAssertEqual(event.key, first.key)
      XCTAssertEqual(event.targetProfileId, profile.id)
      let activity = ProducerActivity(activityType: NSUserActivityTypeBrowsingWeb)
      activity.webpageURL = first.url
      if type == .nfc { activity.message = NFCWriter.message(for: first) } else { activity.barcode = CIQRCodeDescriptor(payload: Data([1]), symbolVersion: 1, maskPattern: 0, errorCorrectionLevel: .levelL) }
      XCTAssertEqual(try ProfileTagLink.classify(activity), .tag(event))
    }
  }

  func testProducerAdmissionN8() throws {
    for type in [TagType.nfc, .qr] {
      let p = profile(type: type)
      let make = { try type == .nfc ? NFCWriter.makePayload(for: p) : QRCodeView.makePayload(for: p) }
      XCTAssertNoThrow(try make())
      p.startTriggers = type == .nfc ? .init(specificNFC: true) : .init(specificQR: true)
      p.startNFCTagIds = ["existing"]
      p.startQRCodeIds = ["existing"]
      XCTAssertThrowsError(try make()) { error in
        XCTAssertEqual(error.localizedDescription, "This profile isn’t set to start this way. Please edit its start settings.")
      }
      var starts = p.startTriggers
      starts.deepLink = true
      p.startTriggers = starts
      XCTAssertNoThrow(try make())
      XCTAssertEqual(p.startNFCTagIds, ["existing"])
      XCTAssertEqual(p.startQRCodeIds, ["existing"])
    }
    let nfc = profile(type: .nfc)
    XCTAssertThrowsError(try QRCodeView.makePayload(for: nfc))
    XCTAssertFalse(nfc.startTriggers.deepLink)
    XCTAssertTrue(nfc.startQRCodeIds.isEmpty)
  }

  func testCanonicalEnrollmentAndLegacyKeysSurvivePrivateSync() throws {
    let now = Date()
    let container = try TestModelContainer.create()
    let context = container.mainContext
    let p = profile(type: .nfc)
    context.insert(p)
    let payload = try NFCWriter.makePayload(for: p)
    let tag = try NFCWriter.enrollWrittenPayload(payload, name: "Kitchen", in: context)
    XCTAssertEqual(tag.id, "nfc:opaque:\(payload.key)")
    XCTAssertNotEqual(tag.recordName, tag.id)
    XCTAssertEqual(tag.name, "Kitchen")
    let scanned = try XCTUnwrap(NFCResult.read(id: "FFFF", message: NFCWriter.message(for: payload), error: nil, now: now).event)
    XCTAssertEqual(scanned.matchingKey, tag.id)
    p.startNFCTagIds = [tag.id, "A0FF"]
    p.stopQRCodeIds = ["old-digest"]
    try context.save()
    let record = SyncedProfile(from: p, originDeviceId: "device-A")
    XCTAssertEqual(record.startNFCTagIds, [tag.id, "A0FF"])
    XCTAssertEqual(record.stopQRCodeIds, ["old-digest"])
    XCTAssertEqual(try NFCResult.read(id: "A0FF", message: nil, error: nil, now: now).event?.matchingKey, "A0FF")
    let before = try SavedTag.fetchAll(in: context).count
    XCTAssertThrowsError(try SavedTag.enroll(event: TagEvent(type: .nfc, namespace: nil, key: nil, unidentifiedLegacyTag: true), name: "Bad", in: context))
    XCTAssertEqual(try SavedTag.fetchAll(in: context).count, before)
  }
}

private final class ProducerActivity: NSUserActivity {
  var message = NFCNDEFMessage(records: [])
  var barcode: CIBarcodeDescriptor?
  override var ndefMessagePayload: NFCNDEFMessage { message }
  override var detectedBarcodeDescriptor: CIBarcodeDescriptor? { barcode }
}
