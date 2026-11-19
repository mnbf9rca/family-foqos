import Foundation

/// Persist exact stop intents until CloudKit confirms each stopped session is resolved.
@MainActor
final class SessionStopOutbox {
  struct Intent: Codable, Equatable {
    let profileId: UUID
    let expectedSessionId: String?
    let expectedStart: Date?
    var allowRemoteLegacy: Bool? = nil
    var endTime: Date? = nil
  }

  private let defaults: UserDefaults
  private let key = "family_foqos_session_stop_outbox"
  private let expectedIdsKey = "family_foqos_session_stop_outbox_expected_ids"
  private let expectedStartsKey = "family_foqos_session_stop_outbox_expected_starts"
  private let intentsKey = "family_foqos_session_stop_intents"

  init(defaults: UserDefaults = .standard) { self.defaults = defaults }

  // A damaged queue cannot authorize a new start or a destructive overwrite.
  var intents: [Intent]? {
    if defaults.object(forKey: intentsKey) != nil {
      guard let data = defaults.data(forKey: intentsKey) else {
        Log.error("Cannot read pending session stops", category: .sync)
        return nil
      }
      do { return try JSONDecoder().decode([Intent].self, from: data) } catch {
        Log.error("Cannot decode pending session stops", category: .sync)
        return nil
      }
    }
    return (defaults.array(forKey: key) as? [String] ?? []).compactMap { value in
      guard let profileId = UUID(uuidString: value) else { return nil }
      return Intent(
        profileId: profileId,
        expectedSessionId: defaults.dictionary(forKey: expectedIdsKey)?[value] as? String,
        expectedStart: defaults.dictionary(forKey: expectedStartsKey)?[value] as? Date)
    }
  }

  var pending: [UUID] {
    (intents ?? []).reduce(into: []) { ids, intent in
      if !ids.contains(intent.profileId) { ids.append(intent.profileId) }
    }
  }

  func expectedStart(for profileId: UUID) -> Date? {
    intents?.first { $0.profileId == profileId }?.expectedStart
  }

  func expectedSessionId(for profileId: UUID) -> String? {
    intents?.first { $0.profileId == profileId }?.expectedSessionId
  }

  @discardableResult
  private func save(_ intents: [Intent]) -> Bool {
    do {
      let data = try JSONEncoder().encode(intents)
      defaults.set(data, forKey: intentsKey)
      return defaults.data(forKey: intentsKey) == data
    } catch {
      Log.error("Cannot encode pending session stops", category: .sync)
      return false
    }
  }

  @discardableResult
  func enqueue(
    profileId: UUID, expectedStart: Date? = nil, expectedSessionId: String? = nil,
    allowRemoteLegacy: Bool = false, endTime: Date? = nil
  ) -> Bool {
    guard var queued = intents else { return false }
    let intent = Intent(
      profileId: profileId, expectedSessionId: expectedSessionId, expectedStart: expectedStart,
      allowRemoteLegacy: allowRemoteLegacy ? true : nil, endTime: endTime)
    if let index = queued.firstIndex(where: {
      $0.profileId == profileId && $0.expectedSessionId == expectedSessionId
        && (expectedSessionId != nil || $0.expectedStart == expectedStart)
    }) {
      if queued[index].endTime == nil, let endTime {
        queued[index].endTime = endTime
        return save(queued)
      }
      return true
    }
    if expectedSessionId == nil, expectedStart == nil,
      queued.contains(where: { $0.profileId == profileId && ($0.expectedSessionId != nil || $0.expectedStart != nil) })
    {
      return false
    }
    // An exact stop supersedes a profile-only intent, never a different identity.
    if expectedSessionId != nil || expectedStart != nil {
      queued.removeAll { $0.profileId == profileId && $0.expectedSessionId == nil && $0.expectedStart == nil }
    }
    queued.append(intent)
    return save(queued)
  }

  func resolve(profileId: UUID, expectedSessionId: String?, expectedStart: Date?) {
    guard var queued = intents else { return }
    queued.removeAll { $0.profileId == profileId && $0.expectedSessionId == expectedSessionId && $0.expectedStart == expectedStart }
    save(queued)
  }

  func removeLegacyIntents(profileId: UUID) {
    guard var queued = intents else { return }
    queued.removeAll { $0.profileId == profileId && $0.expectedSessionId == nil && $0.expectedStart == nil }
    save(queued)
  }

  func remove(profileId: UUID) {
    guard var queued = intents else { return }
    queued.removeAll { $0.profileId == profileId }
    save(queued)
  }

  func clear() {
    for value in [key, expectedIdsKey, expectedStartsKey, intentsKey] { defaults.removeObject(forKey: value) }
  }

  /// Drain a captured FIFO; resolving an attempt cannot remove an intent queued during its await.
  func drain(stop: (UUID, String?, Date?) async -> Bool) async {
    guard let queued = intents else { return }
    for intent in queued {
      if await stop(intent.profileId, intent.expectedSessionId, intent.expectedStart) {
        resolve(profileId: intent.profileId, expectedSessionId: intent.expectedSessionId, expectedStart: intent.expectedStart)
      }
    }
  }
}
