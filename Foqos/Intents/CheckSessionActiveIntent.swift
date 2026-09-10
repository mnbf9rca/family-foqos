import AppIntents
import SwiftData

struct CheckSessionActiveIntent: AppIntent {
  static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

  @Dependency(key: "ModelContainer")
  private var modelContainer: ModelContainer

  @MainActor
  private var modelContext: ModelContext {
    return modelContainer.mainContext
  }

  nonisolated(unsafe) static var title: LocalizedStringResource = "Check if Family Foqos Session is Active"  // SAFETY: AppIntents requires static var; immutable after init
  nonisolated(unsafe) static var description = IntentDescription(  // SAFETY: AppIntents requires static var; immutable after init
    "Check if any Family Foqos blocking session is currently active and return true or false. Useful for automation and shortcuts."
  )

  nonisolated(unsafe) static var openAppWhenRun: Bool = false  // SAFETY: AppIntents requires static var; immutable after init

  @MainActor
  func perform() async throws -> some IntentResult & ReturnsValue<Bool> & ProvidesDialog {
    let status = try ShortcutStatus.read(
      manager: .shared, context: modelContext)

    return .result(
      value: status.isActive,
      dialog: .init(stringLiteral: status.dialog)
    )
  }
}
