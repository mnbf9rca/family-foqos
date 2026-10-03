import CoreImage
import CoreNFC
import FoqosShared
import XCTest

@testable import FamilyFoqos

@MainActor
final class ProfileTagLinkTests: XCTestCase {
  private let profile = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
  private let key = "0123456789abcdef0123456789abcdef"
  private var url: URL { URL(string: "https://family-foqos.app/profile/\(profile.uuidString)/nfc/\(key)")! }

  func testProfileCommandTrustBoundary() throws {
    let parsed = try ProfileTagLink.parse(url)
    XCTAssertEqual(parsed.profileId, profile)
    XCTAssertEqual(parsed.type, .nfc)
    XCTAssertEqual(parsed.key, key)
    XCTAssertNil(try ProfileTagLink.parse(URL(string: "https://family-foqos.app/profile/\(profile)")!).key)
    let invalid = [
      "http://family-foqos.app", "family-foqos://family-foqos.app",
      "https://evil.example", "https://family-foqos.app.evil.example",
      "https://user@family-foqos.app", "https://family-foqos.app:8443",
    ]
    for base in invalid {
      XCTAssertThrowsError(try ProfileTagLink.parse(URL(string: "\(base)/profile/\(profile)/nfc/\(key)")!))
    }
    for path in [
      "/profile/no-uuid", "/profile/\(profile)/nfc", "/profile/\(profile)/unknown/\(key)",
      "/profile/\(profile)/nfc/short", "/profile/\(profile)/nfc/\(key)/extra",
      "/profile/\(profile)/nfc/\(key)/", "/profile//\(profile)",
      "/profile/\(profile)/nfc/%2f\(key)", "/profile/\(profile)/nfc/%2e%2e",
      "/profile/\(profile)/nfc/\(key.uppercased())",
    ] {
      XCTAssertThrowsError(try ProfileTagLink.parse(URL(string: "https://family-foqos.app\(path)")!), path)
    }
    XCTAssertEqual(try ProfileTagLink.classify(url), .link(profileId: profile))
    let redacted = redactedURLString(url)
    XCTAssertFalse(redacted.contains(profile.uuidString))
    XCTAssertFalse(redacted.contains(key))
    let navigation = NavigationManager()
    navigation.handleLink(URL(string: "https://family-foqos.app/navigate/\(profile)")!)
    XCTAssertEqual(navigation.navigateToProfileId, profile.uuidString)
    XCTAssertTrue(navigation.deliveries.isEmpty)
  }

  func testVerifiedMetadataOnly() throws {
    let activity = MetadataActivity(activityType: NSUserActivityTypeBrowsingWeb)
    activity.webpageURL = url
    activity.referrerURL = URL(string: "https://camera.example")
    XCTAssertEqual(try ProfileTagLink.classify(activity), .link(profileId: profile))
    activity.fixtureNDEF = NFCNDEFMessage(records: [
      NFCNDEFPayload(format: .empty, type: Data(), identifier: Data(), payload: Data())
    ])
    XCTAssertEqual(try ProfileTagLink.classify(activity), .link(profileId: profile))
    activity.fixtureNDEF = NFCNDEFMessage(records: [NFCNDEFPayload.wellKnownTypeURIPayload(url: url)!])
    guard case .tag(let event) = try ProfileTagLink.classify(activity) else { return XCTFail("NFC URI proof lost") }
    XCTAssertEqual(event.type, .nfc)
    XCTAssertEqual(event.key, key)
    activity.fixtureNDEF = NFCNDEFMessage(records: [
      NFCNDEFPayload(format: .absoluteURI, type: Data(url.absoluteString.utf8), identifier: Data(), payload: Data())
    ])
    XCTAssertEqual(try ProfileTagLink.classify(activity), .tag(event))
    activity.fixtureNDEF = NFCNDEFMessage(records: [
      NFCNDEFPayload.wellKnownTypeURIPayload(url: URL(string: "https://family-foqos.app/profile/\(UUID())")!)!
    ])
    XCTAssertThrowsError(try ProfileTagLink.classify(activity))
    activity.fixtureNDEF = NFCNDEFMessage(records: [])
    activity.fixtureBarcode = CIQRCodeDescriptor(payload: Data([1]), symbolVersion: 1, maskPattern: 0, errorCorrectionLevel: .levelL)
    XCTAssertThrowsError(try ProfileTagLink.classify(activity))  // QR proof, NFC payload
    activity.webpageURL = URL(string: "https://family-foqos.app/profile/\(profile)/qr/\(key)")!
    guard case .tag(let qr) = try ProfileTagLink.classify(activity) else { return XCTFail("QR descriptor lost") }
    XCTAssertEqual(qr.type, .qr)
    activity.fixtureNDEF = NFCNDEFMessage(records: [NFCNDEFPayload.wellKnownTypeURIPayload(url: activity.webpageURL!)!])
    XCTAssertThrowsError(try ProfileTagLink.classify(activity))
    activity.fixtureNDEF = NFCNDEFMessage(records: [])
    activity.fixtureBarcode = CIAztecCodeDescriptor(payload: Data([1]), isCompact: true, layerCount: 1, dataCodewordCount: 1)
    XCTAssertEqual(try ProfileTagLink.classify(activity), .link(profileId: profile))
  }

