import CoreLocation
import MapKit
import SwiftUI

struct MapLocationPicker: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject var themeManager: ThemeManager

  // Initial coordinate (for editing existing location)
  var initialCoordinate: CLLocationCoordinate2D?

  // Callback when location is confirmed
  var onConfirm: (CLLocationCoordinate2D) -> Void

  @State private var selectedCoordinate: CLLocationCoordinate2D?
  @State private var position: MapCameraPosition = .automatic

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

        if selectedCoordinate == nil {
          VStack {
            Spacer()
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
