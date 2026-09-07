import Foundation

/// The value is an NFC hardware id or the SHA-256 hex of a QR payload.
struct PhysicalKey: Codable, Equatable, Identifiable {
  var name: String
  var value: String
  var id: String { value }
}

struct ProfilePhysicalKeys: Codable, Equatable {
  var startNFC: [PhysicalKey] = []
  var startQR: [PhysicalKey] = []
  var stopNFC: [PhysicalKey] = []
  var stopQR: [PhysicalKey] = []

  func normalized() -> Self {
    func normalize(_ keys: [PhysicalKey], defaultName: String) -> [PhysicalKey] {
      var seen = Set<String>()
      return keys.compactMap { key in
        guard !key.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          seen.insert(key.value).inserted
        else { return nil }
        var key = key
        if key.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          key.name = defaultName
        }
        return key
      }
    }
    return Self(
      startNFC: normalize(startNFC, defaultName: "NFC tag"),
      startQR: normalize(startQR, defaultName: "QR code"),
      stopNFC: normalize(stopNFC, defaultName: "NFC tag"),
      stopQR: normalize(stopQR, defaultName: "QR code"))
  }

  static func decode(_ data: Data?) -> Self? {
    guard let data else { return nil }
    do {
      return try JSONDecoder().decode(Self.self, from: data)
    } catch {
      // Decoding errors can include the input; never log physical key values.
      Log.error("Failed to decode physical keys", category: .sync)
      return nil
    }
  }

  static func reconcile(base: [PhysicalKey], legacy: String?, defaultName: String) -> [PhysicalKey] {
    guard let legacy else { return base }
    if base.first?.value == legacy { return base }
    let promoted = base.first { $0.value == legacy } ?? PhysicalKey(name: defaultName, value: legacy)
    return [promoted] + base.filter { $0.value != legacy }
  }

  func reconciled(startNFC: String?, startQR: String?, stopNFC: String?, stopQR: String?) -> Self {
    Self(
      startNFC: Self.reconcile(base: self.startNFC, legacy: startNFC, defaultName: "NFC tag"),
      startQR: Self.reconcile(base: self.startQR, legacy: startQR, defaultName: "QR code"),
      stopNFC: Self.reconcile(base: self.stopNFC, legacy: stopNFC, defaultName: "NFC tag"),
      stopQR: Self.reconcile(base: self.stopQR, legacy: stopQR, defaultName: "QR code")
    ).normalized()
  }
}
