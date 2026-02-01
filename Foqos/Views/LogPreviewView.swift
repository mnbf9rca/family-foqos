import SwiftUI

struct LogPreviewView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var logContent: String = ""
  @State private var searchText: String = ""
  @State private var isLoading: Bool = true
  private let maxPreviewLines = 100

  private var filteredContent: String {
    if searchText.isEmpty {
      return logContent
    }
    return logContent
      .components(separatedBy: "\n")
      .filter { $0.localizedCaseInsensitiveContains(searchText) }
      .joined(separator: "\n")
  }

  var body: some View {
    NavigationStack {
      Group {
        if isLoading {
          ProgressView("Loading logs...")
        } else if logContent.isEmpty {
          ContentUnavailableView(
            "No Logs",
            systemImage: "doc.text",
            description: Text("No log entries found.")
          )
        } else {
          ScrollView {
            VStack(alignment: .leading, spacing: 8) {
              Text("Showing up to \(maxPreviewLines) lines")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal)

              Text(filteredContent)
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .textSelection(.enabled)
            }
          }
        }
      }
      .navigationTitle("Log Preview")
      .navigationBarTitleDisplayMode(.inline)
      .searchable(text: $searchText, prompt: "Search logs")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") {
            dismiss()
          }
        }
      }
      .onAppear {
        loadLogs()
      }
    }
  }

  private func loadLogs() {
    DispatchQueue.global(qos: .userInitiated).async {
      // Tail last N lines to avoid UI hang on large logs
      let content = Log.shared.getLogContentTail(maxLines: maxPreviewLines)
      DispatchQueue.main.async {
        logContent = content
        isLoading = false
      }
    }
  }
}

#Preview {
  LogPreviewView()
}
