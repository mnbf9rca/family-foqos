import SwiftData
import SwiftUI

struct TagsView: View {
  @Environment(\.modelContext) private var context
  @Environment(\.dismiss) private var dismiss
  @SafeQuery(sort: \SavedTag.name) private var tags: [SavedTag]
  @SafeQuery private var profiles: [BlockedProfiles]
  @StateObject private var scanner = NFCScannerUtil()
  private let reader = PhysicalReader()
  @State private var showingScanOptions = false
  @State private var showingQRScanner = false
  @State private var scannedQR: String?
  @State private var editor: Editor?
  @State private var errorMessage: String?
  @State private var duplicateName: String?

  private struct Editor: Identifiable {
    let id: String
    let kind: String
    let name: String
    let isNew: Bool
  }

  var body: some View {
    NavigationStack {
      List {
        if tags.isEmpty {
          ContentUnavailableView {
            Label("No Tags", systemImage: "tag.slash")
          } description: {
            Text("Scan an NFC tag or QR code to add it.")
          } actions: {
            Button("Add Tag", systemImage: "plus") { showingScanOptions = true }
              .buttonStyle(.borderedProminent)
          }
        } else {
          Section {
            let assignments = SavedTag.assignments(profiles: profiles)
            ForEach(tags) { tag in
              SafeModelView(tag) { tag in
                let target = Editor(id: tag.id, kind: tag.kind, name: tag.name, isNew: false)
                Button {
                  editor = target
                } label: {
                  HStack {
                    VStack(alignment: .leading) {
                      Text(target.name).foregroundStyle(.primary)
                      Text("\(target.kind == "nfc" ? "NFC tag" : "QR code") · \(assignments[target.id].map { "Used by " + $0.joined(separator: ", ") } ?? "Not used")")
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                  }
                }
              }
            }
          } header: {
            Text("Your Tags")
          } footer: {
            Text("Tags a profile uses can be renamed but not removed. Edit the profile to stop using a tag.")
          }
        }
      }
      .navigationTitle("Tags")
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Close", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button("Add Tag", systemImage: "plus") { showingScanOptions = true }.labelStyle(.iconOnly)
        }
      }
      .confirmationDialog("Add Tag", isPresented: $showingScanOptions, titleVisibility: .visible) {
        Button("Scan NFC tag") {
          scanner.onTagScanned = { handleScan(id: $0.id, kind: "nfc") }
          scanner.onError = { errorMessage = $0 }
          scanner.scan(profileName: "your tag list")
        }
        Button("Scan QR code") { showingQRScanner = true }
        Button("Cancel", role: .cancel) {}
      }
      .sheet(
        isPresented: $showingQRScanner,
        onDismiss: {
          if let id = scannedQR {
            scannedQR = nil
            handleScan(id: id, kind: "qr")
          }
        }
      ) {
        BlockingStrategyActionView(
          customView: reader.readQRCode(
            onSuccess: {
              scannedQR = $0
              showingQRScanner = false
            },
            onFailure: {
              errorMessage = $0
              showingQRScanner = false
            }))
      }
      .sheet(item: $editor) { target in
        EditTagView(id: target.id, kind: target.kind, initialName: target.name, isNew: target.isNew)
      }
      .alert("Already added", isPresented: Binding(get: { duplicateName != nil }, set: { if !$0 { duplicateName = nil } })) {
        Button("OK", role: .cancel) {}
      } message: {
        Text("This tag is already on your list as \"\(duplicateName ?? "")\".")
      }
      .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(errorMessage ?? "")
      }
    }
  }

  private func handleScan(id: String, kind: String) {
    do {
      if let existing = try SavedTag.find(byID: id, in: context) {
        duplicateName = existing.name
      } else {
        let number = tags.filter { $0.kind == kind }.count + 1
        editor = Editor(id: id, kind: kind, name: "\(kind == "nfc" ? "NFC tag" : "QR code") \(number)", isNew: true)
      }
    } catch { errorMessage = "Failed to look up tag: \(error.localizedDescription)" }
  }
}
