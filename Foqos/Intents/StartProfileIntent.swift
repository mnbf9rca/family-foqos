import AppIntents
import SwiftData

struct StartProfileIntent: AppIntent {
  static var authenticationPolicy: IntentAuthenticationPolicy { ShortcutsSettings.authenticationPolicy }

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
    "Start a Family Foqos blocking profile using its saved timer. Remove Duration from existing Shortcuts or edit the profile’s timer."
  )

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    let currentName = try StrategyManager.shared.startSessionFromBackground(
      profile.id,
      context: modelContext,
      durationInMinutes: durationInMinutes
    )

    let message = "\(currentName) started."
    return .result(dialog: .init(stringLiteral: message))
  }
}
