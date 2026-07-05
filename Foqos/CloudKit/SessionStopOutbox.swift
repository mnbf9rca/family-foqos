import Foundation

/// #201: a session-stop CAS write that fails must not be silently dropped. The intent is
/// persisted and re-driven on foreground (minimal outbox, consistent with the funnel/tombstone
/// approach — persisted intent, idempotent re-drive; the underlying stop is CAS-idempotent).
@MainActor
final class SessionStopOutbox {
  private let defaults: UserDefaults
  private let key = "family_foqos_session_stop_outbox"

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  var pending: [UUID] {
    (defaults.array(forKey: key) as? [String] ?? []).compactMap(UUID.init(uuidString:))
  }

  func enqueue(profileId: UUID) {
    var ids = defaults.array(forKey: key) as? [String] ?? []
    let value = profileId.uuidString
    guard !ids.contains(value) else { return }
    ids.append(value)
    defaults.set(ids, forKey: key)
  }

  func remove(profileId: UUID) {
    var ids = defaults.array(forKey: key) as? [String] ?? []
    ids.removeAll { $0 == profileId.uuidString }
    defaults.set(ids, forKey: key)
  }

  func clear() {
    defaults.removeObject(forKey: key)
  }

  /// Re-drive each pending stop; `stop` returns true when the id is resolved (removed).
  func drain(stop: (UUID) async -> Bool) async {
    for id in pending where await stop(id) {
      remove(profileId: id)
    }
  }
}
