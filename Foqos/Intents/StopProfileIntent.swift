import AppIntents
import SwiftData

struct StopProfileIntent: AppIntent {
  @Dependency(key: "ModelContainer")
  private var modelContainer: ModelContainer

  @MainActor
  private var modelContext: ModelContext {
    return modelContainer.mainContext
  }

  @Parameter(title: "Profile") var profile: BlockedProfileEntity

  nonisolated(unsafe) static var title: LocalizedStringResource = "Stop Family Foqos Profile"  // SAFETY: AppIntents requires static var; immutable after init

  @MainActor
  func perform() async throws -> some IntentResult {
    let strategyManager = StrategyManager.shared

    strategyManager
      .stopSessionFromBackground(
        profile.id,
        context: modelContext
      )

    return .result()
  }
}
