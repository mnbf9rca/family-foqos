import CoreLocation
import MapKit
import SwiftUI

struct MapLocationPicker: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject var themeManager: ThemeManager

  @ObservedObject private var locationManager = LocationManager.shared

  // Initial coordinate (for editing existing location)
  var initialCoordinate: CLLocationCoordinate2D?

  // Callback when location is confirmed
  var onConfirm: (CLLocationCoordinate2D) -> Void

  @State private var selectedCoordinate: CLLocationCoordinate2D?
  @State private var position: MapCameraPosition = .automatic
  @State private var isFetchingLocation: Bool = false
  @State private var locationErrorMessage: String?

  var body: some View {
    NavigationStack {
      ZStack {
        MapReader { proxy in
          Map(position: $position, interactionModes: [.pan, .zoom]) {
            if let coord = selectedCoordinate {
              Annotation("", coordinate: coord) {
                Image(systemName: "mappin.circle.fill")
                  .font(.title)
                  .foregroundColor(themeManager.themeColor)
              }
            }
          }
          .onTapGesture { screenCoord in
            if let coordinate = proxy.convert(screenCoord, from: .local) {
              selectedCoordinate = coordinate
            }
          }
        }

        // Locate me button
        VStack {
          Spacer()
          HStack {
            Spacer()
            Button {
              Task {
                await locateMe()
              }
            } label: {
              Group {
                if isFetchingLocation {
                  ProgressView()
                    .tint(.white)
                } else {
                  Image(systemName: "location.fill")
                }
              }
              .frame(width: 24, height: 24)
              .padding(12)
              .background(themeManager.themeColor)
              .foregroundColor(.white)
              .clipShape(Circle())
              .shadow(radius: 4)
            }
            .disabled(isFetchingLocation)
            .padding(.trailing, 16)
            .padding(.bottom, selectedCoordinate == nil ? 80 : 16)
          }
        }

        if selectedCoordinate == nil {
          VStack {
            Spacer()
            if let error = locationErrorMessage {
              Text(error)
                .font(.subheadline)
                .foregroundColor(.red)
                .padding()
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .padding(.bottom, 8)
            }
            Text("Tap to select a location")
              .font(.subheadline)
              .padding()
              .background(.ultraThinMaterial)
              .clipShape(Capsule())
              .padding(.bottom, 40)
          }
        }
      }
      .navigationTitle("Select Location")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Confirm") {
            if let coord = selectedCoordinate {
              onConfirm(coord)
              dismiss()
            }
          }
          .disabled(selectedCoordinate == nil)
        }
      }
      .onAppear {
        if let initial = initialCoordinate {
          selectedCoordinate = initial
          position = .region(
            MKCoordinateRegion(
              center: initial,
              span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            ))
        }
      }
    }
  }

  private func locateMe() async {
    locationErrorMessage = nil

    // Request permission if needed
    if locationManager.isNotDetermined {
      let status = await locationManager.requestAuthorizationAndWait()
      guard status == .authorizedWhenInUse || status == .authorizedAlways else {
        locationErrorMessage = "Location access denied. Enable in Settings."
        return
      }
    }

    guard locationManager.isAuthorized else {
      locationErrorMessage = "Location access denied. Enable in Settings."
      return
    }

    isFetchingLocation = true
    defer { isFetchingLocation = false }

    do {
      let location = try await locationManager.getCurrentLocation()
      let coordinate = location.coordinate

      // Set pin at current location and center map
      selectedCoordinate = coordinate
      position = .region(
        MKCoordinateRegion(
          center: coordinate,
          span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        ))
    } catch {
      locationErrorMessage = "Could not get location. Please try again."
    }
  }
}

#Preview {
  MapLocationPicker(
    initialCoordinate: nil
  ) { coordinate in
    print("Selected: \(coordinate)")
  }
  .environmentObject(ThemeManager.shared)
}

#Preview("With Initial Location") {
  MapLocationPicker(
    initialCoordinate: CLLocationCoordinate2D(latitude: 51.5074, longitude: -0.1278)
  ) { coordinate in
    print("Selected: \(coordinate)")
  }
  .environmentObject(ThemeManager.shared)
}
