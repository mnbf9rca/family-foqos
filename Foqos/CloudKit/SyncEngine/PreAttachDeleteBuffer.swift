import Foundation

/// Durable buffer for delete intents formed before the per-user `SyncEngineStore` exists.
/// Entries carry best-effort user provenance so attach only promotes names for the resolved user.
@MainActor
enum PreAttachDeleteBuffer {
  static let defaultsKey = "family_foqos_pending_preattach_deletes"

  struct PendingDelete: Codable, Equatable {
    var recordName: String
    var userRecordName: String?
  }

  static func add(
    _ recordName: String,
    userRecordName: String? = nil,
    defaults: UserDefaults = .standard
  ) {
    var entries = pending(defaults: defaults)
    let entry = PendingDelete(recordName: recordName, userRecordName: userRecordName)
    guard !entries.contains(entry) else { return }
    entries.append(entry)
    save(entries, defaults: defaults)
  }

  static func acknowledge(_ recordName: String, defaults: UserDefaults = .standard) {
    let entries = pending(defaults: defaults).filter { $0.recordName != recordName }
    save(entries, defaults: defaults)
  }

  static func acknowledge(
    _ recordName: String,
    userRecordName: String?,
    defaults: UserDefaults = .standard
  ) {
    let entries = pending(defaults: defaults).filter {
      !($0.recordName == recordName && $0.userRecordName == userRecordName)
    }
    save(entries, defaults: defaults)
  }

  static func pending(defaults: UserDefaults = .standard) -> [PendingDelete] {
    if let data = defaults.data(forKey: defaultsKey),
      let entries = try? JSONDecoder().decode([PendingDelete].self, from: data)
    {
      return entries
    }
    return (defaults.stringArray(forKey: defaultsKey) ?? []).map {
      PendingDelete(recordName: $0, userRecordName: nil)
    }
  }

  static func drainAll(defaults: UserDefaults = .standard) -> [String] {
    let names = pending(defaults: defaults).map(\.recordName)
    defaults.removeObject(forKey: defaultsKey)
    return names
  }

  private static func save(_ entries: [PendingDelete], defaults: UserDefaults) {
    if entries.isEmpty {
      defaults.removeObject(forKey: defaultsKey)
    } else {
      defaults.set(try? JSONEncoder().encode(entries), forKey: defaultsKey)
    }
  }
}
