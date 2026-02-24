import Foundation

/// The type of geofence rule for profile override restrictions
public enum GeofenceRuleType: String, Codable, CaseIterable {
  case within  // User must be inside ANY of the referenced locations
  case outside  // User must be outside ALL of the referenced locations

  public var displayName: String {
    switch self {
    case .within:
      return "Must be within"
    case .outside:
      return "Must be outside"
    }
  }

  public var description: String {
    switch self {
    case .within:
      return "You can only stop this profile when you're at one of the selected locations"
    case .outside:
      return "You can only stop this profile when you've left all of the selected locations"
    }
  }

  public var shortDescription: String {
    switch self {
    case .within:
      return "Stop only at selected locations"
    case .outside:
      return "Stop only away from selected locations"
    }
  }

  public var iconName: String {
    switch self {
    case .within:
      return "location.circle.fill"
    case .outside:
      return "location.slash.circle.fill"
    }
  }
}

/// A reference to a saved location with an optional radius override
public struct ProfileLocationReference: Codable, Equatable, Hashable {
  public var savedLocationId: UUID
  public var radiusOverrideMeters: Double?  // nil = use location's default radius

  public init(savedLocationId: UUID, radiusOverrideMeters: Double? = nil) {
    self.savedLocationId = savedLocationId
    self.radiusOverrideMeters = radiusOverrideMeters
  }

  /// Get the effective radius (override or default from saved location)
  public func effectiveRadius(defaultRadius: Double) -> Double {
    return radiusOverrideMeters ?? defaultRadius
  }
}

/// A geofence rule for a profile, defining location-based restrictions for stopping
public struct ProfileGeofenceRule: Codable, Equatable {
  public var ruleType: GeofenceRuleType
  public var locationReferences: [ProfileLocationReference]
  public var allowEmergencyOverride: Bool

  public init(
    ruleType: GeofenceRuleType,
    locationReferences: [ProfileLocationReference],
    allowEmergencyOverride: Bool = true
  ) {
    self.ruleType = ruleType
    self.locationReferences = locationReferences
    self.allowEmergencyOverride = allowEmergencyOverride
  }

  /// Whether this rule has any locations configured
  public var hasLocations: Bool {
    return !locationReferences.isEmpty
  }

  /// Number of locations in the rule
  public var locationCount: Int {
    return locationReferences.count
  }

  /// Generate a summary text for UI display
  public func summaryText(locationNames: [UUID: String]) -> String {
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
public struct GeofenceCheckResult {
  public var isSatisfied: Bool
  public var failureMessage: String?

  public init(isSatisfied: Bool, failureMessage: String? = nil) {
    self.isSatisfied = isSatisfied
    self.failureMessage = failureMessage
  }

  public static func satisfied() -> GeofenceCheckResult {
    return GeofenceCheckResult(isSatisfied: true, failureMessage: nil)
  }

  public static func failed(message: String) -> GeofenceCheckResult {
    return GeofenceCheckResult(isSatisfied: false, failureMessage: message)
  }
}
