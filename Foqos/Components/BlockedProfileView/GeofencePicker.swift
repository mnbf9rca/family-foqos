import MapKit
import SwiftUI

struct GeofencePicker: View {
  @Environment(\.dismiss) private var dismiss

  @EnvironmentObject var themeManager: ThemeManager

  @Binding var geofenceRule: ProfileGeofenceRule?
  let savedLocations: [SavedLocation]

  // Local state for editing
  @State private var selectedRuleType: GeofenceRuleType = .within
  @State private var selectedLocationIds: Set<UUID> = []
  @State private var locationReferences: [UUID: ProfileLocationReference] = [:]

  // Map state
  @State private var mapRegion = MKCoordinateRegion(
    center: CLLocationCoordinate2D(latitude: 51.5074, longitude: -0.1278),
    span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
  )

  init(geofenceRule: Binding<ProfileGeofenceRule?>, savedLocations: [SavedLocation]) {
    self._geofenceRule = geofenceRule
    self.savedLocations = savedLocations

    // Initialize state from existing rule
    if let rule = geofenceRule.wrappedValue {
      _selectedRuleType = State(initialValue: rule.ruleType)
      _selectedLocationIds = State(initialValue: Set(rule.locationReferences.map { $0.savedLocationId }))

      var refs: [UUID: ProfileLocationReference] = [:]
      for ref in rule.locationReferences {
        refs[ref.savedLocationId] = ref
      }
      _locationReferences = State(initialValue: refs)
    }
  }

  private var hasChanges: Bool {
    !selectedLocationIds.isEmpty
  }

  private var selectedLocations: [SavedLocation] {
    savedLocations.filter { selectedLocationIds.contains($0.id) }
  }

  var body: some View {
    NavigationStack {
      Form {
        // Rule type section
        Section {
          Picker("Rule Type", selection: $selectedRuleType) {
            ForEach(GeofenceRuleType.allCases, id: \.self) { ruleType in
              HStack {
                Image(systemName: ruleType.iconName)
                Text(ruleType.displayName)
              }
              .tag(ruleType)
            }
          }
          .pickerStyle(.segmented)

          Text(selectedRuleType.description)
            .font(.caption)
            .foregroundColor(.secondary)
        } header: {
          Text("Restriction Type")
        }

        // Locations section
        Section {
          if savedLocations.isEmpty {
            VStack(spacing: 12) {
              Image(systemName: "mappin.slash")
                .font(.title)
                .foregroundColor(.secondary)
              Text("No saved locations")
                .font(.subheadline)
              Text("Add locations in Settings to use geofence restrictions.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
          } else {
            ForEach(savedLocations) { location in
              let isSelected = selectedLocationIds.contains(location.id)
              let binding = Binding<ProfileLocationReference>(
                get: {
                  locationReferences[location.id] ?? ProfileLocationReference(savedLocationId: location.id)
                },
                set: { newValue in
                  locationReferences[location.id] = newValue
                }
              )

              LocationReferenceRow(
                location: location,
                reference: binding,
                isSelected: isSelected,
                onToggle: { selected in
                  if selected {
                    selectedLocationIds.insert(location.id)
                    if locationReferences[location.id] == nil {
                      locationReferences[location.id] = ProfileLocationReference(savedLocationId: location.id)
                    }
                  } else {
                    selectedLocationIds.remove(location.id)
                  }
                }
              )
            }
          }
        } header: {
          Text("Locations")
        } footer: {
          if !savedLocations.isEmpty {
            Text("Select locations and optionally customize the radius for each.")
          }
        }

        // Map preview section
        if !selectedLocations.isEmpty {
          Section {
            GeofenceMapPreview(
              locations: selectedLocations,
              locationReferences: locationReferences
            )
            .frame(height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 12))
          } header: {
            Text("Preview")
          }
        }

        // Summary section
        if hasChanges {
          Section {
            HStack {
              Image(systemName: selectedRuleType.iconName)
                .foregroundColor(themeManager.themeColor)
              VStack(alignment: .leading, spacing: 2) {
                Text(selectedRuleType.displayName)
                  .font(.subheadline)
                  .fontWeight(.medium)
                Text("\(selectedLocationIds.count) location\(selectedLocationIds.count == 1 ? "" : "s") selected")
                  .font(.caption)
                  .foregroundColor(.secondary)
              }
            }
          } header: {
            Text("Summary")
          }
        }
      }
      .navigationTitle("Location Restrictions")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Cancel") {
            dismiss()
          }
        }

        ToolbarItem(placement: .topBarTrailing) {
          Button("Done") {
            saveRule()
            dismiss()
          }
        }
      }
    }
  }

  private func saveRule() {
    if selectedLocationIds.isEmpty {
      geofenceRule = nil
    } else {
      let references = selectedLocationIds.map { id in
        locationReferences[id] ?? ProfileLocationReference(savedLocationId: id)
      }
      geofenceRule = ProfileGeofenceRule(
        ruleType: selectedRuleType,
        locationReferences: references
      )
    }
  }
}

