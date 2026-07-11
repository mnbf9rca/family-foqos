import Foundation

struct ScheduleOutOfSyncBannerState {
  var isVisible: Bool = false

  mutating func refresh(
    profile: BlockedProfiles?,
    isOutOfSync: (BlockedProfiles) -> Bool = { $0.scheduleIsOutOfSync }
  ) {
    isVisible = Self.shouldShow(profile: profile, isOutOfSync: isOutOfSync)
  }

  mutating func refreshAfterScheduleReconcile(
    profile: BlockedProfiles?,
    isOutOfSync: (BlockedProfiles) -> Bool = { $0.scheduleIsOutOfSync }
  ) {
    refresh(profile: profile, isOutOfSync: isOutOfSync)
  }

  static func shouldShow(
    profile: BlockedProfiles?,
    isOutOfSync: (BlockedProfiles) -> Bool = { $0.scheduleIsOutOfSync }
  ) -> Bool {
    guard let profile else { return false }
    return isOutOfSync(profile)
  }
}

struct ScheduleOutOfSyncCardState {
  var visibilityByProfileId: [UUID: Bool] = [:]

  mutating func refresh(
    profiles: [BlockedProfiles],
    isOutOfSync: (BlockedProfiles) -> Bool = { $0.scheduleIsOutOfSync }
  ) {
    visibilityByProfileId = Dictionary(
      uniqueKeysWithValues: profiles.map { ($0.id, isOutOfSync($0)) })
  }

  mutating func refreshAfterScheduleReconcile(
    profiles: [BlockedProfiles],
    isOutOfSync: (BlockedProfiles) -> Bool = { $0.scheduleIsOutOfSync }
  ) {
    refresh(profiles: profiles, isOutOfSync: isOutOfSync)
  }

  func isOutOfSync(
    for profile: BlockedProfiles,
    fallback: (BlockedProfiles) -> Bool = { $0.scheduleIsOutOfSync }
  ) -> Bool {
    visibilityByProfileId[profile.id] ?? fallback(profile)
  }
}
