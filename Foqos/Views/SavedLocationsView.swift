import SwiftData
import SwiftUI

struct SavedLocationsView: View {
  @Environment(\.modelContext) private var context
  @Environment(\.dismiss) private var dismiss

  @EnvironmentObject var themeManager: ThemeManager

  @ObservedObject private var appModeManager = AppModeManager.shared
  @ObservedObject private var lockCodeManager = LockCodeManager.shared
  @ObservedObject private var profileSyncManager = ProfileSyncManager.shared
  @ObservedObject private var strategyManager = StrategyManager.shared

  @SafeQuery(sort: \SavedLocation.name) private var locations: [SavedLocation]
  @SafeQuery private var profiles: [BlockedProfiles]

  @State private var showingAddLocation = false
  @State private var locationToEdit: SavedLocation?
  @State private var showingLockCodeEntry = false
  @State private var pendingDeleteLocation: SavedLocation?
  @State private var pendingEditLocation: SavedLocation?
  @State private var showingLockCodeEntryForEdit = false
  @State private var errorMessage: String?

  /// Location IDs that are in use by profiles with active sessions
  private var locationsInUseByActiveProfiles: [UUID: String] {
    Self.locationsInUse(
      profiles: profiles,
      hasLocalActiveSession: { $0.sessions.valid.contains { $0.isActive } },
      remotelyActiveProfileIds: strategyManager.remotelyActiveProfileIds)
  }

  static func locationsInUse(
    profiles: [BlockedProfiles],
    hasLocalActiveSession: (BlockedProfiles) -> Bool,
    remotelyActiveProfileIds: Set<UUID>
  ) -> [UUID: String] {
    var result: [UUID: String] = [:]
    for profile in profiles {
      let active = hasLocalActiveSession(profile) || remotelyActiveProfileIds.contains(profile.id)
      guard active else { continue }

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
              SafeModelView(location) { loc in
                SavedLocationCard(
                  location: loc,
                  onTap: {
                    handleEdit(loc)
                  },
                  inUseByProfile: locationsInUseByActiveProfiles[loc.id]
                )
              }
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
      .sheet(isPresented: $showingLockCodeEntryForEdit) {
        LockCodeEntryView(
          title: "Enter Lock Code",
          subtitle: "This location is locked. Enter the lock code to edit it.",
          onVerify: { code in
            lockCodeManager.validateCode(code)
          },
          onSuccess: {
            if let location = pendingEditLocation {
              locationToEdit = location
            }
            pendingEditLocation = nil
          }
        )
      }
      .alert(
        "Error",
        isPresented: .init(
          get: { errorMessage != nil },
          set: { if !$0 { errorMessage = nil } }
        )
      ) {
        Button("OK", role: .cancel) {}
      } message: {
        if let message = errorMessage {
          Text(message)
        }
      }
    }
  }

  private func handleEdit(_ location: SavedLocation) {
    if location.requiresLockCodeToModify(
      mode: appModeManager.currentMode,
      canVerifyCode: lockCodeManager.canVerifyCode)
    {
      pendingEditLocation = location
      showingLockCodeEntryForEdit = true
    } else {
      locationToEdit = location
    }
  }

  private func handleDelete(_ location: SavedLocation) {
    if location.requiresLockCodeToModify(
      mode: appModeManager.currentMode,
      canVerifyCode: lockCodeManager.canVerifyCode)
    {
      pendingDeleteLocation = location
      showingLockCodeEntry = true
    } else {
      // Directly delete - confirmation was already shown in AddLocationView
      deleteLocation(location)
    }
  }

  private func deleteLocation(_ location: SavedLocation) {
    let locationId = location.id

    if let profileName = locationsInUseByActiveProfiles[locationId] {
      errorMessage =
        "\"\(location.name)\" is in use by \"\(profileName)\", which is currently running "
        + "on this or another device. Stop that profile before deleting the location."
      return
    }

    do {
      if profileSyncManager.isEnabled {
        // Route the delete entirely through the funnel (I2): it re-reads the location
        // itself, writes the delete-intent tombstone, performs the persisted delete, and
        // enqueues the `.deleteRecord` — all in one call. `context` here is the SAME
        // `ModelContext` instance the funnel uses (both are `container.mainContext`), so
        // this view must NOT pre-delete: a committed local delete would leave the funnel's
        // re-fetch-by-id finding nothing, producing `entityNotFound` and swallowing the
        // tombstone with no `.deleteRecord` enqueued — the delete would never propagate to
        // other devices.
        do {
          try profileSyncManager.enqueueLocationDelete(locationId)
        } catch SyncEngineControllingError.notAttached {
          // Engine isn't attached yet (e.g. the brief window right after cold launch) —
          // the funnel can't own this delete, so delete locally now instead of silently
          // leaving the location behind (review finding #4). It will propagate once the
          // engine attaches / on the next sync.
          try BlockedProfiles.removeLocationReference(locationId, in: context)
          try SavedLocation.delete(location, in: context)
        }
      } else {
        // Sync disabled — the funnel would no-op (I2 is only reachable once the engine has
        // started), so delete locally directly.
        let deletedRecordName = locationId.uuidString
        try BlockedProfiles.removeLocationReference(locationId, in: context)
        try SavedLocation.delete(location, in: context)
        profileSyncManager.recordDisabledDeleteTombstone(recordName: deletedRecordName)
      }
    } catch {
      errorMessage = "Failed to delete location: \(error.localizedDescription)"
    }
  }
}

#Preview {
  SavedLocationsView()
    .environmentObject(ThemeManager.shared)
    .modelContainer(for: [SavedLocation.self, BlockedProfiles.self], inMemory: true)
}
