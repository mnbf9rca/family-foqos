import MapKit
import SwiftData
import SwiftUI

struct GeofencePicker: View {
  @Environment(\.dismiss) private var dismiss

  @EnvironmentObject var themeManager: ThemeManager

  @Binding var geofenceRule: ProfileGeofenceRule?

  @SafeQuery(sort: \SavedLocation.name) private var savedLocations: [SavedLocation]

  // Local state for editing
  @State private var selectedRuleType: GeofenceRuleType = .within
  @State private var selectedLocationIds: Set<UUID> = []
  @State private var locationReferences: [UUID: ProfileLocationReference] = [:]
  @State private var allowEmergencyOverride: Bool = true
  @State private var showingAddLocation = false

  // Map state
  @State private var mapRegion = MKCoordinateRegion(
    center: CLLocationCoordinate2D(latitude: 51.5074, longitude: -0.1278),
    span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
  )

  private var hasChanges: Bool {
    !selectedLocationIds.isEmpty
  }

  private var selectedLocations: [SavedLocation] {
    savedLocations.filter { selectedLocationIds.contains($0.id) }
  }

  static func shouldShowAddLocationAffordance(savedLocationCount: Int) -> Bool {
    true
  }

  struct LocationSelectionState {
    var selectedLocationIds: Set<UUID>
    var locationReferences: [UUID: ProfileLocationReference]

    func selectAddedLocation(_ locationId: UUID) -> LocationSelectionState {
      var updated = self
      updated.selectedLocationIds.insert(locationId)
      if updated.locationReferences[locationId] == nil {
        updated.locationReferences[locationId] = ProfileLocationReference(
          savedLocationId: locationId)
      }
      return updated
    }
  }

