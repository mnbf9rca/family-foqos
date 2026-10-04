import SwiftUI

struct LogExportView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var isExporting = false
  private struct LogExport: Identifiable {
    let url: URL
    var id: URL { url }
  }

  @State private var logExport: LogExport?
  @State private var errorMessage: String?
  @State private var showingPreview = false
  @State private var logStats: LogStats = LogStats()
  @State private var includeFamilyRoster = false

  struct LogStats {
    var fileCount: Int = 0
    var totalSize: String = "0 KB"
    var oldestEntry: String = "N/A"
    var newestEntry: String = "N/A"
  }

  var body: some View {
    NavigationStack {
      List {
        Section {
          VStack(alignment: .leading, spacing: 12) {
            Text(
              "Share diagnostic logs with the developer to help troubleshoot issues."
            )
            .font(.subheadline)
            .foregroundColor(.secondary)

            Text(
              includeFamilyRoster
                ? "This export includes family roles, full identifiers, and CloudKit record names in roster.txt, but no participant names. Family data refreshes in the background when this option is enabled, while Share Logs still works offline using available data. Share it only with Family Foqos support."
                : "Logs may contain profile names, timestamps, and technical device or account identifiers. Family member names, passwords, and lock codes are not included."
            )
            .font(.caption)
            .foregroundColor(.secondary)
          }
          .padding(.vertical, 8)
        }

        Section("Log Statistics") {
          LabeledContent("Log Files", value: "\(logStats.fileCount)")
          LabeledContent("Total Size", value: logStats.totalSize)
        }

        Section("Support Options") {
          Toggle("Include family roster", isOn: $includeFamilyRoster)
          Text(
            "Turn this on only when Family Foqos support asks. Adds roster.txt and refreshes family information in the background when possible so support can match diagnostic identifiers to family members."
          )
          .font(.caption)
          .foregroundColor(.secondary)
        }

        Section {
          Button {
            showingPreview = true
          } label: {
            HStack {
              Image(systemName: "doc.text.magnifyingglass")
              Text("Preview Logs")
              Spacer()
              Image(systemName: "chevron.right")
                .foregroundColor(.secondary)
            }
          }
          .disabled(logStats.fileCount == 0)

          Button {
            exportLogs()
          } label: {
            HStack {
              Image(systemName: "square.and.arrow.up")
              Text("Share Logs")
              Spacer()
              if isExporting {
                ProgressView()
              }
            }
          }
          .disabled(isExporting || logStats.fileCount == 0)

          Button(role: .destructive) {
            clearLogs()
          } label: {
            HStack {
              Image(systemName: "trash")
              Text("Clear All Logs")
            }
          }
          .disabled(logStats.fileCount == 0)
        }

        Section("What's Included") {
          Label("App events and errors", systemImage: "doc.text")
          Label("CloudKit sync operations", systemImage: "cloud")
          Label("Session start/stop events", systemImage: "clock")
          Label("Device info (model, iOS version)", systemImage: "iphone")
          if includeFamilyRoster {
            Label("Family member roster for support", systemImage: "person.text.rectangle")
          }
        }

        Section("Not Included") {
          Label("Passwords or lock codes", systemImage: "lock.slash")
          Label("Family member names", systemImage: "person.slash")
          Label("Location coordinates", systemImage: "location.slash")
          Label("Blocked app names", systemImage: "app.badge.checkmark")
        }
      }
      .navigationTitle("Export Logs")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") {
            dismiss()
          }
        }
      }
      .alert(
        "Error",
        isPresented: .init(
          get: { errorMessage != nil },
          set: { if !$0 { errorMessage = nil } }
        )
      ) {
        Button("OK") { errorMessage = nil }
      } message: {
        Text(errorMessage ?? "")
      }
      .sheet(item: $logExport) { export in
        ShareSheet(activityItems: [export.url])
      }
      .sheet(isPresented: $showingPreview) {
        LogPreviewView()
      }
      .onAppear {
        refreshStats()
      }
      .onChange(of: includeFamilyRoster) { _, isEnabled in
        guard isEnabled else { return }

        Task {
          _ = try? await CloudKitManager.shared.fetchFamilyMembers()
        }
      }
    }
  }

  private func refreshStats() {
    let files = Log.shared.getLogFileURLs()
    logStats.fileCount = files.count
    logStats.totalSize = ByteCountFormatter.string(
      fromByteCount: Int64(Log.shared.getTotalLogSize()),
      countStyle: .file
    )
  }

  private func exportLogs() {
    Task {
      isExporting = true
      defer { isExporting = false }

      do {
        // Use zip archive instead of plain text file
        // createLogArchive() is async and offloads file I/O to a background thread
        let familyRoster =
          includeFamilyRoster
          ? FamilyRosterExport.content(
            for: CloudKitManager.shared.familyMembers,
            monitoredDevices: HeartbeatManager.shared.monitoredDevices
          )
          : nil
        let url = try await LogExportManager.shared.createLogArchive(familyRoster: familyRoster)
        logExport = LogExport(url: url)
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  private func clearLogs() {
    Log.shared.clearLogs()
    refreshStats()
  }
}

struct ShareSheet: UIViewControllerRepresentable {
  let activityItems: [Any]
  var excludedActivityTypes: [UIActivity.ActivityType]? = nil

  func makeUIViewController(context: Context) -> UIActivityViewController {
    let controller = UIActivityViewController(
      activityItems: activityItems,
      applicationActivities: nil
    )
    controller.excludedActivityTypes = excludedActivityTypes
    return controller
  }

  func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
  LogExportView()
}
