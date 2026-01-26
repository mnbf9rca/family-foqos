import CoreLocation
import MapKit
import SwiftData
import SwiftUI

struct AddLocationView: View {
  @Environment(\.modelContext) private var context
  @Environment(\.dismiss) private var dismiss

  @EnvironmentObject var themeManager: ThemeManager

  @ObservedObject private var appModeManager = AppModeManager.shared
  @ObservedObject private var lockCodeManager = LockCodeManager.shared
  @ObservedObject private var locationManager = LocationManager.shared

  // If editing an existing location
  var editingLocation: SavedLocation?

  @State private var name: String = ""
  @State private var latitude: Double = 0
  @State private var longitude: Double = 0
  @State private var selectedRadiusIndex: Int = 2  // Default to 500m
  @State private var customRadius: String = ""
  @State private var isLocked: Bool = false
  @State private var hasSetLocation: Bool = false

  @State private var searchText: String = ""
  @State private var searchResults: [MKMapItem] = []
  @State private var isSearching: Bool = false
  @State private var isFetchingCurrentLocation: Bool = false

  @State private var mapRegion = MKCoordinateRegion(
    center: CLLocationCoordinate2D(latitude: 51.5074, longitude: -0.1278),
    span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
  )

  @State private var errorMessage: String?

  private var isEditing: Bool { editingLocation != nil }

  private var showLockToggle: Bool {
    appModeManager.currentMode == .parent && lockCodeManager.hasAnyLockCode
  }

  private var selectedRadius: Double {
    if selectedRadiusIndex < SavedLocation.radiusPresets.count {
      return SavedLocation.radiusPresets[selectedRadiusIndex].meters
    } else {
      return Double(customRadius) ?? 500
    }
  }

  private var canSave: Bool {
    return !name.trimmingCharacters(in: .whitespaces).isEmpty && hasSetLocation
  }

