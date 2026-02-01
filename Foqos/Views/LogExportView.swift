import SwiftUI

struct LogExportView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var isExporting = false
  @State private var showingShareSheet = false
  @State private var shareURL: URL?
  @State private var errorMessage: String?
  @State private var showingPreview = false
  @State private var logStats: LogStats = LogStats()

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
              "Logs may contain profile names and timestamps but no personal data like passwords or device identifiers."
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
        }

        Section("Not Included") {
          Label("Passwords or lock codes", systemImage: "lock.slash")
          Label("Personal identifiers", systemImage: "person.slash")
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
      .sheet(isPresented: $showingShareSheet) {
        if let url = shareURL {
          ShareSheet(activityItems: [url])
        }
      }
      .sheet(isPresented: $showingPreview) {
        LogPreviewView()
      }
      .onAppear {
        refreshStats()
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
    isExporting = true

    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let url = try LogExportManager.shared.getShareableLogFile()

        DispatchQueue.main.async {
          shareURL = url
          showingShareSheet = true
          isExporting = false
        }
      } catch {
        DispatchQueue.main.async {
          errorMessage = error.localizedDescription
          isExporting = false
        }
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
