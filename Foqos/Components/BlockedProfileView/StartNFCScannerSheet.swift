// Foqos/Components/BlockedProfileView/StartNFCScannerSheet.swift
import SwiftUI

/// NFC scanner sheet for starting a profile via NFC trigger
struct StartNFCScannerSheet: View {
  let profileName: String
  let onTagScanned: (String) -> Void
  let onCancel: () -> Void

  @State private var nfcScanner = NFCScannerUtil()
  @State private var errorMessage: String?
  @State private var isScanning = false

  var body: some View {
    NavigationStack {
      VStack(spacing: 24) {
        Image(systemName: "wave.3.right")
          .font(.system(size: 60))
          .foregroundStyle(.blue)

        Text("Scan NFC Tag")
          .font(.title2)
          .bold()

        Text("Hold your iPhone near an NFC tag to start \(profileName).")
          .multilineTextAlignment(.center)
          .foregroundStyle(.secondary)
          .padding(.horizontal)

        if isScanning {
          ProgressView("Scanning...")
        }

        if let error = errorMessage {
          Text(error)
            .foregroundStyle(.red)
            .font(.caption)
        }

        Button {
          startScanning()
        } label: {
          Label("Start Scanning", systemImage: "wave.3.right")
        }
        .buttonStyle(.borderedProminent)
        .disabled(isScanning)

        Spacer()
      }
      .padding()
      .navigationTitle("Start with NFC")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            onCancel()
          }
        }
      }
    }
    .onAppear {
      setupCallbacks()
      startScanning()
    }
  }

  private func setupCallbacks() {
    nfcScanner.onTagScanned = { result in
      isScanning = false
      onTagScanned(result.id)
    }
    nfcScanner.onError = { error in
      isScanning = false
      errorMessage = error
    }
  }

  private func startScanning() {
    errorMessage = nil
    isScanning = true
    nfcScanner.scan(profileName: profileName)
  }
}

#Preview {
  StartNFCScannerSheet(
    profileName: "Work Focus",
    onTagScanned: { _ in },
    onCancel: {}
  )
}
