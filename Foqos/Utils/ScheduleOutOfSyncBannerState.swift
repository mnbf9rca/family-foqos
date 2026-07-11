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
