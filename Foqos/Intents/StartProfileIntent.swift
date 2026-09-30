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
    "Start a Family Foqos blocking profile. Duration applies only to this execution (15 minutes to 23 hours 59 minutes) and is unavailable while profile editing is locked."
  )

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    let currentName = try StrategyManager.shared.startSessionFromBackground(
      profile.id,
      context: modelContext,
      durationInMinutes: durationInMinutes
    )

    let message =
      durationInMinutes != nil
      ? "\(currentName) started for \(durationInMinutes!) minutes."
      : "\(currentName) started."
    return .result(dialog: .init(stringLiteral: message))
  }
}
