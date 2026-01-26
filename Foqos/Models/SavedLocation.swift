import Foundation
import SwiftData

@Model
class SavedLocation {
  @Attribute(.unique) var id: UUID
  var name: String
  var latitude: Double
  var longitude: Double
  var defaultRadiusMeters: Double
  var isLocked: Bool
  var createdAt: Date
  var updatedAt: Date

  init(
    id: UUID = UUID(),
    name: String,
    latitude: Double,
    longitude: Double,
    defaultRadiusMeters: Double = 500,
    isLocked: Bool = false,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.name = name
    self.latitude = latitude
    self.longitude = longitude
    self.defaultRadiusMeters = defaultRadiusMeters
    self.isLocked = isLocked
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  // MARK: - Fetch Operations

  static func fetchAll(in context: ModelContext) throws -> [SavedLocation] {
    let descriptor = FetchDescriptor<SavedLocation>(
      sortBy: [SortDescriptor(\.name, order: .forward)]
    )
    return try context.fetch(descriptor)
  }

  static func find(byID id: UUID, in context: ModelContext) throws -> SavedLocation? {
    let descriptor = FetchDescriptor<SavedLocation>(
      predicate: #Predicate { $0.id == id }
    )
    return try context.fetch(descriptor).first
  }

  // MARK: - Create Operation

  static func create(
    in context: ModelContext,
    name: String,
    latitude: Double,
    longitude: Double,
    defaultRadiusMeters: Double = 500,
    isLocked: Bool = false
  ) throws -> SavedLocation {
    let location = SavedLocation(
      name: name,
      latitude: latitude,
      longitude: longitude,
      defaultRadiusMeters: defaultRadiusMeters,
      isLocked: isLocked
    )
    context.insert(location)
    try context.save()
    return location
  }

  // MARK: - Update Operation

  static func update(
    _ location: SavedLocation,
    in context: ModelContext,
    name: String? = nil,
    latitude: Double? = nil,
    longitude: Double? = nil,
    defaultRadiusMeters: Double? = nil,
    isLocked: Bool? = nil
  ) throws -> SavedLocation {
    if let newName = name {
      location.name = newName
    }
    if let newLatitude = latitude {
      location.latitude = newLatitude
    }
    if let newLongitude = longitude {
      location.longitude = newLongitude
    }
    if let newRadius = defaultRadiusMeters {
      location.defaultRadiusMeters = newRadius
    }
    if let newIsLocked = isLocked {
      location.isLocked = newIsLocked
    }
    location.updatedAt = Date()
    try context.save()
    return location
  }

  // MARK: - Delete Operation

  static func delete(_ location: SavedLocation, in context: ModelContext) throws {
    context.delete(location)
    try context.save()
  }

  // MARK: - Radius Presets

  static let radiusPresets: [(label: String, meters: Double)] = [
    ("100m", 100),
    ("250m", 250),
    ("500m", 500),
    ("1km", 1000),
    ("1mi", 1609.34),
    ("5mi", 8046.72),
  ]

  static func formatRadius(_ meters: Double) -> String {
    if meters < 1000 {
      return "\(Int(meters))m"
    } else if meters < 1609 {
      return String(format: "%.1fkm", meters / 1000)
    } else {
      let miles = meters / 1609.34
      if miles < 2 {
        return "1mi"
      } else {
        return String(format: "%.0fmi", miles)
      }
    }
  }
}
