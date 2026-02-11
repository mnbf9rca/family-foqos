import AppIntents
import SwiftData

struct CheckProfileStatusIntent: AppIntent {
  @Dependency(key: "ModelContainer")
  private var modelContainer: ModelContainer

  @MainActor
  private var modelContext: ModelContext {
    return modelContainer.mainContext
  }

  @Parameter(title: "Profile") var profile: BlockedProfileEntity

  nonisolated(unsafe) static var title: LocalizedStringResource = "Family Foqos Profile Status"  // SAFETY: AppIntents requires static var; immutable after init
  nonisolated(unsafe) static var description = IntentDescription(  // SAFETY: AppIntents requires static var; immutable after init
    "Check if a Family Foqos profile is currently active and return the status as a boolean value.")

  @MainActor
  func perform() async throws -> some IntentResult & ReturnsValue<Bool> & ProvidesDialog {
    let strategyManager = StrategyManager.shared

    do {
      try strategyManager.loadActiveSession(context: modelContext)
    } catch {
      throw IntentError.unexpected("Failed to load session data")
    }

    let isActive = strategyManager.activeSession?.blockedProfile.id == profile.id

    let dialogMessage =
      isActive
      ? "\(profile.name) is currently active."
      : "\(profile.name) is not active."

    return .result(
      value: isActive,
      dialog: .init(stringLiteral: dialogMessage)
    )
  }
}
