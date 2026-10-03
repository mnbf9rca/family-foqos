import CoreImage
import CoreNFC
import FoqosShared
import Foundation

enum TagType: String, Equatable, Sendable { case nfc, qr }

struct ParsedProfileLink: Equatable, Sendable {
  let profileId: UUID
  let type: TagType?
  let key: String?
}

struct TagEvent: Equatable, Sendable {
  let type: TagType
  let namespace: SessionOrigin.KeyNamespace?
  let key: String?
  var targetProfileId: UUID? = nil
  var rawKey: String? = nil
  var unidentifiedLegacyTag = false

  var matchingKey: String? {
    key.map { namespace == .opaque ? "\(type.rawValue):opaque:\($0)" : $0 }
  }

  var origin: SessionOrigin {
    .init(
      kind: type == .nfc ? .nfc : .qr, key: key, namespace: namespace,
      unidentifiedLegacyTag: unidentifiedLegacyTag)
  }
}

struct ProfileTagPayload: Equatable, Sendable {
  let profileId: UUID
  let type: TagType
  let key: String

  init(profileId: UUID, type: TagType) {
    self.profileId = profileId
    self.type = type
    self.key = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
  }

  var url: URL { ProfileTagLink.make(profileId: profileId, type: type, key: key) }
  var event: TagEvent { TagEvent(type: type, namespace: .opaque, key: key, targetProfileId: profileId) }

  @MainActor
  static func prepare(for profile: BlockedProfiles, type: TagType) throws -> ProfileTagPayload {
    let starts = profile.startTriggers
    // A fresh random key cannot already belong to a Specific key set.
    guard starts.deepLink || (type == .nfc ? starts.anyNFC : starts.anyQR) else {
      throw NSError(
        domain: "TagProducer", code: 1,
        userInfo: [
          NSLocalizedDescriptionKey:
            "This profile isn’t set to start this way. Please edit its start settings."
        ])
    }
    return ProfileTagPayload(profileId: profile.id, type: type)
  }
}

enum ProfileTagLink {
  enum Delivery: Equatable, Sendable {
    case tag(TagEvent)
    case link(profileId: UUID)
  }

  enum Failure: LocalizedError {
    case invalidTag, invalidLink
    case read(TagType)
    var errorDescription: String? {
      switch self {
      case .invalidTag: return "This profile link isn’t valid. Please use another tag or code."
      case .invalidLink: return "This profile link isn't valid. Please use a different link."
      case .read(.nfc): return "Couldn’t read that NFC tag. Please try again."
      case .read(.qr): return "Couldn’t read that QR code. Please try again."
      }
    }
  }

  static func parse(_ url: URL) throws -> ParsedProfileLink {
    guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
      c.scheme?.lowercased() == "https", c.host?.lowercased() == "family-foqos.app",
      c.user == nil, c.password == nil, c.port == nil,
      !c.percentEncodedPath.contains("%")
    else { throw Failure.invalidLink }
    let parts = c.path.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 3 || parts.count == 5, parts[0].isEmpty, parts[1] == "profile",
      let id = UUID(uuidString: String(parts[2]))
    else { throw Failure.invalidLink }
    if parts.count == 3 { return ParsedProfileLink(profileId: id, type: nil, key: nil) }
    guard let type = TagType(rawValue: String(parts[3])), usableKey(String(parts[4])) else {
      throw Failure.invalidLink
    }
    return ParsedProfileLink(profileId: id, type: type, key: String(parts[4]))
  }

  static func usableKey(_ key: String) -> Bool {
    key.count == 32 && key.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }

  static func make(profileId: UUID, type: TagType, key: String) -> URL {
    precondition(usableKey(key))
    return URL(string: "https://family-foqos.app/profile/\(profileId.uuidString)/\(type.rawValue)/\(key)")!
  }

  static func classify(_ url: URL) throws -> Delivery {
    .link(profileId: try parse(url).profileId)
  }

  static func classify(_ activity: NSUserActivity) throws -> Delivery {
    guard activity.activityType == NSUserActivityTypeBrowsingWeb, let url = activity.webpageURL else {
      throw Failure.invalidLink
    }
    let uris = try uriURLs(activity.ndefMessagePayload)
    let nfc = uris.contains(url)
    let qr = activity.detectedBarcodeDescriptor is CIQRCodeDescriptor
    guard !(nfc && qr), uris.isEmpty || nfc else { throw Failure.invalidTag }
    guard nfc || qr else { return try classify(url) }
    let parsed: ParsedProfileLink
    do { parsed = try parse(url) } catch { throw Failure.invalidTag }
    let type: TagType = nfc ? .nfc : .qr
    guard parsed.type == nil || parsed.type == type else { throw Failure.invalidTag }
    return .tag(
      TagEvent(
        type: type, namespace: parsed.key == nil ? nil : .opaque,
        key: parsed.key, targetProfileId: parsed.profileId,
        unidentifiedLegacyTag: parsed.key == nil))
  }

  static func uriURLs(_ message: NFCNDEFMessage?, requireValidRecords: Bool = true) throws -> [URL] {
    try (message?.records ?? []).compactMap { record in
      if record.typeNameFormat == .nfcWellKnown, record.type == Data([0x55]) {
        guard record.payload.count > 1, let url = record.wellKnownTypeURIPayload(), url.scheme != nil else {
          if requireValidRecords { throw Failure.invalidTag }
          return nil
        }
        return url
      }
      if record.typeNameFormat == .absoluteURI {
        guard let text = String(data: record.type, encoding: .utf8), let url = URL(string: text), url.scheme != nil else {
          if requireValidRecords { throw Failure.invalidTag }
          return nil
        }
        return url
      }
      return nil
    }
  }

  /// Ordinary content retains UID/digest matching; any recognized profile path must validate.
  static func scannedEvent(type: TagType, urls: [URL], legacyKey: String, rawKey: String? = nil) throws -> TagEvent {
    let profileURLs = urls.filter {
      $0.host?.lowercased() == "family-foqos.app" && ($0.path == "/profile" || $0.path.hasPrefix("/profile/"))
    }
    guard let url = profileURLs.first else {
      return TagEvent(type: type, namespace: type == .nfc ? .nfcUID : .qrDigest, key: legacyKey, rawKey: rawKey)
    }
    guard profileURLs.allSatisfy({ $0 == url }) else { throw Failure.invalidTag }
    let parsed: ParsedProfileLink
    do { parsed = try parse(url) } catch { throw Failure.invalidTag }
    guard parsed.type == nil || parsed.type == type else { throw Failure.invalidTag }
    return TagEvent(
      type: type, namespace: parsed.key == nil ? (type == .nfc ? .nfcUID : .qrDigest) : .opaque,
      key: parsed.key ?? legacyKey, targetProfileId: parsed.profileId,
      rawKey: parsed.key == nil ? rawKey : nil)
  }
}
