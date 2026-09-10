import AppIntents
import SwiftData

struct StopProfileIntent: AppIntent {
  static var authenticationPolicy: IntentAuthenticationPolicy { ShortcutsSettings.authenticationPolicy }

  @Dependency(key: "ModelContainer")
  private var modelContainer: ModelContainer

  @MainActor
  private var modelContext: ModelContext {
    return modelContainer.mainContext
  }

  @Parameter(title: "Profile") var profile: BlockedProfileEntity

  nonisolated(unsafe) static var title: LocalizedStringResource = "Stop Family Foqos Profile"  // SAFETY: AppIntents requires static var; immutable after init

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    try await StrategyManager.shared
      .stopSessionFromBackground(
        profile.id,
        context: modelContext
      )

    guard let current = try BlockedProfiles.findProfile(byID: profile.id, in: modelContext) else {
      throw IntentError.profileNotFound
    }
    return .result(dialog: "\(current.name) stopped.")
  }
}
