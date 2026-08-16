import Foundation
import SwiftData

enum AppModelStore {
  static var schema: Schema {
    Schema([BlockedProfileSession.self, BlockedProfiles.self, SavedLocation.self])
  }

  static var configuration: ModelConfiguration {
    ModelConfiguration(
      schema: schema,
      isStoredInMemoryOnly: ScreenshotDemoMode.isActive,
      cloudKitDatabase: .none)
  }

  static var storeURL: URL {
    configuration.url
  }

  static func makeConfiguration(url: URL) -> ModelConfiguration {
    ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
  }

  static func makeContainer() throws -> ModelContainer {
    let schema = schema
    return try ModelContainer(for: schema, configurations: [configuration])
  }
}
