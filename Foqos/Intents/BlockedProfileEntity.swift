import AppIntents
@preconcurrency import SwiftData  // ReferenceWritableKeyPath in SortDescriptor lacks Sendable conformance

struct BlockedProfileEntity: AppEntity, Identifiable {
  let id: UUID
  let name: String

  init(id: UUID, name: String) {
    self.id = id
    self.name = name
  }

  init(profile: BlockedProfiles) {
    self.id = profile.id
    self.name = profile.name
  }

  nonisolated(unsafe) static var typeDisplayRepresentation = TypeDisplayRepresentation(  // SAFETY: AppIntents requires static var; immutable after init
    name: "Profile"
  )

  nonisolated(unsafe) static var defaultQuery = BlockedProfilesQuery()  // SAFETY: AppIntents requires static var; immutable after init

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "\(name)")
  }
}

struct BlockedProfilesQuery: EntityStringQuery {
  @Dependency(key: "ModelContainer")
  private var modelContainer: ModelContainer

  init() {}

  init(modelContainer: ModelContainer) {
    self.modelContainer = modelContainer
  }

  @MainActor
  private var modelContext: ModelContext {
    return modelContainer.mainContext
  }

  @MainActor
  func entities(for identifiers: [UUID]) async throws
    -> [BlockedProfileEntity]
  {
    let results = try modelContext.fetch(
      FetchDescriptor<BlockedProfiles>(
        predicate: #Predicate { identifiers.contains($0.id) }
      )
    )
    guard Set(results.map(\.id)) == Set(identifiers) else { throw IntentError.profileNotFound }
    return results.map { BlockedProfileEntity(profile: $0) }
  }

  @MainActor
  func suggestedEntities() async throws -> [BlockedProfileEntity] {
    let results = try modelContext.fetch(
      FetchDescriptor<BlockedProfiles>(sortBy: [.init(\.name)])
    )
    return results.map { BlockedProfileEntity(profile: $0) }
  }

  @MainActor
  func entities(matching string: String) async throws -> [BlockedProfileEntity] {
    let matches = try await suggestedEntities().filter {
      $0.name.localizedCaseInsensitiveContains(string)
    }
    guard !matches.isEmpty else { throw IntentError.profileNotFound }
    return matches
  }
}