// MARK: - Map Preview

struct GeofenceMapPreview: View {
  @EnvironmentObject var themeManager: ThemeManager

  let locations: [SavedLocation]
  let locationReferences: [UUID: ProfileLocationReference]

  @State private var region: MKCoordinateRegion

  init(locations: [SavedLocation], locationReferences: [UUID: ProfileLocationReference]) {
    self.locations = locations
    self.locationReferences = locationReferences

    // Calculate region to fit all locations
    let coordinates = locations.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    _region = State(initialValue: Self.regionToFit(coordinates: coordinates))
  }

  private static func regionToFit(coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
    guard !coordinates.isEmpty else {
      return MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 51.5074, longitude: -0.1278),
        span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
      )
    }

    let latitudes = coordinates.map { $0.latitude }
    let longitudes = coordinates.map { $0.longitude }

    let minLat = latitudes.min()!
    let maxLat = latitudes.max()!
    let minLon = longitudes.min()!
    let maxLon = longitudes.max()!

    let center = CLLocationCoordinate2D(
      latitude: (minLat + maxLat) / 2,
      longitude: (minLon + maxLon) / 2
    )

    let latDelta = max((maxLat - minLat) * 1.5, 0.01)
    let lonDelta = max((maxLon - minLon) * 1.5, 0.01)

    return MKCoordinateRegion(
      center: center,
      span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)
    )
  }

  var body: some View {
    Map(position: .constant(.region(region))) {
      ForEach(locations) { location in
        let reference = locationReferences[location.id]
        let radius = reference?.radiusOverrideMeters ?? location.defaultRadiusMeters

        Annotation(location.name, coordinate: CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)) {
          VStack(spacing: 2) {
            ZStack {
              Circle()
                .fill(themeManager.themeColor.opacity(0.2))
                .frame(width: radiusToSize(radius), height: radiusToSize(radius))
              Circle()
                .stroke(themeManager.themeColor, lineWidth: 2)
                .frame(width: radiusToSize(radius), height: radiusToSize(radius))
              Image(systemName: "mappin.circle.fill")
                .font(.title2)
                .foregroundColor(themeManager.themeColor)
            }
            Text(location.name)
              .font(.caption2)
              .fontWeight(.medium)
              .padding(.horizontal, 4)
              .padding(.vertical, 2)
              .background(Color(.systemBackground).opacity(0.9))
              .clipShape(Capsule())
          }
        }
      }
    }
  }

  private func radiusToSize(_ meters: Double) -> CGFloat {
    // Scale radius to a reasonable visual size
    let minSize: CGFloat = 30
    let maxSize: CGFloat = 80
    let scaleFactor = min(max(meters / 1000, 0.1), 5)
    return minSize + CGFloat(scaleFactor) * (maxSize - minSize) / 5
  }
}

#Preview {
  struct PreviewContainer: View {
    @State var rule: ProfileGeofenceRule? = nil

    let sampleLocations = [
      SavedLocation(name: "Home", latitude: 51.5074, longitude: -0.1278, defaultRadiusMeters: 500),
      SavedLocation(name: "Office", latitude: 51.5155, longitude: -0.1419, defaultRadiusMeters: 1000),
      SavedLocation(name: "School", latitude: 51.5200, longitude: -0.1300, defaultRadiusMeters: 250),
    ]

    var body: some View {
      GeofencePicker(
        geofenceRule: $rule,
        savedLocations: sampleLocations
      )
      .environmentObject(ThemeManager.shared)
    }
  }

  return PreviewContainer()
}
