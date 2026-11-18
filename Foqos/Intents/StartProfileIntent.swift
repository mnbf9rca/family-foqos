import AppIntents
import SwiftData

struct StartProfileIntent: AppIntent {
  static var authenticationPolicy: IntentAuthenticationPolicy { ShortcutsSettings.authenticationPolicy }

  @Dependency(key: "ProtectedStoreLaunch")
  private var launch: ProtectedStoreLaunch

  init() {}

  init(launch: ProtectedStoreLaunch) {
    self.launch = launch
  }

  @Parameter(title: "Profile") var profile: BlockedProfileEntity

  @Parameter(title: "Duration minutes (Optional)") var durationInMinutes: Int?

  nonisolated(unsafe) static var title: LocalizedStringResource = "Start Family Foqos Profile"  // SAFETY: AppIntents requires static var; immutable after init

  nonisolated(unsafe) static var description = IntentDescription(  // SAFETY: AppIntents requires static var; immutable after init
    "This start uses the profile’s saved timer. Remove Duration from the Shortcut or edit the profile’s timer."
  )

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    try perform { profileID, context, duration in
      try StrategyManager.shared.startSessionFromBackground(
        profileID, context: context, durationInMinutes: duration)
    }
  }

  @MainActor
  func perform(
    start: (UUID, ModelContext, Int?) throws -> String
  ) throws -> some IntentResult & ProvidesDialog {
    let modelContext = try launch.readyContainer().mainContext
    let currentName = try start(profile.id, modelContext, durationInMinutes)

    let message = "\(currentName) started."
    return .result(dialog: .init(stringLiteral: message))
  }
}
