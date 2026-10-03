import Foundation

public struct SessionOrigin: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable { case manual, nfc, qr, shortcut, link, schedule }
  public enum KeyNamespace: String, Codable, Sendable { case nfcUID, qrDigest }

  public var kind: Kind
  public var key: String?
  public var namespace: KeyNamespace?

  public init(kind: Kind, key: String? = nil, namespace: KeyNamespace? = nil) {
    self.kind = kind
    self.key = key
    self.namespace = namespace
  }

  public var initiatingKey: String? {
    guard (kind == .nfc && namespace == .nfcUID) || (kind == .qr && namespace == .qrDigest),
      let key, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }
    return key
  }
}
