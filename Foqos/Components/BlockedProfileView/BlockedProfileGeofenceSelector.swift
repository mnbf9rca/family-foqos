import SwiftUI

struct BlockedProfileGeofenceSelector: View {
  @EnvironmentObject var themeManager: ThemeManager

  @Binding var geofenceRule: ProfileGeofenceRule?
  var savedLocations: [SavedLocation]
  var buttonAction: () -> Void
  var disabled: Bool = false

  private var hasRule: Bool {
    geofenceRule?.hasLocations == true
  }

  private var locationNames: [UUID: String] {
    Dictionary(uniqueKeysWithValues: savedLocations.map { ($0.id, $0.name) })
  }

  private var summaryText: String {
    guard let rule = geofenceRule, rule.hasLocations else {
      return "No location restrictions"
    }
    return rule.summaryText(locationNames: locationNames)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Button(action: buttonAction) {
        HStack {
          Text("Set location restrictions")
            .foregroundStyle(themeManager.themeColor)
          Spacer()
          Image(systemName: "chevron.right")
            .foregroundStyle(.gray)
        }
      }
      .disabled(disabled)

      if savedLocations.isEmpty {
        HStack(spacing: 8) {
          Image(systemName: "info.circle")
            .foregroundColor(.secondary)
          Text("Add locations in Settings first")
            .font(.caption)
            .foregroundColor(.secondary)
        }
      } else if hasRule {
        HStack(spacing: 8) {
          Image(systemName: geofenceRule?.ruleType.iconName ?? "location.circle")
            .foregroundColor(themeManager.themeColor)
          Text(summaryText)
            .font(.footnote)
            .foregroundColor(.secondary)
        }

        if !disabled {
          Button {
            geofenceRule = nil
          } label: {
            Text("Remove restriction")
              .font(.caption)
              .foregroundColor(.red)
          }
        }
      } else {
        Text("No location restrictions set")
          .font(.footnote)
          .foregroundColor(.gray)
      }
    }
  }
}

#Preview {
  struct PreviewContainer: View {
    @State var ruleWithLocations: ProfileGeofenceRule? = ProfileGeofenceRule(
      ruleType: .within,
      locationReferences: [
        ProfileLocationReference(savedLocationId: UUID()),
        ProfileLocationReference(savedLocationId: UUID()),
      ]
    )

    @State var emptyRule: ProfileGeofenceRule? = nil

    let sampleLocations = [
      SavedLocation(name: "Home", latitude: 51.5074, longitude: -0.1278),
      SavedLocation(name: "Office", latitude: 51.5155, longitude: -0.1419),
    ]

    var body: some View {
      Form {
        Section("With Locations") {
          BlockedProfileGeofenceSelector(
            geofenceRule: $ruleWithLocations,
            savedLocations: sampleLocations,
            buttonAction: {}
          )
        }

        Section("No Rule") {
          BlockedProfileGeofenceSelector(
            geofenceRule: $emptyRule,
            savedLocations: sampleLocations,
            buttonAction: {}
          )
        }

        Section("No Saved Locations") {
          BlockedProfileGeofenceSelector(
            geofenceRule: $emptyRule,
            savedLocations: [],
            buttonAction: {}
          )
        }

        Section("Disabled") {
          BlockedProfileGeofenceSelector(
            geofenceRule: $ruleWithLocations,
            savedLocations: sampleLocations,
            buttonAction: {},
            disabled: true
          )
        }
      }
      .environmentObject(ThemeManager.shared)
    }
  }

  return PreviewContainer()
}
