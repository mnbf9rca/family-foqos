@preconcurrency import CoreNFC  // NFCTagReaderSession, NFCMiFareTag, NFCISO15693Tag lack Sendable
import SwiftUI

/// Writes NDEF-formatted URLs to NFC tags
///
/// **Supported Tags:**
/// - Blank NTAG (NTAG213, NTAG215, NTAG216)
/// - MiFare Ultralight with NDEF formatting
/// - Other NDEF-compliant tags
///
/// **NOT Supported (will show error):**
/// - Amiibos (proprietary Nintendo format)
/// - Hotel key cards (proprietary lock system data)
/// - Read-only/locked tags
/// - Non-NDEF formatted tags
@MainActor
class NFCWriter: NSObject, ObservableObject {
  var scannedNFCTag: NFCResult?
  var isScanning: Bool = false
  var errorMessage: String?

  private var tagSession: NFCTagReaderSession?
  private var urlToWrite: String?

  func resultFromURL(_ url: String) -> NFCResult {
    return NFCResult(id: url, url: url, DateScanned: Date())
  }

  func writeURL(_ url: String) {
    guard NFCReaderSession.readingAvailable else {
      self.errorMessage = "NFC writing not available on this device"
      return
    }

    guard URL(string: url) != nil else {
      self.errorMessage = "Invalid URL format"
      return
    }

    urlToWrite = url

    // Use NFCTagReaderSession to detect ALL tag types (including non-NDEF)
    // This allows us to show proper errors for Amiibos, hotel cards, etc.
    tagSession = NFCTagReaderSession(
      pollingOption: [.iso14443, .iso15693],
      delegate: self,
      queue: nil
    )
    tagSession?.alertMessage = "Hold your iPhone near an NFC tag to write the profile."
    tagSession?.begin()

    isScanning = true
  }
}

// MARK: - Sendable Wrappers for CoreNFC Types
// CoreNFC types are not Sendable but are thread-safe when used with their session's queue.
// These wrappers allow passing them through @Sendable closures in callback chains.

private struct NFCSessionBox: @unchecked Sendable {  // SAFETY: NFCTagReaderSession is only used on CoreNFC's internal queue
  private let session: NFCTagReaderSession

  init(session: NFCTagReaderSession) {
    self.session = session
  }

  func connect(to tag: NFCTag, completionHandler: @escaping @Sendable (Error?) -> Void) {
    session.connect(to: tag, completionHandler: completionHandler)
  }

  func invalidate(errorMessage: String) {
    session.invalidate(errorMessage: errorMessage)
  }

  func invalidate() {
    session.invalidate()
  }

  var alertMessage: String {
    get { session.alertMessage }
    nonmutating set { session.alertMessage = newValue }
  }
}

private struct NFCTagBox: @unchecked Sendable {  // SAFETY: NFCTag is only used on CoreNFC's internal queue after connection
  let tag: NFCTag
}

private struct NFCMiFareTagBox: @unchecked Sendable {  // SAFETY: NFCMiFareTag is only used on CoreNFC's internal queue
  let tag: NFCMiFareTag

  func queryNDEFStatus(completionHandler: @escaping @Sendable (NFCNDEFStatus, Int, (any Error)?) -> Void) {
    tag.queryNDEFStatus(completionHandler: completionHandler)
  }
}

private struct NFCISO15693TagBox: @unchecked Sendable {  // SAFETY: NFCISO15693Tag is only used on CoreNFC's internal queue
  let tag: NFCISO15693Tag

  func queryNDEFStatus(completionHandler: @escaping @Sendable (NFCNDEFStatus, Int, (any Error)?) -> Void) {
    tag.queryNDEFStatus(completionHandler: completionHandler)
  }
}

private struct NFCNDEFTagBox: @unchecked Sendable {  // SAFETY: NFCNDEFTag is only used on CoreNFC's internal queue
  let tag: NFCNDEFTag

  func writeNDEF(_ ndefMessage: NFCNDEFMessage, completionHandler: @escaping @Sendable ((any Error)?) -> Void) {
    tag.writeNDEF(ndefMessage, completionHandler: completionHandler)
  }
}

private struct NFCNDEFMessageBox: @unchecked Sendable {  // SAFETY: NFCNDEFMessage is immutable after creation
  let message: NFCNDEFMessage

  var length: Int { message.length }
}

// MARK: - NFCTagReaderSessionDelegate
extension NFCWriter: NFCTagReaderSessionDelegate {
  nonisolated func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {
    // Session became active
  }

  nonisolated func tagReaderSession(
    _ session: NFCTagReaderSession, didInvalidateWithError error: Error
  ) {
    // Capture values before MainActor hop
    let readerError = error as? NFCReaderError
    let errorCode = readerError?.code
    let localizedDescription = error.localizedDescription

    Task { @MainActor in
      self.isScanning = false

      if let errorCode = errorCode {
        switch errorCode {
        case .readerSessionInvalidationErrorUserCanceled:
          // User canceled - not an error
          break
        case .readerSessionInvalidationErrorSessionTimeout:
          self.errorMessage = "Session timed out. Please try again."
        case .readerTransceiveErrorTagConnectionLost:
          self.errorMessage = "Tag moved away. Please hold it steady."
        default:
          // Log the actual error for debugging
          Log.info(
            "⚠️ NFC Writer error: \(errorCode.rawValue) - \(localizedDescription)", category: .nfc)
          self.errorMessage = localizedDescription
        }
      }
    }
  }