  func testBrowsingActivityPreservesPassiveNavigationWithoutCommands() {
    let navigation = NavigationManager()
    let scene = SceneDelegate(navigation: navigation)
    let activity = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
    activity.webpageURL = URL(string: "https://family-foqos.app/navigate/\(profile)")!
    scene.receiveConnection(activities: [activity], urls: [])
    XCTAssertEqual(navigation.navigateToProfileId, profile.uuidString)
    XCTAssertTrue(navigation.deliveries.isEmpty)
    XCTAssertNil(navigation.deliveryError)
    navigation.clearNavigation()
    scene.receiveActivity(activity)
    XCTAssertNil(navigation.navigateToProfileId)
    let later = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
    later.webpageURL = activity.webpageURL
    scene.receiveActivity(later)
    XCTAssertEqual(navigation.navigateToProfileId, profile.uuidString)
    XCTAssertTrue(navigation.deliveries.isEmpty)
  }

  func testNonCommandURLsStaySilentAcrossSceneRoutes() {
    for text in [
      "https://family-foqos.app", "https://family-foqos.app/",
      "https://family-foqos.app/help", "https://www.icloud.com/share/example",
      "https://evil.example/profile/\(profile)/nfc/\(key)",
    ] {
      let navigation = NavigationManager()
      let scene = SceneDelegate(navigation: navigation)
      let url = URL(string: text)!
      scene.receiveConnection(activities: [], urls: [url])
      scene.receiveURL(url)
      let activity = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
      activity.webpageURL = url
      scene.receiveActivity(activity)
      XCTAssertTrue(navigation.deliveries.isEmpty, text)
      XCTAssertNil(navigation.deliveryError, text)
      XCTAssertNil(navigation.navigateToProfileId, text)
    }
    let navigation = NavigationManager()
    let scene = SceneDelegate(navigation: navigation)
    scene.receiveURL(URL(string: "https://family-foqos.app/profile/bad/nfc/\(key)")!)
    XCTAssertTrue(navigation.deliveries.isEmpty)
    XCTAssertEqual(navigation.deliveryError, ProfileTagLink.Failure.invalidLink.localizedDescription)
  }

  func testMalformedBackgroundNDEFNeverDowngrades() throws {
    let now = Date()
    let malformed = NFCNDEFMessage(records: [
      NFCNDEFPayload(format: .nfcWellKnown, type: Data([0x55]), identifier: Data(), payload: Data())
    ])
    let activity = MetadataActivity(activityType: NSUserActivityTypeBrowsingWeb)
    activity.webpageURL = url
    activity.fixtureNDEF = malformed
    XCTAssertThrowsError(try ProfileTagLink.classify(activity))
    XCTAssertEqual(try NFCResult.read(id: "A0FF", message: malformed, error: nil, now: now).event?.matchingKey, "A0FF")
    let navigation = NavigationManager()
    navigation.handleActivity(activity)
    XCTAssertTrue(navigation.deliveries.isEmpty)
    XCTAssertNotNil(navigation.deliveryError)
  }

  func testBlankNDEFRetainsUIDAndRealReadFailureDoesNot() throws {
    let now = Date()
    let blank = NSError(domain: NFCErrorDomain, code: NFCReaderError.Code.ndefReaderSessionErrorZeroLengthMessage.rawValue)
    XCTAssertEqual((blank as Error as? NFCReaderError)?.code, .ndefReaderSessionErrorZeroLengthMessage)
    XCTAssertEqual(try NFCResult.read(id: "A0FF", message: nil, error: blank, now: now).event?.matchingKey, "A0FF")
    let failed = NSError(domain: NFCErrorDomain, code: NFCReaderError.Code.readerTransceiveErrorTagConnectionLost.rawValue)
    XCTAssertThrowsError(try NFCResult.read(id: "A0FF", message: nil, error: failed, now: now))
  }

