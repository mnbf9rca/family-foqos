import CoreLocation
import Foundation
import SwiftData

/// Manages location services for geofence-based override restrictions.
/// Uses "When In Use" permission - only checks location on-demand when stopping a session.
@MainActor
class LocationManager: NSObject, ObservableObject {
  static let shared = LocationManager()

  private let locationManager = CLLocationManager()
  private var locationContinuation: CheckedContinuation<CLLocation, Error>?
  private var isLocationRequestInFlight: Bool = false
  private var authorizationContinuation: CheckedContinuation<CLAuthorizationStatus, Never>?

  @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined

  override private init() {
    super.init()
    locationManager.delegate = self
    locationManager.desiredAccuracy = kCLLocationAccuracyBest
    authorizationStatus = locationManager.authorizationStatus
  }

  // MARK: - Authorization

  /// Request location authorization if not already determined
  func requestAuthorization() {
    if locationManager.authorizationStatus == .notDetermined {
      locationManager.requestWhenInUseAuthorization()
    }
  }

  /// Request location authorization and wait for the result
  /// Returns the authorization status after the user responds to the permission prompt
  func requestAuthorizationAndWait() async -> CLAuthorizationStatus {
    let currentStatus = locationManager.authorizationStatus

    // If already determined, return immediately
    guard currentStatus == .notDetermined else {
      return currentStatus
    }

    return await withCheckedContinuation { continuation in
      self.authorizationContinuation = continuation
      locationManager.requestWhenInUseAuthorization()
    }
  }

  /// Check if location services are authorized
  var isAuthorized: Bool {
    let status = locationManager.authorizationStatus
    return status == .authorizedWhenInUse || status == .authorizedAlways
  }

  /// Check if authorization has been denied
  var isDenied: Bool {
    return locationManager.authorizationStatus == .denied
  }

  /// Check if authorization is not yet determined
  var isNotDetermined: Bool {
    return locationManager.authorizationStatus == .notDetermined
  }

  // MARK: - Location Fetch

  /// Get the current location (one-shot fetch)
  /// Throws if location cannot be obtained
  func getCurrentLocation() async throws -> CLLocation {
    // Prevent concurrent requests - second caller would overwrite continuation
    guard !isLocationRequestInFlight else {
      throw LocationError.locationUnavailable
    }

    // Check authorization first
    guard isAuthorized else {
      if isNotDetermined {
        throw LocationError.permissionNotDetermined
      } else {
        throw LocationError.permissionDenied
      }
    }

    isLocationRequestInFlight = true
    defer { isLocationRequestInFlight = false }

    return try await withCheckedThrowingContinuation { continuation in
      self.locationContinuation = continuation
      locationManager.requestLocation()
    }
  }

  // MARK: - Geofence Check

  /// Check if the current location satisfies a geofence rule
  /// - Parameters:
  ///   - rule: The geofence rule to check
  ///   - savedLocations: The saved locations referenced by the rule
  /// - Returns: A GeofenceCheckResult indicating whether the rule is satisfied
  func checkGeofenceRule(
    rule: ProfileGeofenceRule,
    savedLocations: [SavedLocation]
  ) async -> GeofenceCheckResult {
    // If no locations configured, rule is satisfied
    guard rule.hasLocations else {
      return .satisfied()
    }

    // Get current location
    let currentLocation: CLLocation
    do {
      currentLocation = try await getCurrentLocation()
    } catch let error as LocationError {
      return .failed(message: error.userMessage)
    } catch {
      return .failed(message: "Unable to determine your location. Please try again.")
    }

    // Build a map of saved location IDs to locations
    let locationMap = Dictionary(uniqueKeysWithValues: savedLocations.map { ($0.id, $0) })

    // Check each referenced location
    var satisfiedLocations: [String] = []
    var unsatisfiedLocations: [String] = []

    for reference in rule.locationReferences {
      guard let savedLocation = locationMap[reference.savedLocationId] else {
        continue  // Skip references to deleted locations
      }

      let targetLocation = CLLocation(
        latitude: savedLocation.latitude,
        longitude: savedLocation.longitude
      )

      let effectiveRadius = reference.effectiveRadius(defaultRadius: savedLocation.defaultRadiusMeters)
      let distance = currentLocation.distance(from: targetLocation)

      if distance <= effectiveRadius {
        satisfiedLocations.append(savedLocation.name)
      } else {
        unsatisfiedLocations.append(savedLocation.name)
      }
    }

    // Evaluate based on rule type
    switch rule.ruleType {
    case .within:
      // User must be inside ANY location
      if !satisfiedLocations.isEmpty {
        return .satisfied()
      } else {
        let locationNames = unsatisfiedLocations.prefix(2).joined(separator: " or ")
        return .failed(message: "You must be within \(locationNames) to stop this profile.")
      }

    case .outside:
      // User must be outside ALL locations
      if unsatisfiedLocations.count == rule.locationReferences.count {
        return .satisfied()
      } else {
        let locationNames = satisfiedLocations.prefix(2).joined(separator: " and ")
        return .failed(message: "You must leave \(locationNames) to stop this profile.")
      }
    }
  }

  /// Check geofence rule using a model context to fetch saved locations
  func checkGeofenceRule(
    rule: ProfileGeofenceRule,
    context: ModelContext
  ) async -> GeofenceCheckResult {
    do {
      let savedLocations = try SavedLocation.fetchAll(in: context)
      return await checkGeofenceRule(rule: rule, savedLocations: savedLocations)
    } catch {
      return .failed(message: "Unable to load saved locations.")
    }
  }
}

// MARK: - CLLocationManagerDelegate

extension LocationManager: CLLocationManagerDelegate {
  nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    let location = locations.last
    Task { @MainActor in
      if let location = location {
        self.locationContinuation?.resume(returning: location)
        self.locationContinuation = nil
      }
    }
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    Task { @MainActor in
      self.locationContinuation?.resume(throwing: LocationError.locationUnavailable)
      self.locationContinuation = nil
    }
  }

  nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    let status = manager.authorizationStatus
    Task { @MainActor in
      // Resume any pending authorization continuation
      if let continuation = self.authorizationContinuation {
        self.authorizationContinuation = nil
        continuation.resume(returning: status)
      }
      self.authorizationStatus = status
    }
  }
}

// MARK: - Error Types

enum LocationError: Error {
  case permissionNotDetermined
  case permissionDenied
  case locationUnavailable

  var userMessage: String {
    switch self {
    case .permissionNotDetermined:
      return "Location permission is required. Please allow location access to use this feature."
    case .permissionDenied:
      return "Location access is denied. Please enable location services in Settings to use location-based restrictions."
    case .locationUnavailable:
      return "Unable to determine your location. Please ensure location services are enabled and try again."
    }
  }
}
