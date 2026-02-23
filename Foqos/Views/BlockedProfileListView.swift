import FamilyControls
@preconcurrency import SwiftData  // ReferenceWritableKeyPath in @Query lacks Sendable conformance
import SwiftUI

struct BlockedProfileListView: View {
  @Environment(\.modelContext) private var context
  @Environment(\.dismiss) private var dismiss

  @SafeQuery(sort: [
    SortDescriptor(\BlockedProfiles.order, order: .forward),
    SortDescriptor(\BlockedProfiles.createdAt, order: .reverse),
  ]) private var profiles: [BlockedProfiles]

  @State private var showingCreateProfile = false
  @State private var showingDataExport = false

  @State private var profileToEdit: BlockedProfiles?
  @State private var deleteError: DeleteError?
  @State private var editMode: EditMode = .inactive

  private enum DeleteError {
    case activeProfile
    case fetchFailed

    var title: String {
      switch self {
      case .activeProfile: "Cannot Delete Active Profile"
      case .fetchFailed: "Unable to Delete"
      }
    }

    var message: String {
      switch self {
      case .activeProfile:
        "You cannot delete a profile that is currently active. Please switch to a different profile first."
      case .fetchFailed:
        "Something went wrong while checking profile status. Please try again."
      }
    }
  }

  @ViewBuilder
  private var contentView: some View {
    if profiles.isEmpty {
      EmptyStateView(
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
      ForEach(profiles) { profile in
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
            if !profiles.isEmpty {
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
          deleteError?.title ?? "",
          isPresented: Binding(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } }
          )
        ) {
          Button("OK", role: .cancel) {}
        } message: {
          Text(deleteError?.message ?? "")
        }
    }
  }

  private func deleteProfiles(at offsets: IndexSet) {
    var activeSession: BlockedProfileSession?
    do {
      activeSession = try BlockedProfileSession.mostRecentActiveSession(in: context)
    } catch {
      Log.error("Failed to determine active session: \(error.localizedDescription)", category: .ui)
      deleteError = .fetchFailed
      return
    }
    let profilesToDelete = profiles

    // Check if any of the profiles to delete are active
    for index in offsets {
      let profile = profilesToDelete[index]
      if profile.id == activeSession?.blockedProfile.id {
        deleteError = .activeProfile
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
    var reorderedProfiles = profiles
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
