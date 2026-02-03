//
//  ProfileSelectionIntent.swift
//  FoqosWidget
//
//  Created by Ali Waseem on 2025-03-11.
//

import AppIntents
import Foundation

// MARK: - Profile Entity for Widget Configuration
struct WidgetProfileEntity: AppEntity {
  let id: String
  let name: String

  init(id: String, name: String) {
    self.id = id
    self.name = name
  }

  nonisolated(unsafe) static var typeDisplayRepresentation = TypeDisplayRepresentation(  // SAFETY: AppIntents requires static var; immutable after init
    name: "Profile"
  )

  nonisolated(unsafe) static var defaultQuery = WidgetProfileQuery()  // SAFETY: AppIntents requires static var; immutable after init

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "\(name)")
  }
}

// MARK: - Profile Query for Widget Configuration
struct WidgetProfileQuery: EntityQuery {
  func entities(for identifiers: [WidgetProfileEntity.ID]) async throws -> [WidgetProfileEntity] {
    let profileSnapshots = SharedData.profileSnapshots
    return identifiers.compactMap { id in
      guard let snapshot = profileSnapshots[id] else { return nil }
      return WidgetProfileEntity(id: id, name: snapshot.name)
    }
  }

  func suggestedEntities() async throws -> [WidgetProfileEntity] {
    let profileSnapshots = SharedData.profileSnapshots
    return profileSnapshots.map { (id, snapshot) in
      WidgetProfileEntity(id: id, name: snapshot.name)
    }.sorted { $0.name < $1.name }
  }

  func defaultResult() async -> WidgetProfileEntity? {
    return try? await suggestedEntities().first
  }
}

// MARK: - Widget Configuration Intent
struct ProfileSelectionIntent: WidgetConfigurationIntent {
  nonisolated(unsafe) static var title: LocalizedStringResource = "Select Profile"  // SAFETY: AppIntents requires static var; immutable after init
  nonisolated(unsafe) static var description = IntentDescription("Choose which profile to display in the widget")  // SAFETY: AppIntents requires static var; immutable after init

  @Parameter(title: "Profile", description: "The profile to monitor in the widget")
  var profile: WidgetProfileEntity?

  @Parameter(
    title: "Quick Launch",
    description: "Launch the profile directly without navigating to the app")
  var useProfileURL: Bool?

  init() {
    self.useProfileURL = false
  }

  init(profile: WidgetProfileEntity?, useProfileURL: Bool = false) {
    self.profile = profile
    self.useProfileURL = useProfileURL
  }
}