  var body: some View {
    NavigationStack {
      Form {
        // Rule type section
        Section {
          VStack(spacing: 12) {
            ForEach(GeofenceRuleType.allCases, id: \.self) { ruleType in
              Button {
                selectedRuleType = ruleType
              } label: {
                HStack(spacing: 12) {
                  Image(systemName: ruleType.iconName)
                    .font(.title2)
                    .foregroundColor(selectedRuleType == ruleType ? .white : themeManager.themeColor)
                    .frame(width: 32)
                  VStack(alignment: .leading, spacing: 2) {
                    Text(ruleType.displayName)
                      .font(.subheadline)
                      .fontWeight(.medium)
                    Text(ruleType.shortDescription)
                      .font(.caption)
                      .foregroundColor(selectedRuleType == ruleType ? .white.opacity(0.8) : .secondary)
                  }
                  Spacer()
                  if selectedRuleType == ruleType {
                    Image(systemName: "checkmark")
                      .font(.body.weight(.semibold))
                      .foregroundColor(.white)
                  }
                }
                .padding(12)
                .background(selectedRuleType == ruleType ? themeManager.themeColor : Color.secondary.opacity(0.1))
                .foregroundColor(selectedRuleType == ruleType ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 10))
              }
              .buttonStyle(.plain)
            }
          }
          .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
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
              Text("Add a location to use geofence restrictions.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

              Button {
                showingAddLocation = true
              } label: {
                Label("Add Location", systemImage: "plus")
              }
              .buttonStyle(.borderedProminent)
              .tint(themeManager.themeColor)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
          } else {
            ForEach(savedLocations) { location in
              SafeModelView(location) { loc in
                let data = loc.locationReferenceRowData
                let locationId = data.id
                let isSelected = selectedLocationIds.contains(locationId)
                let binding = Binding<ProfileLocationReference>(
                  get: {
                    locationReferences[locationId]
                      ?? ProfileLocationReference(savedLocationId: locationId)
                  },
                  set: { newValue in
                    locationReferences[locationId] = newValue
                  }
                )

                // #298: snapshot the location inside the gate; the reference stays a live binding.
                LocationReferenceRow(
                  location: data,
                  reference: binding,
                  isSelected: isSelected,
                  onToggle: { selected in
                    if selected {
                      selectLocation(locationId)
                    } else {
                      selectedLocationIds.remove(locationId)
                    }
                  }
                )
              }
            }

            if Self.shouldShowAddLocationAffordance(savedLocationCount: savedLocations.count) {
              Button {
                showingAddLocation = true
              } label: {
                Label("Add Location", systemImage: "plus")
                  .foregroundStyle(themeManager.themeColor)
              }
            }
          }
        } header: {
          Text("Locations")
        } footer: {
          if !savedLocations.isEmpty {
            Text("Select locations and optionally customize the distance for each.")
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

          // Emergency override section
          Section {
            Toggle(isOn: $allowEmergencyOverride) {
              VStack(alignment: .leading, spacing: 4) {
                Text("Allow Emergency Override")
                  .font(.body)
                Text("Emergency unblock can bypass this location restriction")
                  .font(.caption)
                  .foregroundColor(.secondary)
              }
            }
            .tint(themeManager.themeColor)
          } header: {
            Text("Emergency Access")
          } footer: {
            Text("When enabled, the limited emergency unblock feature can stop this profile regardless of location.")
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
      .onAppear {
        syncStateFromRule()
      }
      .sheet(isPresented: $showingAddLocation) {
        AddLocationView(onSave: { locationId in
          selectLocation(locationId)
        })
      }
    }
  }

  private func selectionState() -> LocationSelectionState {
    LocationSelectionState(
      selectedLocationIds: selectedLocationIds,
      locationReferences: locationReferences
    )
  }

  private func applySelectionState(_ state: LocationSelectionState) {
    selectedLocationIds = state.selectedLocationIds
    locationReferences = state.locationReferences
  }

  private func selectLocation(_ locationId: UUID) {
    applySelectionState(selectionState().selectAddedLocation(locationId))
  }

  private func syncStateFromRule() {
    if let rule = geofenceRule {
      selectedRuleType = rule.ruleType
      selectedLocationIds = Set(rule.locationReferences.map { $0.savedLocationId })
      var refs: [UUID: ProfileLocationReference] = [:]
      for ref in rule.locationReferences {
        refs[ref.savedLocationId] = ref
      }
      locationReferences = refs
      allowEmergencyOverride = rule.allowEmergencyOverride
    } else {
      selectedRuleType = .within
      selectedLocationIds = []
      locationReferences = [:]
      allowEmergencyOverride = true
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
        locationReferences: references,
        allowEmergencyOverride: allowEmergencyOverride
      )
    }
  }
}

// MARK: - Map Preview

struct GeofenceMapPreview: View {
  @EnvironmentObject var themeManager: ThemeManager

  let locations: [SavedLocation]
  let locationReferences: [UUID: ProfileLocationReference]

  private var region: MKCoordinateRegion {
    Self.regionToFit(locations: locations, locationReferences: locationReferences)
  }

  private static func regionToFit(
    locations: [SavedLocation],
    locationReferences: [UUID: ProfileLocationReference]
  ) -> MKCoordinateRegion {
    guard !locations.isEmpty else {
      return MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 51.5074, longitude: -0.1278),
        span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
      )
    }

    // Calculate bounds including the radius of each location
    let metersPerDegree = 111000.0
    var minLat = Double.greatestFiniteMagnitude
    var maxLat = -Double.greatestFiniteMagnitude
    var minLon = Double.greatestFiniteMagnitude
    var maxLon = -Double.greatestFiniteMagnitude

    for location in locations {
      let radius = locationReferences[location.id]?.radiusOverrideMeters ?? location.defaultRadiusMeters
      let radiusDegrees = radius / metersPerDegree

      minLat = min(minLat, location.latitude - radiusDegrees)
      maxLat = max(maxLat, location.latitude + radiusDegrees)
      minLon = min(minLon, location.longitude - radiusDegrees)
      maxLon = max(maxLon, location.longitude + radiusDegrees)
    }

    let center = CLLocationCoordinate2D(
      latitude: (minLat + maxLat) / 2,
      longitude: (minLon + maxLon) / 2
    )

    let latDelta = max((maxLat - minLat) * 1.4, 0.005)
    let lonDelta = max((maxLon - minLon) * 1.4, 0.005)

    return MKCoordinateRegion(
      center: center,
      span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)
    )
  }

  var body: some View {
    Map(position: .constant(.region(region)), interactionModes: []) {
      // Draw circles for each location
      ForEach(locations) { location in
        let reference = locationReferences[location.id]
        let radius = reference?.radiusOverrideMeters ?? location.defaultRadiusMeters
        let coordinate = CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)

        MapCircle(center: coordinate, radius: radius)
          .foregroundStyle(themeManager.themeColor.opacity(0.2))
          .stroke(themeManager.themeColor, lineWidth: 2)

        Annotation(location.name, coordinate: coordinate) {
          VStack(spacing: 4) {
            Image(systemName: "mappin.circle.fill")
              .font(.title2)
              .foregroundColor(themeManager.themeColor)
            Text(location.name)
              .font(.caption2)
              .fontWeight(.medium)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(Color(.systemBackground).opacity(0.9))
              .clipShape(Capsule())
          }
        }
      }
    }
  }
}

#Preview {
  struct PreviewContainer: View {
    @State var rule: ProfileGeofenceRule? = nil

    var body: some View {
      GeofencePicker(geofenceRule: $rule)
        .environmentObject(ThemeManager.shared)
        .modelContainer(for: SavedLocation.self, inMemory: true)
    }
  }

  return PreviewContainer()
}