  nonisolated func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
    guard let tag = tags.first else {
      session.invalidate(errorMessage: "No tag found")
      return
    }

    // Fetch URL from MainActor FIRST, then proceed with all NFC work
    let sessionBox = NFCSessionBox(session: session)
    let tagBox = NFCTagBox(tag: tag)

    Task { @MainActor in
      guard let urlString = self.urlToWrite,
        let url = URL(string: urlString),
        let urlPayload = NFCNDEFPayload.wellKnownTypeURIPayload(url: url)
      else {
        sessionBox.invalidate(errorMessage: "Invalid URL format")
        return
      }

      let message = NFCNDEFMessage(records: [urlPayload])
      let messageBox = NFCNDEFMessageBox(message: message)

      // Now proceed with NFC operations - pass all needed data through closures
      self.connectAndWrite(sessionBox: sessionBox, tagBox: tagBox, messageBox: messageBox)
    }
  }

  // MARK: - NFC Operations (nonisolated - all work happens on CoreNFC's queue)

  nonisolated private func connectAndWrite(
    sessionBox: NFCSessionBox, tagBox: NFCTagBox, messageBox: NFCNDEFMessageBox
  ) {
    sessionBox.connect(to: tagBox.tag) { error in
      if error != nil {
        sessionBox.invalidate(
          errorMessage: "Connection error. Please hold tag steady and try again.")
        return
      }

      // Handle different tag types
      switch tagBox.tag {
      case .miFare(let miFareTag):
        self.handleMiFareTagWrite(
          NFCMiFareTagBox(tag: miFareTag), sessionBox: sessionBox, messageBox: messageBox)
      case .iso15693(let iso15693Tag):
        self.handleISO15693TagWrite(
          NFCISO15693TagBox(tag: iso15693Tag), sessionBox: sessionBox, messageBox: messageBox)
      case .iso7816:
        sessionBox.invalidate(errorMessage: "This type of card cannot be written to.")
      case .feliCa:
        sessionBox.invalidate(errorMessage: "This type of card cannot be written to.")
      @unknown default:
        sessionBox.invalidate(errorMessage: "Unsupported tag type")
      }
    }
  }

  nonisolated private func handleMiFareTagWrite(
    _ tagBox: NFCMiFareTagBox, sessionBox: NFCSessionBox, messageBox: NFCNDEFMessageBox
  ) {
    tagBox.queryNDEFStatus { status, capacity, error in
      if error != nil {
        sessionBox.invalidate(
          errorMessage: "This tag cannot be written to. Use a blank NFC tag instead.")
        return
      }

      switch status {
      case .notSupported:
        sessionBox.invalidate(
          errorMessage: "This tag uses a proprietary format. Use a blank NFC tag instead.")
      case .readOnly:
        sessionBox.invalidate(errorMessage: "This tag is locked and cannot be modified.")
      case .readWrite:
        self.writeNDEFMessage(
          NFCNDEFTagBox(tag: tagBox.tag), sessionBox: sessionBox, messageBox: messageBox,
          capacity: capacity)
      @unknown default:
        sessionBox.invalidate(errorMessage: "Unknown tag status")
      }
    }
  }

  nonisolated private func handleISO15693TagWrite(
    _ tagBox: NFCISO15693TagBox, sessionBox: NFCSessionBox, messageBox: NFCNDEFMessageBox
  ) {
    tagBox.queryNDEFStatus { status, capacity, error in
      if error != nil {
        sessionBox.invalidate(
          errorMessage: "This tag cannot be written to. Use a blank NFC tag instead.")
        return
      }

      switch status {
      case .notSupported:
        sessionBox.invalidate(
          errorMessage: "This tag uses a proprietary format. Use a blank NFC tag instead.")
      case .readOnly:
        sessionBox.invalidate(errorMessage: "This tag is locked and cannot be modified.")
      case .readWrite:
        self.writeNDEFMessage(
          NFCNDEFTagBox(tag: tagBox.tag), sessionBox: sessionBox, messageBox: messageBox,
          capacity: capacity)
      @unknown default:
        sessionBox.invalidate(errorMessage: "Unknown tag status")
      }
    }
  }

  nonisolated private func writeNDEFMessage(
    _ tagBox: NFCNDEFTagBox, sessionBox: NFCSessionBox, messageBox: NFCNDEFMessageBox, capacity: Int
  ) {
    let messageSize = messageBox.length
    if messageSize > capacity {
      sessionBox.invalidate(
        errorMessage: "URL too long for this tag (\(messageSize) > \(capacity) bytes)")
      return
    }

    tagBox.writeNDEF(messageBox.message) { error in
      if error != nil {
        sessionBox.invalidate(errorMessage: "Write failed. Please try again.")
      } else {
        sessionBox.alertMessage = "✓ Successfully wrote profile to tag"
        Task { @MainActor in
          self.isScanning = false
        }
        sessionBox.invalidate()
      }
    }
  }
}
