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
  var onDelete: (() -> Void)?

  @State private var name: String = ""
  @State private var showingDeleteConfirmation: Bool = false
  @State private var latitude: Double = 0
  @State private var longitude: Double = 0
  @State private var radiusSliderValue: Double = Double(SavedLocation.defaultRadiusIndex)
  @State private var isLocked: Bool = false
  @State private var hasSetLocation: Bool = false

  @State private var searchText: String = ""
  @State private var searchResults: [MKMapItem] = []
  @State private var isSearching: Bool = false
  @State private var isFetchingCurrentLocation: Bool = false
  @State private var showingMapPicker: Bool = false

  @State private var mapRegion = MKCoordinateRegion(
    center: CLLocationCoordinate2D(latitude: 51.5074, longitude: -0.1278),
    span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
  )

  @State private var errorMessage: String?

  private var isEditing: Bool { editingLocation != nil }

  private var showLockToggle: Bool {
    appModeManager.currentMode == .parent && lockCodeManager.hasAnyLockCode
  }

  private var selectedRadiusIndex: Int {
    Int(radiusSliderValue.rounded())
  }

  private var selectedRadius: Double {
    let index = min(max(selectedRadiusIndex, 0), SavedLocation.radiusSteps.count - 1)
    return SavedLocation.radiusSteps[index]
  }

  private var canSave: Bool {
    return !name.trimmingCharacters(in: .whitespaces).isEmpty && hasSetLocation
  }

  init(editingLocation: SavedLocation? = nil, onDelete: (() -> Void)? = nil) {
    self.editingLocation = editingLocation
    self.onDelete = onDelete

    if let location = editingLocation {
      _name = State(initialValue: location.name)
      _latitude = State(initialValue: location.latitude)
      _longitude = State(initialValue: location.longitude)
      _isLocked = State(initialValue: location.isLocked)
      _hasSetLocation = State(initialValue: true)

      // Find closest radius step
      let stepIndex = SavedLocation.radiusStepIndex(for: location.defaultRadiusMeters)
      _radiusSliderValue = State(initialValue: Double(stepIndex))

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
            Task {
              await fetchCurrentLocation()
            }
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

          Button {
            showingMapPicker = true
          } label: {
            HStack {
              Image(systemName: "map")
                .foregroundColor(themeManager.themeColor)
              Text("Select on Map")
                .foregroundColor(.primary)
              Spacer()
            }
          }

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

        // Map with range slider
        if hasSetLocation {
          Section {
            VStack(spacing: 12) {
              Map(position: .constant(.region(mapRegion))) {
                Annotation("", coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)) {
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
              .onTapGesture {
                showingMapPicker = true
              }

              HStack {
                Text("10m")
                  .font(.caption)
                  .foregroundColor(.secondary)
                  .frame(width: 32, alignment: .leading)
                Slider(
                  value: $radiusSliderValue,
                  in: 0...Double(SavedLocation.radiusSteps.count - 1),
                  step: 1
                )
                .tint(themeManager.themeColor)
                Text("3km")
                  .font(.caption)
                  .foregroundColor(.secondary)
                  .frame(width: 32, alignment: .trailing)
              }

              Text(SavedLocation.formatRadiusWithDescription(selectedRadius))
                .font(.subheadline)
                .foregroundColor(themeManager.themeColor)
                .fontWeight(.medium)
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

        // Delete section (only when editing)
        if isEditing && onDelete != nil {
          Section {
            Button(role: .destructive) {
              showingDeleteConfirmation = true
            } label: {
              HStack {
                Spacer()
                Text("Delete Location")
                Spacer()
              }
            }
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
      .alert("Delete Location", isPresented: $showingDeleteConfirmation) {
        Button("Cancel", role: .cancel) {}
        Button("Delete", role: .destructive) {
          onDelete?()
          dismiss()
        }
      } message: {
        Text("Are you sure you want to delete \"\(name)\"? This will remove it from any profiles using it.")
      }
      .sheet(isPresented: $showingMapPicker) {
        MapLocationPicker(
          initialCoordinate: hasSetLocation
            ? CLLocationCoordinate2D(latitude: latitude, longitude: longitude) : nil
        ) { coordinate in
          latitude = coordinate.latitude
          longitude = coordinate.longitude
          hasSetLocation = true
          reverseGeocode(CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
        }
        .environmentObject(themeManager)
      }
      .onAppear { updateMapRegion() }
      .onChange(of: latitude) { _, _ in updateMapRegion() }
      .onChange(of: longitude) { _, _ in updateMapRegion() }
      .onChange(of: radiusSliderValue) { _, _ in updateMapRegion() }
      .onChange(of: hasSetLocation) { _, newValue in
        if newValue { updateMapRegion() }
      }
    }
  }

  private func fetchCurrentLocation() async {
    // Request permission if needed and wait for the result
    if locationManager.isNotDetermined {
      isFetchingCurrentLocation = true
      let status = await locationManager.requestAuthorizationAndWait()
      if status != .authorizedWhenInUse && status != .authorizedAlways {
        isFetchingCurrentLocation = false
        if status == .denied {
          errorMessage = "Location access is denied. Please enable it in Settings."
        } else {
          errorMessage = "Please allow location access to use this feature."
        }
        return
      }
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

    do {
      let location = try await locationManager.getCurrentLocation()
      latitude = location.coordinate.latitude
      longitude = location.coordinate.longitude
      hasSetLocation = true
      isFetchingCurrentLocation = false

      // Suggest a name based on reverse geocoding
      reverseGeocode(location)
    } catch {
      errorMessage = "Failed to get current location. Please try again."
      isFetchingCurrentLocation = false
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

    // Convert radius to degrees
    // 1 degree ≈ 111,000 meters at equator
    let metersPerDegree = 111000.0
    let radiusInDegrees = selectedRadius / metersPerDegree
    // Span needs to show full diameter (2x radius) plus 60% padding
    let spanDelta = radiusInDegrees * 2 * 1.6

    mapRegion = MKCoordinateRegion(
      center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
      span: MKCoordinateSpan(
        latitudeDelta: max(0.002, spanDelta),
        longitudeDelta: max(0.002, spanDelta)
      )
    )
  }

  private func radiusToMapSize() -> CGFloat {
    // Convert radius to pixel size based on map's latitude span and view height
    let metersPerDegree = 111000.0
    let radiusInDegrees = selectedRadius / metersPerDegree
    let mapHeightDegrees = mapRegion.span.latitudeDelta
    let viewHeight: CGFloat = 200  // Map view height
    let pixelsPerDegree = viewHeight / mapHeightDegrees
    // Return diameter (2x radius) in pixels
    return CGFloat(radiusInDegrees * Double(pixelsPerDegree) * 2)
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
