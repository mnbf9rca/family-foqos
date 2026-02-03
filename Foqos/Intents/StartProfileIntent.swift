import AppIntents
import SwiftData

struct StartProfileIntent: AppIntent {
  @Dependency(key: "ModelContainer")
  private var modelContainer: ModelContainer

  @MainActor
  private var modelContext: ModelContext {
    return modelContainer.mainContext
  }

  @Parameter(title: "Profile") var profile: BlockedProfileEntity

  @Parameter(title: "Duration minutes (Optional)") var durationInMinutes: Int?

  nonisolated(unsafe) static var title: LocalizedStringResource = "Start Family Foqos Profile"  // SAFETY: AppIntents requires static var; immutable after init

  nonisolated(unsafe) static var description = IntentDescription(  // SAFETY: AppIntents requires static var; immutable after init
    "Start a Family Foqos blocking profile. Optionally specify a timer duration in minutes (15-1440)."
  )

  @MainActor
  func perform() async throws -> some IntentResult {
    StrategyManager.shared.startSessionFromBackground(
      profile.id,
      context: modelContext,
      durationInMinutes: durationInMinutes
    )

    return .result()
  }
}
