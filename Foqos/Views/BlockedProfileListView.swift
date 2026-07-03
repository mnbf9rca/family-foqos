import FamilyControls
@preconcurrency import SwiftData  // ReferenceWritableKeyPath in @Query lacks Sendable conformance
import SwiftUI

struct BlockedProfileListView: View {
  @Environment(\.modelContext) private var context
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var profileSyncManager: ProfileSyncManager

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
        SafeModelView(profile) { p in
          ProfileRow(profile: p)
            .contentShape(Rectangle())
            .onTapGesture {
              if editMode == .inactive {
                profileToEdit = p
              }
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
        let profileId = profile.id
        if profileSyncManager.isEnabled {
          // Route the delete entirely through the funnel (I2): it re-reads the profile
          // itself, writes the delete-intent tombstone, performs the persisted delete, and
          // enqueues the `.deleteRecord` — all in one call. The view's `context` here is the
          // SAME `ModelContext` instance the funnel uses (both are `container.mainContext`),
          // so the view must NOT pre-delete: an unsaved `context.delete()` is already
          // excluded from the funnel's own re-fetch-by-id on that shared context, which
          // would throw `entityNotFound` and roll back (undoing the delete entirely). Must
          // run BEFORE the reorder below, whose `context.save()` would otherwise commit
          // ahead of the funnel.
          profileSyncManager.enqueueProfileDelete(profileId)
        } else {
          // Sync disabled — the funnel would no-op (I2 is only reachable once the engine has
          // started), so delete locally directly.
          try BlockedProfiles.deleteProfile(profile, in: context)
        }
      }

      // Reorder remaining profiles to fix gaps in ordering
      let remainingProfiles = try BlockedProfiles.fetchProfiles(in: context)
      try BlockedProfiles.reorderProfiles(remainingProfiles, in: context)
      // The `order` field is synced state — bump syncVersion + enqueue a save for each
      // surviving profile so the gap-fix reaches other devices (I2).
      for profile in remainingProfiles {
        profileSyncManager.enqueueProfileSave(profile.id)
      }
    } catch {
      Log.error("Failed to delete or reorder profiles: \(error)", category: .ui)
    }
  }

  private func moveProfiles(from source: IndexSet, to destination: Int) {
    var reorderedProfiles = profiles
    reorderedProfiles.move(fromOffsets: source, toOffset: destination)

    do {
      try BlockedProfiles.reorderProfiles(reorderedProfiles, in: context)
      // Persist the new order to sync (I2) — drag-reorder mutates the synced `order`
      // field and must not bypass the funnel.
      for profile in reorderedProfiles {
        profileSyncManager.enqueueProfileSave(profile.id)
      }
    } catch {
      Log.error("Failed to reorder profiles: \(error)", category: .ui)
    }
  }
}

#Preview {
  BlockedProfileListView()
    .environmentObject(ProfileSyncManager.shared)
    .modelContainer(for: BlockedProfiles.self, inMemory: true)
}
