import SwiftUI

struct LocationReferenceRow: View {
  @EnvironmentObject var themeManager: ThemeManager

  let location: SavedLocation
  @Binding var reference: ProfileLocationReference
  let isSelected: Bool
  let onToggle: (Bool) -> Void

  @State private var showDistanceOverride: Bool = false
  @State private var sliderValue: Double = 0

  private var effectiveRadius: Double {
    reference.radiusOverrideMeters ?? location.defaultRadiusMeters
  }

  private var hasOverride: Bool {
    reference.radiusOverrideMeters != nil
  }

  private var selectedRadiusIndex: Int {
    Int(sliderValue.rounded())
  }

  private var selectedRadius: Double {
    let index = min(max(selectedRadiusIndex, 0), SavedLocation.radiusSteps.count - 1)
    return SavedLocation.radiusSteps[index]
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 12) {
        // Checkbox
        Button {
          onToggle(!isSelected)
        } label: {
          Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.title2)
            .foregroundColor(isSelected ? themeManager.themeColor : .secondary)
        }
        .buttonStyle(.plain)

        // Location info
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Text(location.name)
              .font(.body)
              .foregroundColor(.primary)

            if location.isLocked {
              Image(systemName: "lock.fill")
                .font(.caption2)
                .foregroundColor(.orange)
            }
          }

          Text("Distance: \(SavedLocation.formatRadius(effectiveRadius))")
            .font(.caption)
            .foregroundColor(.secondary)
        }

        Spacer()

        // Distance override button (only show when selected)
        if isSelected {
          Button {
            showDistanceOverride.toggle()
          } label: {
            HStack(spacing: 4) {
              if hasOverride {
                Image(systemName: "ruler")
                  .font(.caption)
              }
              Image(systemName: "chevron.down")
                .font(.caption2)
                .rotationEffect(.degrees(showDistanceOverride ? 180 : 0))
            }
            .foregroundColor(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.1))
            .clipShape(Capsule())
          }
          .buttonStyle(.plain)
        }
      }

      // Distance override picker (expandable)
      if isSelected && showDistanceOverride {
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text("Override distance for this profile:")
              .font(.caption)
              .foregroundColor(.secondary)
            Spacer()
            if hasOverride {
              Button("Reset") {
                reference.radiusOverrideMeters = nil
                sliderValue = Double(SavedLocation.radiusStepIndex(for: location.defaultRadiusMeters))
              }
              .font(.caption)
              .foregroundColor(themeManager.themeColor)
            }
          }

          HStack {
            Text("10m")
              .font(.caption)
              .foregroundColor(.secondary)
              .frame(width: 32, alignment: .leading)
            Slider(
              value: $sliderValue,
              in: 0...Double(SavedLocation.radiusSteps.count - 1),
              step: 1
            )
            .tint(themeManager.themeColor)
            .onChange(of: sliderValue) { _, newValue in
              let index = Int(newValue.rounded())
              let meters = SavedLocation.radiusSteps[min(max(index, 0), SavedLocation.radiusSteps.count - 1)]
              if abs(location.defaultRadiusMeters - meters) < 1 {
                reference.radiusOverrideMeters = nil
              } else {
                reference.radiusOverrideMeters = meters
              }
            }
            Text("3km")
              .font(.caption)
              .foregroundColor(.secondary)
              .frame(width: 32, alignment: .trailing)
          }

          Text(SavedLocation.formatRadiusWithDescription(selectedRadius))
            .font(.subheadline)
            .foregroundColor(themeManager.themeColor)
            .fontWeight(.medium)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.leading, 44)
        .padding(.top, 4)
      }
    }
    .padding(.vertical, 4)
    .animation(.easeInOut(duration: 0.2), value: showDistanceOverride)
    .onAppear {
      sliderValue = Double(SavedLocation.radiusStepIndex(for: effectiveRadius))
    }
  }
}

#Preview {
  struct PreviewContainer: View {
    @State var reference = ProfileLocationReference(savedLocationId: UUID())
    @State var isSelected = true

    var body: some View {
      List {
        LocationReferenceRow(
          location: SavedLocation(
            name: "Home",
            latitude: 51.5074,
            longitude: -0.1278,
            defaultRadiusMeters: 500
          ),
          reference: $reference,
          isSelected: isSelected,
          onToggle: { isSelected = $0 }
        )

        LocationReferenceRow(
          location: SavedLocation(
            name: "Office",
            latitude: 51.5155,
            longitude: -0.1419,
            defaultRadiusMeters: 1000,
            isLocked: true
          ),
          reference: .constant(ProfileLocationReference(savedLocationId: UUID(), radiusOverrideMeters: 250)),
          isSelected: true,
          onToggle: { _ in }
        )

        LocationReferenceRow(
          location: SavedLocation(
            name: "School",
            latitude: 51.5200,
            longitude: -0.1300,
            defaultRadiusMeters: 250
          ),
          reference: .constant(ProfileLocationReference(savedLocationId: UUID())),
          isSelected: false,
          onToggle: { _ in }
        )
      }
      .environmentObject(ThemeManager.shared)
    }
  }

  return PreviewContainer()
}
