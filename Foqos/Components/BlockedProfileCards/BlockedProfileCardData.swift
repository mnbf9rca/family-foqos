import FamilyControls
import FoqosShared
import Foundation

// REGRESSION GUARD (#297): BlockedProfileCard / ProfileScheduleRow accept ONLY this value type.
// They can no longer hold a live BlockedProfiles @Model, so a re-render can never read a
// vacated store row. Reintroducing `let profile: BlockedProfiles` on those views is a
// compile-time-visible regression. The runtime proof is
// BlockedProfileCardDataTests.testGivenCardDataThenModelDeletedAndSaved_ThenValuesStillReadableNoTrap.

/// Immutable value snapshot of everything the BlockedProfileCard family renders.
/// NOT a SwiftData model — holding a value (never the live `@Model`) is what makes the
/// card crash-proof against a re-render on a deleted profile (see #297). The compiler now
/// forbids handing the card a live model, which is the regression guard.
struct BlockedProfileCardData {
  let id: UUID
  let name: String
  let isNewerSchemaVersion: Bool
  let enableLiveActivity: Bool
  let hasReminders: Bool
  let enableBreaks: Bool
  let enableStrictMode: Bool
  let blockingStrategyId: String?
  let selectedActivity: FamilyActivitySelection
  let sessionCount: Int
  let domainsCount: Int
  let needsAppSelection: Bool

  let schedule: BlockedProfileSchedule?
  let startTriggers: ProfileStartTriggers
  let stopConditions: ProfileStopConditions
  let startSchedule: ProfileScheduleTime?
  let stopSchedule: ProfileScheduleTime?
  let strategyData: Data?
  let profileSchemaVersion: Int
  let scheduleIsOutOfSync: Bool
}

extension BlockedProfiles {
  /// Build the card snapshot. MUST be called only on a valid (non-zombie) model — callers
  /// gate via `.valid` / `SafeModelView` before invoking. Reads live attributes/relationships.
  ///
  /// TRIPWIRE (#297 edit-propagation): this MUST be evaluated inside an observation-tracked
  /// SwiftUI body (the carousel's `SafeModelView` content closure). Those tracked reads register
  /// the `@Observable` dependencies that make a legitimate edit rebuild the snapshot. Do NOT
  /// memoize it, cache it on the model, or move the call into an `init` / stored property / out of
  /// the render path — that silently stops the card updating on edits while still compiling and
  /// passing the zombie test. Verified by `testGivenModelMutated_WhenCardDataRebuilt_ThenReflectsChange`
  /// and the device-gate edit step.
  var cardData: BlockedProfileCardData {
    cardData(scheduleIsOutOfSync: scheduleIsOutOfSync)
  }

  func cardData(scheduleIsOutOfSync: Bool) -> BlockedProfileCardData {
    BlockedProfileCardData(
      id: id,
      name: name,
      isNewerSchemaVersion: isNewerSchemaVersion,
      enableLiveActivity: enableLiveActivity,
      hasReminders: reminderTimeInSeconds != nil,
      enableBreaks: enableBreaks,
      enableStrictMode: enableStrictMode,
      blockingStrategyId: blockingStrategyId,
      selectedActivity: selectedActivity,
      sessionCount: sessions.count,
      domainsCount: domains?.count ?? 0,
      needsAppSelection: needsAppSelection,
      schedule: schedule,
      startTriggers: startTriggers,
      stopConditions: stopConditions,
      startSchedule: startSchedule,
      stopSchedule: stopSchedule,
      strategyData: strategyData,
      profileSchemaVersion: profileSchemaVersion,
      scheduleIsOutOfSync: scheduleIsOutOfSync
    )
  }
}
