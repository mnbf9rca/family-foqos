import FamilyControls
import SwiftData
import SwiftUI

struct BlockedProfileListView: View {
  @Environment(\.modelContext) private var context
  @Environment(\.dismiss) private var dismiss

  @Query(sort: [
    SortDescriptor(\BlockedProfiles.order, order: .forward),
    SortDescriptor(\BlockedProfiles.createdAt, order: .reverse),
  ]) private var profiles: [BlockedProfiles]

  @State private var showingCreateProfile = false
  @State private var showingDataExport = false

  @State private var profileToEdit: BlockedProfiles?
  @State private var showErrorAlert = false
  @State private var editMode: EditMode = .inactive

  /// Filtered profiles excluding deleted models
  private var validProfiles: [BlockedProfiles] {
    profiles.valid
  }

  @ViewBuilder
  private var contentView: some View {
    if validProfiles.isEmpty {
      EmptyView(
        iconName: "person.crop.circle.badge.plus",
        headingText:
          "Group and switch between sets of blocked restrictions with customizable profiles"
      )
    } else {
      listView
    }
  }

  private var listView: some View {
    List {
      ForEach(validProfiles) { profile in
        ProfileRow(profile: profile)
          .contentShape(Rectangle())
          .onTapGesture {
            if editMode == .inactive {
              profileToEdit = profile
            }
          }
      }
      .onDelete(perform: deleteProfiles)
      .onMove(perform: moveProfiles)
    }
    .environment(\.editMode, $editMode)
  }

  var body: some View {
    NavigationStack {
      contentView
      .navigationTitle("Profiles")
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button(action: { dismiss() }) {
            Image(systemName: "xmark")
          }
        }

        ToolbarItemGroup(placement: .topBarTrailing) {
          if editMode == .active {
            Button(action: { editMode = .inactive }) {
              Image(systemName: "checkmark.circle")
            }
          }
          if !validProfiles.isEmpty {
            Menu {
              Button {
                editMode = .active
              } label: {
                Label("Edit/Move", systemImage: "pencil")
              }

              Button {
                showingDataExport = true
              } label: {
                Label("Export Data", systemImage: "square.and.arrow.up")
              }
            } label: {
              Image(systemName: "ellipsis.circle")
            }
          }
          Button(action: { showingCreateProfile = true }) {
            Image(systemName: "plus")
          }
        }
      }
      .sheet(isPresented: $showingCreateProfile) {
        BlockedProfileView()
      }
      .sheet(item: $profileToEdit) { profile in
        BlockedProfileView(profile: profile)
      }
      .sheet(isPresented: $showingDataExport) {
        BlockedProfileDataExportView()
      }
      .alert(
        "Cannot Delete Active Profile",
        isPresented: $showErrorAlert
      ) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(
          "You cannot delete a profile that is currently active. Please switch to a different profile first."
        )
      }
    }
  }

  private func deleteProfiles(at offsets: IndexSet) {
    let activeSession = BlockedProfileSession.mostRecentActiveSession(
      in: context)
    let profilesToDelete = validProfiles

    // Check if any of the profiles to delete are active
    for index in offsets {
      let profile = profilesToDelete[index]
      if profile.id == activeSession?.blockedProfile.id {
        showErrorAlert = true
        return
      }
    }

    // Delete the profiles and reorder
    do {
      for index in offsets {
        let profile = profilesToDelete[index]
        try BlockedProfiles.deleteProfile(profile, in: context)
      }

      // Reorder remaining profiles to fix gaps in ordering
      let remainingProfiles = try BlockedProfiles.fetchProfiles(in: context)
      try BlockedProfiles.reorderProfiles(remainingProfiles, in: context)
    } catch {
      Log.error("Failed to delete or reorder profiles: \(error)", category: .ui)
    }
  }

  private func moveProfiles(from source: IndexSet, to destination: Int) {
    var reorderedProfiles = validProfiles
    reorderedProfiles.move(fromOffsets: source, toOffset: destination)

    do {
      try BlockedProfiles.reorderProfiles(reorderedProfiles, in: context)
    } catch {
      Log.error("Failed to reorder profiles: \(error)", category: .ui)
    }
  }
}

#Preview {
  BlockedProfileListView()
    .modelContainer(for: BlockedProfiles.self, inMemory: true)
}
