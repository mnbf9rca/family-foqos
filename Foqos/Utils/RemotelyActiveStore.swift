import Foundation

@MainActor
enum RemotelyActiveStore {
  static let defaultsKey = "family_foqos_remotely_active_profiles"

  static func load(defaults: UserDefaults = .standard) -> Set<UUID> {
    let strings = defaults.stringArray(forKey: defaultsKey) ?? []
    return Set(strings.compactMap(UUID.init(uuidString:)))
  }

  static func save(_ ids: Set<UUID>, defaults: UserDefaults = .standard) {
    defaults.set(ids.map(\.uuidString), forKey: defaultsKey)
  }
}
