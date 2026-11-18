import AppIntents

struct StopProfileIntent: AppIntent {
  static var authenticationPolicy: IntentAuthenticationPolicy { ShortcutsSettings.authenticationPolicy }

  @Dependency(key: "ProtectedStoreLaunch")
  private var launch: ProtectedStoreLaunch

  init() {}

  init(launch: ProtectedStoreLaunch) {
    self.launch = launch
  }

  @Parameter(title: "Profile") var profile: BlockedProfileEntity

  nonisolated(unsafe) static var title: LocalizedStringResource = "Stop Family Foqos Profile"  // SAFETY: AppIntents requires static var; immutable after init

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    let modelContext = try launch.readyContainer().mainContext
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