  init(editingLocation: SavedLocation? = nil) {
    self.editingLocation = editingLocation

    if let location = editingLocation {
      _name = State(initialValue: location.name)
      _latitude = State(initialValue: location.latitude)
      _longitude = State(initialValue: location.longitude)
      _isLocked = State(initialValue: location.isLocked)
      _hasSetLocation = State(initialValue: true)

      // Find matching radius preset or use custom
      if let presetIndex = SavedLocation.radiusPresets.firstIndex(where: { abs($0.meters - location.defaultRadiusMeters) < 1 }) {
        _selectedRadiusIndex = State(initialValue: presetIndex)
      } else {
        _selectedRadiusIndex = State(initialValue: SavedLocation.radiusPresets.count)
        _customRadius = State(initialValue: String(Int(location.defaultRadiusMeters)))
      }

      _mapRegion = State(initialValue: MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude),
        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
      ))
    }
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Name") {
          TextField("Location Name", text: $name)
            .textContentType(.none)
        }

        Section("Location") {
          // Current location button
          Button {
            fetchCurrentLocation()
          } label: {
            HStack {
              Image(systemName: "location.fill")
                .foregroundColor(themeManager.themeColor)
              Text("Use Current Location")
                .foregroundColor(.primary)
              Spacer()
              if isFetchingCurrentLocation {
                ProgressView()
              }
            }
          }
          .disabled(isFetchingCurrentLocation)

          // Search field
          HStack {
            Image(systemName: "magnifyingglass")
              .foregroundColor(.secondary)
            TextField("Search address...", text: $searchText)
              .textContentType(.fullStreetAddress)
              .autocorrectionDisabled()
              .onSubmit {
                searchAddress()
              }
            if isSearching {
              ProgressView()
            } else if !searchText.isEmpty {
              Button {
                searchText = ""
                searchResults = []
              } label: {
                Image(systemName: "xmark.circle.fill")
                  .foregroundColor(.secondary)
              }
            }
          }

          // Search results
          if !searchResults.isEmpty {
            ForEach(searchResults, id: \.self) { item in
              Button {
                selectSearchResult(item)
              } label: {
                VStack(alignment: .leading, spacing: 4) {
                  Text(item.name ?? "Unknown")
                    .foregroundColor(.primary)
                  if let address = item.placemark.title {
                    Text(address)
                      .font(.caption)
                      .foregroundColor(.secondary)
                      .lineLimit(2)
                  }
                }
              }
            }
          }

          // Selected location display
          if hasSetLocation {
            HStack {
              Image(systemName: "mappin.circle.fill")
                .foregroundColor(.green)
              VStack(alignment: .leading) {
                Text("Location Set")
                  .font(.subheadline)
                  .fontWeight(.medium)
                Text(String(format: "%.4f, %.4f", latitude, longitude))
                  .font(.caption)
                  .foregroundColor(.secondary)
              }
            }
            .padding(.vertical, 4)
          }
        }

        // Map preview
        if hasSetLocation {
          Section("Preview") {
            Map(coordinateRegion: $mapRegion, annotationItems: [LocationAnnotation(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude))]) { annotation in
              MapAnnotation(coordinate: annotation.coordinate) {
                ZStack {
                  Circle()
                    .fill(themeManager.themeColor.opacity(0.2))
                    .frame(width: radiusToMapSize(), height: radiusToMapSize())
                  Circle()
                    .stroke(themeManager.themeColor, lineWidth: 2)
                    .frame(width: radiusToMapSize(), height: radiusToMapSize())
                  Image(systemName: "mappin.circle.fill")
                    .font(.title)
                    .foregroundColor(themeManager.themeColor)
                }
              }
            }
            .frame(height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 12))
          }
        }

        Section("Radius") {
          Picker("Radius", selection: $selectedRadiusIndex) {
            ForEach(0..<SavedLocation.radiusPresets.count, id: \.self) { index in
              Text(SavedLocation.radiusPresets[index].label).tag(index)
            }
            Text("Custom").tag(SavedLocation.radiusPresets.count)
          }
          .pickerStyle(.segmented)

          if selectedRadiusIndex == SavedLocation.radiusPresets.count {
            HStack {
              TextField("Meters", text: $customRadius)
                .keyboardType(.numberPad)
              Text("meters")
                .foregroundColor(.secondary)
            }
          }
        }

        // Lock toggle (parent mode only)
        if showLockToggle {
          Section {
            Toggle(isOn: $isLocked) {
              VStack(alignment: .leading, spacing: 4) {
                Text("Lock Location")
                  .font(.body)
                Text("Requires lock code to edit or delete")
                  .font(.caption)
                  .foregroundColor(.secondary)
              }
            }
            .tint(themeManager.themeColor)
          } header: {
            Text("Parent Controls")
          }
        }
      }
      .navigationTitle(isEditing ? "Edit Location" : "Add Location")
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Cancel") {
            dismiss()
          }
        }

        ToolbarItem(placement: .topBarTrailing) {
          Button(isEditing ? "Save" : "Add") {
            saveLocation()
          }
          .disabled(!canSave)
        }
      }
      .alert("Error", isPresented: .init(
        get: { errorMessage != nil },
        set: { if !$0 { errorMessage = nil } }
      )) {
        Button("OK", role: .cancel) {}
      } message: {
        if let message = errorMessage {
          Text(message)
        }
      }
      .onChange(of: latitude) { _, _ in updateMapRegion() }
      .onChange(of: longitude) { _, _ in updateMapRegion() }
      .onChange(of: selectedRadiusIndex) { _, _ in updateMapRegion() }
    }
  }

  private func fetchCurrentLocation() {
    // Request permission if needed
    if locationManager.isNotDetermined {
      locationManager.requestAuthorization()
    }

    guard locationManager.isAuthorized else {
      if locationManager.isDenied {
        errorMessage = "Location access is denied. Please enable it in Settings."
      } else {
        errorMessage = "Please allow location access to use this feature."
      }
      return
    }

    isFetchingCurrentLocation = true

    Task {
      do {
        let location = try await locationManager.getCurrentLocation()
        await MainActor.run {
          latitude = location.coordinate.latitude
          longitude = location.coordinate.longitude
          hasSetLocation = true
          isFetchingCurrentLocation = false

          // Suggest a name based on reverse geocoding
          reverseGeocode(location)
        }
      } catch {
        await MainActor.run {
          errorMessage = "Failed to get current location. Please try again."
          isFetchingCurrentLocation = false
        }
      }
    }
  }

  private func reverseGeocode(_ location: CLLocation) {
    let geocoder = CLGeocoder()
    geocoder.reverseGeocodeLocation(location) { placemarks, error in
      if let placemark = placemarks?.first, name.isEmpty {
        if let locality = placemark.locality {
          name = locality
        } else if let name = placemark.name {
          self.name = name
        }
      }
    }
  }

  private func searchAddress() {
    guard !searchText.isEmpty else { return }

    isSearching = true
    let request = MKLocalSearch.Request()
    request.naturalLanguageQuery = searchText

    let search = MKLocalSearch(request: request)
    search.start { response, error in
      isSearching = false
      if let response = response {
        searchResults = Array(response.mapItems.prefix(5))
      }
    }
  }

  private func selectSearchResult(_ item: MKMapItem) {
    latitude = item.placemark.coordinate.latitude
    longitude = item.placemark.coordinate.longitude
    hasSetLocation = true

    if name.isEmpty, let itemName = item.name {
      name = itemName
    }

    searchText = ""
    searchResults = []
  }

  private func updateMapRegion() {
    guard hasSetLocation else { return }

    // Adjust span based on radius
    let spanDelta = selectedRadius / 50000  // Rough conversion to degrees
    mapRegion = MKCoordinateRegion(
      center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
      span: MKCoordinateSpan(
        latitudeDelta: max(0.005, spanDelta),
        longitudeDelta: max(0.005, spanDelta)
      )
    )
  }

  private func radiusToMapSize() -> CGFloat {
    // Convert radius to approximate pixel size on map
    let metersPerDegree = 111000.0
    let degreesPerMeter = 1.0 / metersPerDegree
    let radiusDegrees = selectedRadius * degreesPerMeter
    let mapWidthDegrees = mapRegion.span.longitudeDelta
    let viewWidth: CGFloat = 300  // Approximate map view width
    let pixelsPerDegree = viewWidth / mapWidthDegrees
    return CGFloat(radiusDegrees * Double(pixelsPerDegree) * 2)
  }

  private func saveLocation() {
    let trimmedName = name.trimmingCharacters(in: .whitespaces)
    guard !trimmedName.isEmpty, hasSetLocation else { return }

    do {
      if let existing = editingLocation {
        _ = try SavedLocation.update(
          existing,
          in: context,
          name: trimmedName,
          latitude: latitude,
          longitude: longitude,
          defaultRadiusMeters: selectedRadius,
          isLocked: isLocked
        )
      } else {
        _ = try SavedLocation.create(
          in: context,
          name: trimmedName,
          latitude: latitude,
          longitude: longitude,
          defaultRadiusMeters: selectedRadius,
          isLocked: isLocked
        )
      }
      dismiss()
    } catch {
      errorMessage = "Failed to save location: \(error.localizedDescription)"
    }
  }
}

// Helper for map annotation
private struct LocationAnnotation: Identifiable {
  let id = UUID()
  let coordinate: CLLocationCoordinate2D
}

#Preview {
  AddLocationView()
    .environmentObject(ThemeManager.shared)
    .modelContainer(for: SavedLocation.self, inMemory: true)
}

#Preview("Editing") {
  AddLocationView(
    editingLocation: SavedLocation(
      name: "Home",
      latitude: 51.5074,
      longitude: -0.1278,
      defaultRadiusMeters: 500
    )
  )
  .environmentObject(ThemeManager.shared)
  .modelContainer(for: SavedLocation.self, inMemory: true)
}
