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

  // MARK: - Radius Steps

  /// Radius steps for the slider (in meters)
  /// Range: 10m ("at this spot") to ~2 miles
  static let radiusSteps: [Double] = [
    10, 25, 50, 100, 150, 200, 250, 300, 400, 500, 750, 1000, 1500, 2000, 3200
  ]

  /// Default radius index (500m)
  static let defaultRadiusIndex: Int = 9

  /// Find the closest radius step index for a given meters value
  static func radiusStepIndex(for meters: Double) -> Int {
    var closestIndex = 0
    var closestDiff = Double.infinity
    for (index, step) in radiusSteps.enumerated() {
      let diff = abs(step - meters)
      if diff < closestDiff {
        closestDiff = diff
        closestIndex = index
      }
    }
    return closestIndex
  }

  static func formatRadius(_ meters: Double) -> String {
    if meters < 1000 {
      return "\(Int(meters))m"
    } else {
      let km = meters / 1000
      if km == floor(km) {
        return "\(Int(km))km"
      } else {
        return String(format: "%.1fkm", km)
      }
    }
  }

  /// Format radius with description for small values
  static func formatRadiusWithDescription(_ meters: Double) -> String {
    if meters <= 10 {
      return "10m (at this spot)"
    } else if meters <= 25 {
      return "25m (very close)"
    } else if meters <= 50 {
      return "50m (nearby)"
    } else {
      return formatRadius(meters)
    }
  }
}