  func testThirdPartyContentRetainsLegacyScanIdentities() throws {
    let now = Date()
    let card = URL(string: "https://tapt.io/profile/jane")!
    let message = NFCNDEFMessage(records: [NFCNDEFPayload.wellKnownTypeURIPayload(url: card)!])
    let nfc = try NFCResult.read(id: "A0FF", message: message, error: nil, now: now)
    XCTAssertEqual(nfc.event?.matchingKey, "A0FF")
    XCTAssertNil(nfc.event?.targetProfileId)
    let qr = try QRScanResult.read(card.absoluteString)
    XCTAssertEqual(qr.event?.matchingKey, QRCodeHasher.hash(card.absoluteString))
    XCTAssertNil(qr.event?.targetProfileId)
    let oddURI = NFCNDEFMessage(records: [
      NFCNDEFPayload(format: .absoluteURI, type: Data([0xff]), identifier: Data(), payload: Data())
    ])
    XCTAssertEqual(try NFCResult.read(id: "A0FF", message: oddURI, error: nil, now: now).event?.matchingKey, "A0FF")
    XCTAssertThrowsError(try QRScanResult.read("family-foqos://family-foqos.app/profile/\(profile)/qr/\(key)"))
  }

  func testColdWarmAndDualEntryDeliveryConsumedOnce() throws {
    let navigation = NavigationManager()
    let scene = SceneDelegate(navigation: navigation)
    let activity = MetadataActivity(activityType: NSUserActivityTypeBrowsingWeb)
    activity.webpageURL = url
    activity.fixtureNDEF = NFCNDEFMessage(records: [NFCNDEFPayload.wellKnownTypeURIPayload(url: url)!])
    scene.receiveConnection(activities: [activity], urls: [])
    navigation.receiveSwiftUI(activity)
    navigation.receiveSwiftUI(url)
    scene.receiveActivity(activity)
    XCTAssertEqual(navigation.deliveries.count, 1)  // queued before Home is ready
    guard case .tag(let event) = navigation.takeDelivery() else { return XCTFail("Cold metadata lost") }
    XCTAssertEqual(event.key, key)
    XCTAssertNil(navigation.takeDelivery())
    let later = MetadataActivity(activityType: NSUserActivityTypeBrowsingWeb)
    later.webpageURL = url
    later.fixtureNDEF = activity.ndefMessagePayload
    scene.receiveActivity(later)
    XCTAssertEqual(navigation.deliveries.count, 1)  // identical later payload eligible
    _ = navigation.takeDelivery()
    scene.receiveURL(url)
    XCTAssertEqual(navigation.takeDelivery(), .link(profileId: profile))
  }

  func testScannersRetainCanonicalSignatureTargetAndRawCompatibility() throws {
    let now = Date()
    let message = NFCNDEFMessage(records: [NFCNDEFPayload.wellKnownTypeURIPayload(url: url)!])
    let nfc = try NFCResult.read(id: "A0FF", message: message, error: nil, now: now)
    XCTAssertEqual(nfc.id, "A0FF")
    XCTAssertEqual(nfc.event?.key, key)
    XCTAssertEqual(nfc.event?.targetProfileId, profile)
    XCTAssertEqual(nfc.dateScanned, now)
    XCTAssertEqual(Data([0xa0, 0xff]).hexEncodedString(), "A0FF")
    let legacy = try NFCResult.read(id: "A0FF", message: nil, error: nil, now: now)
    XCTAssertEqual(legacy.event?.key, "A0FF")
    XCTAssertNil(legacy.event?.targetProfileId)
    XCTAssertThrowsError(try NFCResult.read(id: "A0FF", message: message, error: NSError(domain: "read", code: 1), now: now))
    let qrURL = URL(string: "https://family-foqos.app/profile/\(profile)/qr/\(key)")!
    let qr = try QRScanResult.read(qrURL.absoluteString)
    XCTAssertEqual(qr.hash, QRCodeHasher.hash(qrURL.absoluteString))
    XCTAssertEqual(qr.rawHash, QRCodeHasher.rawHash(qrURL.absoluteString))
    XCTAssertEqual(qr.event?.key, key)
    XCTAssertEqual(qr.event?.targetProfileId, profile)
    XCTAssertThrowsError(try QRScanResult.read(url.absoluteString))
    let ordinary = try QRScanResult.read("  HTTPS://EXAMPLE.COM/ ")
    XCTAssertEqual(ordinary.event?.key, QRCodeHasher.hash("  HTTPS://EXAMPLE.COM/ "))
    XCTAssertEqual(ordinary.event?.rawKey, QRCodeHasher.rawHash("  HTTPS://EXAMPLE.COM/ "))
    XCTAssertThrowsError(try QRScanResult.read("https://family-foqos.app/profile/bad/qr/\(key)"))
  }
}

private final class MetadataActivity: NSUserActivity {
  var fixtureNDEF = NFCNDEFMessage(records: [])
  var fixtureBarcode: CIBarcodeDescriptor?
  override var ndefMessagePayload: NFCNDEFMessage { fixtureNDEF }
  override var detectedBarcodeDescriptor: CIBarcodeDescriptor? { fixtureBarcode }
}
