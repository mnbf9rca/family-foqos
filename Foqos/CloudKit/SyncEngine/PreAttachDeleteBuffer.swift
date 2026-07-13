import Foundation

/// Durable, non-user-namespaced buffer for delete intents formed before the per-user
/// `SyncEngineStore` exists. Drained into store tombstones when `attachEngine` builds the store.
@MainActor
enum PreAttachDeleteBuffer {
  static let defaultsKey = "family_foqos_pending_preattach_deletes"

  static func add(_ recordName: String, defaults: UserDefaults = .standard) {
    var names = Set(defaults.stringArray(forKey: defaultsKey) ?? [])
    names.insert(recordName)
    defaults.set(Array(names), forKey: defaultsKey)
  }

  static func pending(defaults: UserDefaults = .standard) -> [String] {
    defaults.stringArray(forKey: defaultsKey) ?? []
  }

  static func acknowledge(_ recordName: String, defaults: UserDefaults = .standard) {
    var names = Set(defaults.stringArray(forKey: defaultsKey) ?? [])
    names.remove(recordName)
    if names.isEmpty {
      defaults.removeObject(forKey: defaultsKey)
    } else {
      defaults.set(Array(names), forKey: defaultsKey)
    }
  }

  static func drainAll(defaults: UserDefaults = .standard) -> [String] {
    let names = defaults.stringArray(forKey: defaultsKey) ?? []
    defaults.removeObject(forKey: defaultsKey)
    return names
  }
}
