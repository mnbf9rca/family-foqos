import AppIntents
import SwiftData

struct CheckProfileStatusIntent: AppIntent {
  static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

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
    let status = try ShortcutStatus.read(
      manager: .shared, context: modelContext, askedProfileId: profile.id)

    return .result(
      value: status.isActive,
      dialog: .init(stringLiteral: status.dialog)
    )
  }
}
