import SwiftData
import SwiftUI

struct SavedLocationsView: View {
  @Environment(\.modelContext) private var context
  @Environment(\.dismiss) private var dismiss

  @EnvironmentObject var themeManager: ThemeManager

  @ObservedObject private var appModeManager = AppModeManager.shared
  @ObservedObject private var lockCodeManager = LockCodeManager.shared
  @ObservedObject private var profileSyncManager = ProfileSyncManager.shared

  @Query(sort: \SavedLocation.name) private var locations: [SavedLocation]
  @Query private var profiles: [BlockedProfiles]

  @State private var showingAddLocation = false
  @State private var locationToEdit: SavedLocation?
  @State private var showingLockCodeEntry = false
  @State private var pendingDeleteLocation: SavedLocation?
  @State private var errorMessage: String?

  /// Location IDs that are in use by profiles with active sessions
  private var locationsInUseByActiveProfiles: [UUID: String] {
    var result: [UUID: String] = [:]
    for profile in profiles {
      // Check if profile has an active session
      let hasActiveSession = profile.sessions.contains { $0.isActive }
      guard hasActiveSession else { continue }

      // Get location IDs from the profile's geofence rule
      if let rule = profile.geofenceRule {
        for ref in rule.locationReferences {
          result[ref.savedLocationId] = profile.name
        }
      }
    }
    return result
  }

  var body: some View {
    NavigationStack {
      List {
        if locations.isEmpty {
          Section {
            VStack(spacing: 16) {
              Image(systemName: "mappin.slash")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

              Text("No Saved Locations")
                .font(.headline)

              Text("Add locations to use geofence-based restrictions on your profiles.")
                .font(.subheadline)
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
            .padding(.vertical, 32)
          }
        } else {
          Section {
            ForEach(locations) { location in
              SavedLocationCard(
                location: location,
                onTap: {
                  handleEdit(location)
                },
                inUseByProfile: locationsInUseByActiveProfiles[location.id]
              )
            }
          } header: {
            Text("Your Locations")
          } footer: {
            Text("These locations can be used to restrict when profiles can be stopped.")
          }
        }
      }
      .navigationTitle("Saved Locations")
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button(action: { dismiss() }) {
            Image(systemName: "xmark")
          }
          .accessibilityLabel("Close")
        }

        if !locations.isEmpty {
          ToolbarItem(placement: .topBarTrailing) {
            Button {
              showingAddLocation = true
            } label: {
              Image(systemName: "plus")
            }
            .accessibilityLabel("Add Location")
          }
        }
      }
      .sheet(isPresented: $showingAddLocation) {
        AddLocationView()
      }
      .sheet(item: $locationToEdit) { location in
        AddLocationView(
          editingLocation: location,
          onDelete: {
            handleDelete(location)
          }
        )
      }
      .sheet(isPresented: $showingLockCodeEntry) {
        LockCodeEntryView(
          title: "Enter Lock Code",
          subtitle: "This location is locked. Enter the lock code to delete it.",
          onVerify: { code in
            lockCodeManager.validateCode(code)
          },
          onSuccess: {
            if let location = pendingDeleteLocation {
              deleteLocation(location)
            }
            pendingDeleteLocation = nil
          }
        )
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
    }
  }

  private func handleEdit(_ location: SavedLocation) {
    // Note: Locked locations can be edited freely in Individual and Parent modes.
    // In Child mode, AddLocationView will prevent saving changes to locked locations.
    locationToEdit = location
  }

  private func handleDelete(_ location: SavedLocation) {
    if location.isLocked && appModeManager.currentMode == .child {
      pendingDeleteLocation = location
      showingLockCodeEntry = true
    } else {
      // Directly delete - confirmation was already shown in AddLocationView
      deleteLocation(location)
    }
  }

  private func deleteLocation(_ location: SavedLocation) {
    let locationId = location.id

    do {
      // Remove references from profiles that use this location
      removeLocationFromProfiles(locationId)

      try SavedLocation.delete(location, in: context)

      // Sync deletion to other devices if sync is enabled
      if profileSyncManager.isEnabled {
        Task {
          try? await profileSyncManager.deleteLocation(locationId)
        }
      }
    } catch {
      errorMessage = "Failed to delete location: \(error.localizedDescription)"
    }
  }

  private func removeLocationFromProfiles(_ locationId: UUID) {
    do {
      let profiles = try BlockedProfiles.fetchProfiles(in: context)
      for profile in profiles {
        if var rule = profile.geofenceRule {
          rule.locationReferences.removeAll { $0.savedLocationId == locationId }
          if rule.locationReferences.isEmpty {
            profile.geofenceRule = nil
          } else {
            profile.geofenceRule = rule
          }
        }
      }
      try context.save()
    } catch {
      Log.error("Failed to update profiles after location deletion: \(error)", category: .location)
    }
  }
}

#Preview {
  SavedLocationsView()
    .environmentObject(ThemeManager.shared)
    .modelContainer(for: [SavedLocation.self, BlockedProfiles.self], inMemory: true)
}
