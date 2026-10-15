import Foundation

@MainActor
enum RemotelyActiveStore {
  static let defaultsKey = "family_foqos_remotely_active_profiles"
  private static let recordsKey = "family_foqos_remote_session_records"

  static func load(defaults: UserDefaults = .standard) -> [UUID: ProfileSessionRecord] {
    defaults.removeObject(forKey: defaultsKey)
    let entries = defaults.dictionary(forKey: recordsKey) ?? [:]
    var records: [UUID: ProfileSessionRecord] = [:]
    for (key, value) in entries {
      guard let id = UUID(uuidString: key), let data = value as? Data,
        let record = try? JSONDecoder().decode(ProfileSessionRecord.self, from: data), record.profileId == id
      else {
        Log.error("Could not load a synced session record", category: .sync)
        continue
      }
      records[id] = record
    }
    return records
  }

  static func save(_ records: [UUID: ProfileSessionRecord], defaults: UserDefaults = .standard) {
    do {
      let entries = try Dictionary(uniqueKeysWithValues: records.map { ($0.key.uuidString, try JSONEncoder().encode($0.value)) })
      defaults.set(entries, forKey: recordsKey)
    } catch {
      Log.error("Could not save synced session records", category: .sync)
    }
  }
}
