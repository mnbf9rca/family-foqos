import AVFoundation
import CodeScanner
import SwiftUI
import UIKit

struct LabeledCodeScannerView: View {
  let heading: String
  let subtitle: String
  let simulatedData: String?
  let onScanResult: (Result<(hash: String, rawHash: String), ScanError>) -> Void

  @State private var camera =
    AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    ?? AVCaptureDevice.default(for: .video)
  @State private var zoomFactor: CGFloat = 1
  @State private var isShowingScanner = true
  @State private var errorMessage: String? = nil
  @State private var scanError: ScanError? = nil
  @State private var isTorchOn = false

  init(
    heading: String,
    subtitle: String,
    simulatedData: String? = nil,
    onScanResult: @escaping (Result<(hash: String, rawHash: String), ScanError>) -> Void
  ) {
    self.heading = heading
    self.subtitle = subtitle
    self.simulatedData = simulatedData
    self.onScanResult = onScanResult
  }

  var body: some View {
    VStack(alignment: .leading) {
      Text(heading)
        .font(.title2)
        .bold()
      Text(subtitle)
        .font(.subheadline)
        .foregroundColor(.gray)
        .padding(.bottom)

      if isShowingScanner {
        ZStack(alignment: .bottomTrailing) {
          CodeScannerView(
            codeTypes: [
              .aztec,
              .code128,
              .code39,
              .code39Mod43,
              .code93,
              .ean8,
              .ean13,
              .interleaved2of5,
              .itf14,
              .pdf417,
              .upce,
              .qr,
              .dataMatrix,
            ],
            showViewfinder: true,
            shouldVibrateOnSuccess: true,
            isTorchOn: isTorchOn,
            videoCaptureDevice: camera,
            completion: handleScanResult
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .cornerRadius(12)

          HStack {
            if let camera,
              Self.nextZoomFactor(
                current: zoomFactor, minimum: camera.minAvailableVideoZoomFactor,
                maximum: camera.maxAvailableVideoZoomFactor) != nil
            {
              Button(action: cycleZoom) {
                Text(Double(zoomFactor).formatted(.number.precision(.fractionLength(0...1))) + "x")
                  .font(.caption.bold().monospacedDigit())
                  .frame(width: 48, height: 48)
                  .foregroundStyle(.white)
                  .background(Color.black.opacity(0.6), in: Circle())
              }
              .accessibilityLabel("Camera zoom")
              .accessibilityValue("\(Double(zoomFactor).formatted()) times")
              .accessibilityHint("Cycles through the available zoom levels")
            }
            Spacer()
            Button(action: {
              isTorchOn.toggle()
            }) {
              Image(systemName: isTorchOn ? "flashlight.on.fill" : "flashlight.slash")
                .font(.system(size: 24))
                .foregroundColor(.white)
                .padding(12)
                .background(Color.black.opacity(0.6))
                .clipShape(Circle())
            }
            .accessibilityLabel(isTorchOn ? "Turn flashlight off" : "Turn flashlight on")
          }
          .buttonStyle(.plain)
          .padding(16)
        }
        .padding(.vertical, 10)
      } else if let scanError = scanError {
        if case ScanError.permissionDenied = scanError {
          VStack(spacing: 16) {
            Image(systemName: "camera.fill")
              .font(.system(size: 30))

            Text("Camera Access Required")
              .font(.headline)

            Text("To scan QR codes, you need to grant camera access to Family Foqos.")
              .font(.subheadline)
              .multilineTextAlignment(.center)
              .foregroundColor(.secondary)
              .padding(.horizontal)

            ActionButton(
              title: "Open Settings",
              backgroundColor: .red,
              iconName: "gearshape.fill"
            ) {
              if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(settingsURL)
              }
            }
            .padding(.horizontal, 24)
          }
          .frame(maxWidth: .infinity)
          .padding(.vertical, 30)
        } else {
          Text("Error: \(errorMessage ?? "Unknown error")")
            .foregroundColor(.red)
            .padding()
        }
      } else {

        Text("Scanner Paused or Not Available")
          .foregroundColor(.secondary)
          .padding()
      }

      Spacer()
    }
    .padding()
    .onAppear {
      isShowingScanner = true
      errorMessage = nil
      scanError = nil
      isTorchOn = false
      zoomFactor = camera?.videoZoomFactor ?? 1
    }
    .onDisappear {
      isShowingScanner = false
      scanError = nil
      isTorchOn = false
    }
  }

  static func nextZoomFactor(current: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat? {
    let factors: [CGFloat] = [1, 2, 5].filter { $0 >= minimum && $0 <= maximum }
    guard factors.count > 1 else { return nil }
    return factors.first { $0 > current } ?? factors.first
  }

  private func cycleZoom() {
    guard let camera else { return }
    do {
      try camera.lockForConfiguration()
      defer { camera.unlockForConfiguration() }
      guard
        let next = Self.nextZoomFactor(
          current: camera.videoZoomFactor, minimum: camera.minAvailableVideoZoomFactor,
          maximum: camera.maxAvailableVideoZoomFactor)
      else { return }
      camera.videoZoomFactor = next
      zoomFactor = camera.videoZoomFactor
    } catch {
      Log.warning("Unable to change scanner camera zoom", category: .ui)
    }
  }

  private func handleScanResult(_ result: Result<ScanResult, ScanError>) {
    switch result {
    case .success(let scanResult):
      isShowingScanner = false
      errorMessage = nil
      scanError = nil
      // Keep both digests so existing keys match the untouched original payload.
      // V1 profiles with active QR sessions store plaintext physicalUnblockQRCodeId;
      // those sessions will mismatch until ended (Emergency Unblock) and migrated to V2.
      onScanResult(
        .success(
          (
            hash: QRCodeHasher.hash(scanResult.string),
            rawHash: QRCodeHasher.rawHash(scanResult.string)
          )))
    case .failure(let error):
      if case ScanError.permissionDenied = error {
        isShowingScanner = false
        errorMessage = error.localizedDescription
        scanError = error
      } else {
        isShowingScanner = false
        errorMessage = error.localizedDescription
        scanError = error
        onScanResult(.failure(error))
      }
    }
  }
}

#Preview {  // Using the #Preview macro
  LabeledCodeScannerView(
    heading: "Scan QR Code",
    subtitle: "Point your camera at a QR code to activate a feature.",
    simulatedData: "Simulated QR Code Data for Preview"  // For preview purposes
  ) { result in
    switch result {
    case .success:
      Log.debug("Preview scanned code", category: .ui)
    case .failure:
      Log.debug("Preview scanning failed", category: .ui)
    }
  }
}
