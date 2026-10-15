import FoqosShared
import Foundation
import SwiftData

@MainActor
enum OrphanedSessionCleanup {
  private static let completionKey = "family_foqos_orphaned_session_cleanup_v1"

  static func runIfNeeded(
    context: ModelContext,
    defaults: UserDefaults = .standard,
    save: (ModelContext) throws -> Void = { try $0.save() },
    removeActivities: (UUID) -> Void = { DeviceActivityCenterUtil.removeActivities(for: $0) },
    deactivateRestrictions: () -> Void = { AppBlockerUtil().deactivateRestrictions() }
  ) throws {
    guard !defaults.bool(forKey: completionKey) else { return }
    let profiles = try context.fetch(FetchDescriptor<BlockedProfiles>())
    let sessions = try context.fetch(FetchDescriptor<BlockedProfileSession>())
    let profileIds = Set(profiles.map(\.id))
    // Use the surviving owners, never fault a deleted session's nonoptional relationship.
    let ownedSessionIds = Set(profiles.flatMap { $0.sessions.valid.map(\.id) })
    guard
      let removed = SharedData.removeProfileSessions(
        where: { !profileIds.contains($0) }, onRemoveActive: deactivateRestrictions)
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
    defaults.set(true, forKey: completionKey)
  }
}
