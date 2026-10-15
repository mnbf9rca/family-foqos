import FoqosShared
import Foundation
import SwiftData

@MainActor
enum OrphanedSessionCleanup {
  enum Failure: Error { case activeSession }

  @discardableResult
  static func run(
    context: ModelContext,
    retryLock: Bool = false,
    requireInactive: Bool = false,
    publishedActiveOwner: UUID? = nil,
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
    let hasPublishedActiveSession = publishedActiveOwner.map { profileIds.contains($0) } ?? false
    let hasLocalActiveSession = hasPublishedActiveSession || profiles.contains { $0.sessions.valid.contains { $0.isActive } }
    var refusedActiveSession = false
    guard
      let removed = SharedData.removeProfileSessions(
        where: { !profileIds.contains($0) }, retryLock: retryLock, discardUnreadableSessions: requireInactive,
        rebuildUnreadableProfiles: requireInactive ? { Dictionary(uniqueKeysWithValues: profiles.map { ($0.id.uuidString, BlockedProfiles.getSnapshot(for: $0)) }) } : nil,
        allowRemoval: { shared in
          refusedActiveSession = requireInactive && (hasLocalActiveSession || (shared.map { $0.endTime == nil && profileIds.contains($0.blockedProfileId) } ?? false))
          return !refusedActiveSession
        }, onRemoveActive: deactivateRestrictions, onCommit: onCommit)
    else {
      if refusedActiveSession { throw Failure.activeSession }
      throw CocoaError(.fileWriteUnknown)
    }
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
