import SwiftData

@testable import FamilyFoqos

enum TestModelContainer {
  static func create() throws -> ModelContainer {
    let schema = Schema([BlockedProfiles.self, BlockedProfileSession.self, SavedLocation.self])
    let config = ModelConfiguration(
      schema: schema,
      isStoredInMemoryOnly: true,
      cloudKitDatabase: .none
    )
    return try ModelContainer(for: schema, configurations: [config])
  }
}
