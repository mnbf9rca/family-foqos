import AppIntents

struct CheckProfileStatusIntent: AppIntent {
  static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

  @Dependency(key: "ProtectedStoreLaunch")
  private var launch: ProtectedStoreLaunch

  init() {}

  init(launch: ProtectedStoreLaunch) {
    self.launch = launch
  }

  @Parameter(title: "Profile") var profile: BlockedProfileEntity

  nonisolated(unsafe) static var title: LocalizedStringResource = "Family Foqos Profile Status"  // SAFETY: AppIntents requires static var; immutable after init
  nonisolated(unsafe) static var description = IntentDescription(  // SAFETY: AppIntents requires static var; immutable after init
    "Check if a Family Foqos profile is currently active and return the status as a boolean value.")

  @MainActor
  func perform() async throws -> some IntentResult & ReturnsValue<Bool> & ProvidesDialog {
    let modelContext = try launch.readyContainer().mainContext
    let status = try ShortcutStatus.read(
      manager: .shared, context: modelContext, askedProfileId: profile.id)

    return .result(
      value: status.isActive,
      dialog: .init(stringLiteral: status.dialog)
    )
  }
}
