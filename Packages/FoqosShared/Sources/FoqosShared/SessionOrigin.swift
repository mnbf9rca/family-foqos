import Foundation

public struct SessionOrigin: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable { case manual, nfc, qr, shortcut, link, schedule }
  public enum KeyNamespace: String, Codable, Sendable { case nfcUID, qrDigest, opaque }

  public var kind: Kind
  public var key: String?
  public var namespace: KeyNamespace?
  public var unidentifiedLegacyTag: Bool?

  public init(kind: Kind, key: String? = nil, namespace: KeyNamespace? = nil, unidentifiedLegacyTag: Bool = false) {
    self.kind = kind
    self.key = key
    self.namespace = namespace
    self.unidentifiedLegacyTag = unidentifiedLegacyTag ? true : nil
  }

  public var initiatingKey: String? {
    if kind == .nfc || kind == .qr, namespace == .opaque, let key,
      key.count == 32, key.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    {
      return kind.rawValue + ":opaque:" + key
    }
    guard (kind == .nfc && namespace == .nfcUID) || (kind == .qr && namespace == .qrDigest),
      let key, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }
    return key
  }
}
