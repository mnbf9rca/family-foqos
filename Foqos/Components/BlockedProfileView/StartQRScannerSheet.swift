// Foqos/Components/BlockedProfileView/StartQRScannerSheet.swift
import CodeScanner
import SwiftUI

/// QR scanner sheet for starting a profile via QR trigger
struct StartQRScannerSheet: View {
  let profileName: String
  let onCodeScanned: (String) -> Void
  let onCancel: () -> Void

  var body: some View {
    NavigationStack {
      LabeledCodeScannerView(
        heading: "Scan QR Code",
        subtitle: "Point your camera at a QR code to start \(profileName)."
      ) { result in
        switch result {
        case .success(let scanResult):
          onCodeScanned(scanResult.string)
        case .failure:
          // Error handled by LabeledCodeScannerView
          break
        }
      }
      .navigationTitle("Start with QR")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            onCancel()
          }
        }
      }
    }
  }
}

#Preview {
  StartQRScannerSheet(
    profileName: "Work Focus",
    onCodeScanned: { _ in },
    onCancel: {}
  )
}
