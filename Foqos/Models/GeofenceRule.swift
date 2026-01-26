import Foundation

/// The type of geofence rule for profile override restrictions
enum GeofenceRuleType: String, Codable, CaseIterable {
  case within   // User must be inside ANY of the referenced locations
  case outside  // User must be outside ALL of the referenced locations

  var displayName: String {
    switch self {
    case .within:
      return "Must be within"
    case .outside:
      return "Must be outside"
    }
  }

  var description: String {
    switch self {
    case .within:
      return "You can only stop this profile when you're at one of the selected locations"
    case .outside:
      return "You can only stop this profile when you've left all of the selected locations"
    }
  }

  var shortDescription: String {
    switch self {
    case .within:
      return "Stop only at selected locations"
    case .outside:
      return "Stop only away from selected locations"
    }
  }

  var iconName: String {
    switch self {
    case .within:
      return "location.circle.fill"
    case .outside:
      return "location.slash.circle.fill"
    }
  }
}

/// A reference to a saved location with an optional radius override
struct ProfileLocationReference: Codable, Equatable, Hashable {
  var savedLocationId: UUID
  var radiusOverrideMeters: Double?  // nil = use location's default radius

  init(savedLocationId: UUID, radiusOverrideMeters: Double? = nil) {
    self.savedLocationId = savedLocationId
    self.radiusOverrideMeters = radiusOverrideMeters
  }

  /// Get the effective radius (override or default from saved location)
  func effectiveRadius(defaultRadius: Double) -> Double {
    return radiusOverrideMeters ?? defaultRadius
  }
}

/// A geofence rule for a profile, defining location-based restrictions for stopping
struct ProfileGeofenceRule: Codable, Equatable {
  var ruleType: GeofenceRuleType
  var locationReferences: [ProfileLocationReference]
  var allowEmergencyOverride: Bool

  init(
    ruleType: GeofenceRuleType,
    locationReferences: [ProfileLocationReference],
    allowEmergencyOverride: Bool = true
  ) {
    self.ruleType = ruleType
    self.locationReferences = locationReferences
    self.allowEmergencyOverride = allowEmergencyOverride
  }

  /// Whether this rule has any locations configured
  var hasLocations: Bool {
    return !locationReferences.isEmpty
  }

  /// Number of locations in the rule
  var locationCount: Int {
    return locationReferences.count
  }

  /// Generate a summary text for UI display
  func summaryText(locationNames: [UUID: String]) -> String {
    guard hasLocations else {
      return "No locations selected"
    }

    let names = locationReferences.compactMap { locationNames[$0.savedLocationId] }
    let locationList = names.prefix(2).joined(separator: ", ")
    let remaining = names.count - 2

    let prefix = ruleType == .within ? "Within" : "Outside"

    if remaining > 0 {
      return "\(prefix) \(locationList) +\(remaining) more"
    } else {
      return "\(prefix) \(locationList)"
    }
  }
}

/// Result of checking a geofence rule against current location
struct GeofenceCheckResult {
  var isSatisfied: Bool
  var failureMessage: String?

  static func satisfied() -> GeofenceCheckResult {
    return GeofenceCheckResult(isSatisfied: true, failureMessage: nil)
  }

  static func failed(message: String) -> GeofenceCheckResult {
    return GeofenceCheckResult(isSatisfied: false, failureMessage: message)
  }
}
