import FamilyControls
@preconcurrency import SwiftData  // ReferenceWritableKeyPath in @Query lacks Sendable conformance
import SwiftUI

struct BlockedProfileListView: View {
  @Environment(\.modelContext) private var context
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var profileSyncManager: ProfileSyncManager
  @EnvironmentObject private var strategyManager: StrategyManager
  @ObservedObject private var appModeManager = AppModeManager.shared
  @ObservedObject private var lockCodeManager = LockCodeManager.shared

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
    case remotelyActiveProfile
    case lockedProfile
    case fetchFailed
    case syncFailed(String)

    var title: String {
      switch self {
      case .activeProfile: "Cannot Delete Active Profile"
      case .remotelyActiveProfile: "Active on Another Device"
      case .lockedProfile: "Profile Locked"
      case .fetchFailed: "Unable to Delete"
      case .syncFailed: "Sync Error"
      }
    }

    var message: String {
      switch self {
      case .activeProfile:
        "You cannot delete a profile that is currently active. Please switch to a different profile first."
      case .remotelyActiveProfile:
        "This profile is currently blocking on another device. Stop it there before deleting."
      case .lockedProfile:
        "This profile is locked. Open the profile, enter the lock code, "
          + "then delete it from the profile screen."
      case .fetchFailed:
        "Something went wrong while checking profile status. Please try again."
      case .syncFailed(let message):
        message
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
          // #298: build the snapshot ONLY here inside the validity gate (observation-tracked);
          // do NOT hoist/memoize - see the profileRowData tripwire.
          let data = p.profileRowData
          ProfileRow(data: data)
            .contentShape(Rectangle())
            .onTapGesture {
              if editMode == .inactive {
                handleEditProfile(data.id)
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

  private func handleEditProfile(_ profileId: UUID) {
    guard let profile = try? BlockedProfiles.findProfile(byID: profileId, in: context),
      profile.isPersistentModelValid
    else {
      return
    }
    profileToEdit = profile
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

    // Check if any of the profiles to delete are active or locked.
    for index in offsets {
      let profile = profilesToDelete[index]
      let reason = ProfileDeleteGate.blockedReason(
        hasLocalActiveSession: profile.id == activeSession?.blockedProfile.id,
        isRemotelyActive: strategyManager.remotelyActiveProfileIds.contains(profile.id),
        isEditLocked: lockCodeManager.isEditLocked(profile)
      )
      switch reason {
      case .active:
        deleteError = .activeProfile
        return
      case .remotelyActive:
        deleteError = .remotelyActiveProfile
        return
      case .locked:
        deleteError = .lockedProfile
        return
      case nil:
        break
      }
    }

    // Delete the profiles and reorder
    do {
      var disabledDeletedRecordNames: [String] = []
      var deletedProfileIds: [UUID] = []
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
          do {
            try profileSyncManager.enqueueProfileDelete(profileId)
          } catch SyncEngineControllingError.notAttached {
            // Engine isn't attached yet — the funnel can't own this delete, so delete
            // locally now instead of silently leaving the profile behind (review finding
            // #6). It will propagate once the engine attaches.
            try BlockedProfiles.deleteProfile(profile, in: context)
          }
        } else {
          // Sync disabled — the funnel would no-op (I2 is only reachable once the engine has
          // started), so delete locally directly. Remember the id for a tombstone only after
          // the shared reorder save durably commits.
          try BlockedProfiles.deleteProfile(profile, in: context)
          disabledDeletedRecordNames.append(profileId.uuidString)
        }
        deletedProfileIds.append(profileId)
      }

      BlockedProfiles.scheduleProfileDeleteCommit {
        do {
          // Reorder remaining profiles to fix gaps in ordering after SwiftUI settles pending deletes.
          let remainingProfiles = try BlockedProfiles.fetchProfiles(in: context)
          try BlockedProfiles.reorderProfiles(remainingProfiles, in: context)
          // The deletes are now durable. A failed save skips these writes, so a rolled-back
          // delete cannot leave a tombstone that could later kill a live record.
          for recordName in disabledDeletedRecordNames {
            profileSyncManager.recordDisabledDeleteTombstone(recordName: recordName)
          }
          for profileId in deletedProfileIds {
            strategyManager.setRemoteSessionActive(false, profileId: profileId)
          }
          // The `order` field is synced state — bump syncVersion + enqueue a save for each
          // surviving profile so the gap-fix reaches other devices (I2).
          for profile in remainingProfiles {
            do {
              try profileSyncManager.enqueueProfileSave(profile.id)
            } catch SyncEngineControllingError.notAttached {
              Log.warning("Profile reorder saved locally; sync engine not attached yet", category: .sync)
            }
          }
        } catch {
          Log.error("Failed to delete or reorder profiles: \(error)", category: .ui)
          deleteError = .syncFailed(error.localizedDescription)
        }
      }
    } catch {
      Log.error("Failed to delete or reorder profiles: \(error)", category: .ui)
      deleteError = .syncFailed(error.localizedDescription)
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
        do {
          try profileSyncManager.enqueueProfileSave(profile.id)
        } catch SyncEngineControllingError.notAttached {
          Log.warning("Profile reorder saved locally; sync engine not attached yet", category: .sync)
        }
      }
    } catch {
      Log.error("Failed to reorder profiles: \(error)", category: .ui)
      deleteError = .syncFailed(error.localizedDescription)
    }
  }
}

#Preview {
  BlockedProfileListView()
    .environmentObject(ProfileSyncManager.shared)
    .environmentObject(StrategyManager.shared)
    .modelContainer(for: BlockedProfiles.self, inMemory: true)
}
