import FoqosShared
import Foundation
import SwiftData

@MainActor
enum OrphanedSessionCleanup {
  @discardableResult
  static func run(
    context: ModelContext,
    retryLock: Bool = false,
    requireInactive: Bool = false,
    save: (ModelContext) throws -> Void = { try $0.save() },
    removeActivities: (UUID) -> Void = { DeviceActivityCenterUtil.removeActivities(for: $0) },
    deactivateRestrictions: () -> Void = { AppBlockerUtil().deactivateRestrictions() },
    onCommit: () -> Void = {}
  ) throws -> Set<UUID> {
    let profiles = try context.fetch(FetchDescriptor<BlockedProfiles>())
    let sessions = try context.fetch(FetchDescriptor<BlockedProfileSession>())
    let profileIds = Set(profiles.map(\.id))
    // Use the surviving owners, never fault a deleted session's nonoptional relationship.
    let ownedSessionIds = Set(profiles.flatMap { $0.sessions.valid.map(\.id) })
    let hasLocalActiveSession = profiles.contains { $0.sessions.valid.contains { $0.isActive } }
    guard
      let removed = SharedData.removeProfileSessions(
        where: { !profileIds.contains($0) }, retryLock: retryLock,
        allowRemoval: { shared in
          !requireInactive || (!hasLocalActiveSession && !(shared.map { $0.endTime == nil && profileIds.contains($0.blockedProfileId) } ?? false))
        }, onRemoveActive: deactivateRestrictions, onCommit: onCommit)
    else { throw CocoaError(.fileWriteUnknown) }
    for id in removed {
      removeActivities(id)
      TimersUtil.cancelAllPreActivationReminders(for: id)
      TimersUtil.cancelOwnedReminders(for: id)
    }
    for session in sessions where !ownedSessionIds.contains(session.id) {
      context.delete(session)
    }
    try save(context)
    return profileIds
  }
}
