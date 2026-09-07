import SwiftData
import SwiftUI

struct EditTagView: View {
  @Environment(\.modelContext) private var context
  @Environment(\.dismiss) private var dismiss
  @ObservedObject private var syncManager = ProfileSyncManager.shared
  @SafeQuery private var profiles: [BlockedProfiles]
  let id: String
  let kind: String
  let isNew: Bool
  @State private var name: String
  @State private var showingRemove = false
  @State private var errorMessage: String?

  init(id: String, kind: String, initialName: String, isNew: Bool) {
    self.id = id
    self.kind = kind
    self.isNew = isNew
    _name = State(initialValue: initialName)
  }

  private var usedBy: [String] { SavedTag.assignments(profiles: profiles)[id] ?? [] }
  private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Name", text: $name)
        } footer: {
          if isNew {
            Text("\(kind == "nfc" ? "NFC tag" : "QR code"). Pick a name you will recognise on the profile screen.")
          } else {
            Text("\(kind == "nfc" ? "NFC tag" : "QR code") · \(usedBy.isEmpty ? "Not used by any profile" : "Used by " + usedBy.joined(separator: ", "))")
          }
        }
        if !isNew {
          Section {
            Button("Remove Tag", role: .destructive) { showingRemove = true }
              .disabled(!usedBy.isEmpty)
          } footer: {
            if !usedBy.isEmpty {
              Text("This tag cannot be removed while \(usedBy.joined(separator: " and ")) use it. Edit those profiles first.")
            }
          }
        }
      }
      .navigationTitle(isNew ? "Name Tag" : "Edit Tag")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(trimmedName.isEmpty) }
      }
      .confirmationDialog("Remove \"\(name)\"?", isPresented: $showingRemove, titleVisibility: .visible) {
        Button("Remove", role: .destructive, action: remove)
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("Profiles cannot use it afterwards.")
      }
      .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(errorMessage ?? "")
      }
    }
  }

  private func save() {
    guard !trimmedName.isEmpty else { return }
    do {
      if isNew {
        _ = try SavedTag.findOrCreate(id: id, kind: kind, name: trimmedName, in: context)
      } else {
        guard let tag = try SavedTag.find(byID: id, in: context) else {
          throw MutationFunnel.MutationFunnelError.entityNotFound
        }
        tag.name = trimmedName
        tag.updatedAt = Date()
      }
      try context.save()
      if syncManager.isEnabled {
        do { try syncManager.enqueueTagSave(id) } catch SyncEngineControllingError.notAttached {
          Log.info("Tag save deferred until sync attaches", category: .sync)
        }
      }
      dismiss()
    } catch { errorMessage = "Failed to save tag: \(error.localizedDescription)" }
  }

  private func remove() {
    do {
      // Re-fetch at confirmation so a newly-synced assignment also prevents removal.
      let assignments = SavedTag.assignments(profiles: try BlockedProfiles.fetchProfiles(in: context))
      guard assignments[id] == nil else {
        errorMessage = "This tag is used by a profile. Edit that profile first."
        return
      }
      guard let tag = try SavedTag.find(byID: id, in: context) else {
        dismiss()
        return
      }
      let recordName = tag.recordName
      if syncManager.isEnabled {
        do { try syncManager.enqueueTagDelete(id) } catch SyncEngineControllingError.notAttached { try SavedTag.delete(tag, in: context) }
      } else {
        try SavedTag.delete(tag, in: context)
        syncManager.recordDisabledDeleteTombstone(recordName: recordName)
      }
      dismiss()
    } catch { errorMessage = "Failed to remove tag: \(error.localizedDescription)" }
  }
}
