import Foundation

/// #201: a session-stop CAS write that fails must not be silently dropped. The intent is
/// persisted and re-driven on foreground (minimal outbox, consistent with the funnel/tombstone
/// approach — persisted intent, idempotent re-drive; the underlying stop is CAS-idempotent).
@MainActor
final class SessionStopOutbox {
  private let defaults: UserDefaults
  private let key = "family_foqos_session_stop_outbox"
  private let expectedIdsKey = "family_foqos_session_stop_outbox_expected_ids"
  private let expectedStartsKey = "family_foqos_session_stop_outbox_expected_starts"

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  var pending: [UUID] {
    (defaults.array(forKey: key) as? [String] ?? []).compactMap(UUID.init(uuidString:))
  }

  func expectedStart(for profileId: UUID) -> Date? {
    defaults.dictionary(forKey: expectedStartsKey)?[profileId.uuidString] as? Date
  }

  func expectedSessionId(for profileId: UUID) -> String? {
    defaults.dictionary(forKey: expectedIdsKey)?[profileId.uuidString] as? String
  }

  func enqueue(profileId: UUID, expectedStart: Date? = nil, expectedSessionId: String? = nil) {
    var ids = defaults.array(forKey: key) as? [String] ?? []
    let value = profileId.uuidString
    var starts = defaults.dictionary(forKey: expectedStartsKey) ?? [:]
    var sessionIds = defaults.dictionary(forKey: expectedIdsKey) ?? [:]
    // Never weaken a pending exact intent into a profile-only legacy stop.
    if let expectedSessionId { sessionIds[value] = expectedSessionId } else if sessionIds[value] != nil { return }
    defaults.set(sessionIds, forKey: expectedIdsKey)
    starts[value] = expectedStart
    defaults.set(starts, forKey: expectedStartsKey)
    guard !ids.contains(value) else { return }
    ids.append(value)
    defaults.set(ids, forKey: key)
  }

  func remove(profileId: UUID) {
    var ids = defaults.array(forKey: key) as? [String] ?? []
    ids.removeAll { $0 == profileId.uuidString }
    defaults.set(ids, forKey: key)
    var sessionIds = defaults.dictionary(forKey: expectedIdsKey) ?? [:]
    sessionIds.removeValue(forKey: profileId.uuidString)
    defaults.set(sessionIds, forKey: expectedIdsKey)
    var starts = defaults.dictionary(forKey: expectedStartsKey) ?? [:]
    starts.removeValue(forKey: profileId.uuidString)
    defaults.set(starts, forKey: expectedStartsKey)
  }

  func clear() {
    defaults.removeObject(forKey: expectedIdsKey)
    defaults.removeObject(forKey: key)
    defaults.removeObject(forKey: expectedStartsKey)
  }

  /// Re-drive each pending stop; `stop` returns true when the id is resolved (removed).
  func drain(stop: (UUID, String?, Date?) async -> Bool) async {
    for id in pending {
      let expectedId = expectedSessionId(for: id)
      let start = expectedStart(for: id)
      if await stop(id, expectedId, start), expectedSessionId(for: id) == expectedId, expectedStart(for: id) == start {
        remove(profileId: id)
      }
    }
  }
}
