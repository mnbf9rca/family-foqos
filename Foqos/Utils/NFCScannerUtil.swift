@preconcurrency import CoreNFC  // NFCTagReaderSession, NFCNDEFReaderSession, tag types lack Sendable
import SwiftUI

struct NFCResult: Equatable {
  var id: String
  var DateScanned: Date
}

@MainActor
class NFCScannerUtil: NSObject, ObservableObject {
  // Callback closures for handling results and errors
  var onTagScanned: ((NFCResult) -> Void)?
  var onError: ((String) -> Void)?

  private var nfcSession: NFCReaderSession?
  private var urlToWrite: String?
  private var scanCompleted = false

  func scan(profileName: String) {
    guard NFCReaderSession.readingAvailable else {
      self.onError?("NFC scanning not available on this device")
      return
    }

    scanCompleted = false
    nfcSession = NFCTagReaderSession(
      pollingOption: [.iso14443, .iso15693],
      delegate: self,
      queue: nil
    )
    nfcSession?.alertMessage = "Hold your iPhone near an NFC tag to trigger " + profileName
    nfcSession?.begin()
  }

  func writeURL(_ url: String) {
    guard NFCReaderSession.readingAvailable else {
      self.onError?("NFC writing not available on this device")
      return
    }

    guard URL(string: url) != nil else {
      self.onError?("Invalid URL format")
      return
    }

    urlToWrite = url

    // Using NFCNDEFReaderSession for writing
    let ndefSession = NFCNDEFReaderSession(
      delegate: self, queue: nil, invalidateAfterFirstRead: false)
    ndefSession.alertMessage =
      "Hold your iPhone near an NFC tag to write the profile."
    ndefSession.begin()
  }
}

// MARK: - Sendable Wrappers for CoreNFC Types
// CoreNFC types are not Sendable but are thread-safe when used with their session's queue.
// These wrappers allow passing them through @Sendable closures in callback chains.

private struct ScannerSessionBox: @unchecked Sendable {  // SAFETY: NFCTagReaderSession is only used on CoreNFC's internal queue
  let session: NFCTagReaderSession

  func connect(to tag: NFCTag, completionHandler: @escaping @Sendable (Error?) -> Void) {
    session.connect(to: tag, completionHandler: completionHandler)
  }

  func invalidate(errorMessage: String) {
    session.invalidate(errorMessage: errorMessage)
  }

  func invalidate() {
    session.invalidate()
  }
}

private struct ScannerNDEFSessionBox: @unchecked Sendable {  // SAFETY: NFCNDEFReaderSession is only used on CoreNFC's internal queue
  let session: NFCNDEFReaderSession

  func connect(to tag: NFCNDEFTag, completionHandler: @escaping @Sendable (Error?) -> Void) {
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

private struct ScannerTagBox: @unchecked Sendable {  // SAFETY: NFCTag is only used on CoreNFC's internal queue after connection
  let tag: NFCTag
}

private struct ScannerMiFareTagBox: @unchecked Sendable {  // SAFETY: NFCMiFareTag is only used on CoreNFC's internal queue
  let tag: NFCMiFareTag

  var identifier: Data { tag.identifier }

  func readNDEF(completionHandler: @escaping @Sendable (NFCNDEFMessage?, (any Error)?) -> Void) {
    tag.readNDEF(completionHandler: completionHandler)
  }
}

private struct ScannerISO15693TagBox: @unchecked Sendable {  // SAFETY: NFCISO15693Tag is only used on CoreNFC's internal queue
  let tag: NFCISO15693Tag

  var identifier: Data { tag.identifier }

  func readNDEF(completionHandler: @escaping @Sendable (NFCNDEFMessage?, (any Error)?) -> Void) {
    tag.readNDEF(completionHandler: completionHandler)
  }
}

private struct ScannerNDEFTagBox: @unchecked Sendable {  // SAFETY: NFCNDEFTag is only used on CoreNFC's internal queue
  let tag: NFCNDEFTag

  func queryNDEFStatus(completionHandler: @escaping @Sendable (NFCNDEFStatus, Int, (any Error)?) -> Void) {
    tag.queryNDEFStatus(completionHandler: completionHandler)
  }

  func writeNDEF(_ messageBox: ScannerNDEFMessageBox, completionHandler: @escaping @Sendable ((any Error)?) -> Void) {
    tag.writeNDEF(messageBox.message, completionHandler: completionHandler)
  }
}

private struct ScannerNDEFMessageBox: @unchecked Sendable {  // SAFETY: NFCNDEFMessage is immutable after creation
  let message: NFCNDEFMessage
}

// MARK: - NFCTagReaderSessionDelegate
extension NFCScannerUtil: NFCTagReaderSessionDelegate {
  nonisolated func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {
    // Session started
  }

  nonisolated func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
    let readerError = error as? NFCReaderError
    Task { @MainActor in
      // After a successful tag read, any invalidation error is expected and benign
      // (e.g., systemIsBusy during teardown, userCanceled from programmatic invalidate)
      guard !self.scanCompleted else { return }

      if let readerError = readerError {
        switch readerError.code {
        case .readerSessionInvalidationErrorUserCanceled:
          break  // User dismissed the NFC sheet without scanning
        default:
          self.onError?(readerError.localizedDescription)
        }
      } else {
        self.onError?(error.localizedDescription)
      }
    }
  }

  nonisolated func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
    guard let tag = tags.first else { return }

    let sessionBox = ScannerSessionBox(session: session)
    let tagBox = ScannerTagBox(tag: tag)

    sessionBox.connect(to: tagBox.tag) { error in
      if let error = error {
        sessionBox.invalidate(errorMessage: "Connection error: \(error.localizedDescription)")
        return
      }

      switch tagBox.tag {
      case .iso15693(let iso15693Tag):
        self.readISO15693Tag(ScannerISO15693TagBox(tag: iso15693Tag), sessionBox: sessionBox)
      case .miFare(let miFareTag):
        self.readMiFareTag(ScannerMiFareTagBox(tag: miFareTag), sessionBox: sessionBox)
      default:
        sessionBox.invalidate(errorMessage: "Unsupported tag type")
      }
    }
  }

  // MARK: - NFC Read Operations (nonisolated - all work happens on CoreNFC's queue)

  nonisolated private func readMiFareTag(_ tagBox: ScannerMiFareTagBox, sessionBox: ScannerSessionBox) {
    let tagIdentifier = tagBox.identifier.hexEncodedString()
    tagBox.readNDEF { (message: NFCNDEFMessage?, error: Error?) in
      if error != nil || message == nil {
        if let error = error {
          Log.info("⚠️ NDEF read failed (non-critical): \(error.localizedDescription). using tag id: \(tagIdentifier)", category: .nfc)
        }

        // Still use the identifier - works for all tag types
        self.completeTagScan(id: tagIdentifier, sessionBox: sessionBox)
        return
      }

      self.completeTagScan(id: tagIdentifier, sessionBox: sessionBox)
    }
  }

  nonisolated private func readISO15693Tag(_ tagBox: ScannerISO15693TagBox, sessionBox: ScannerSessionBox) {
    let tagIdentifier = tagBox.identifier.hexEncodedString()
    tagBox.readNDEF { (message: NFCNDEFMessage?, error: Error?) in
      if error != nil || message == nil {
        if let error = error {
          Log.info("⚠️ ISO15693 NDEF read failed (non-critical): \(error.localizedDescription). using tag id: \(tagIdentifier)", category: .nfc)
        }

        self.completeTagScan(id: tagIdentifier, sessionBox: sessionBox)
        return
      }

      self.completeTagScan(id: tagIdentifier, sessionBox: sessionBox)
    }
  }

  nonisolated private func completeTagScan(id: String, sessionBox: ScannerSessionBox) {
    let result = NFCResult(id: id, DateScanned: Date())
    Task { @MainActor in
      self.scanCompleted = true
      self.onTagScanned?(result)
    }
    sessionBox.invalidate()
  }
}

// MARK: - NFCNDEFReaderSessionDelegate (NDEF Writing Support)
extension NFCScannerUtil: NFCNDEFReaderSessionDelegate {
  nonisolated func readerSession(
    _ session: NFCNDEFReaderSession,
    didDetectNDEFs messages: [NFCNDEFMessage]
  ) {
    // Not used for writing
  }

  nonisolated func readerSession(
    _ session: NFCNDEFReaderSession, didDetect tags: [NFCNDEFTag]
  ) {
    guard let tag = tags.first else {
      session.invalidate(errorMessage: "No tag found")
      return
    }

    let sessionBox = ScannerNDEFSessionBox(session: session)
    let tagBox = ScannerNDEFTagBox(tag: tag)

    // Fetch URL from MainActor FIRST, then proceed with all NFC work
    Task { @MainActor in
      guard let urlString = self.urlToWrite,
        let url = URL(string: urlString),
        let urlPayload = NFCNDEFPayload.wellKnownTypeURIPayload(url: url)
      else {
        sessionBox.invalidate(errorMessage: "Invalid URL format")
        return
      }

      let message = NFCNDEFMessage(records: [urlPayload])
      let messageBox = ScannerNDEFMessageBox(message: message)
      self.connectAndWrite(sessionBox: sessionBox, tagBox: tagBox, messageBox: messageBox)
    }
  }

  nonisolated func readerSessionDidBecomeActive(_ session: NFCNDEFReaderSession) {
    // Session became active
  }

  nonisolated func readerSession(
    _ session: NFCNDEFReaderSession, didInvalidateWithError error: Error
  ) {
    let readerError = error as? NFCReaderError
    Task { @MainActor in
      if let readerError = readerError {
        switch readerError.code {
        case .readerSessionInvalidationErrorFirstNDEFTagRead,
          .readerSessionInvalidationErrorUserCanceled:
          // User canceled or first tag read
          break
        default:
          self.onError?(readerError.localizedDescription)
        }
      }
    }
  }

  // MARK: - NFC Write Operations (nonisolated - all work happens on CoreNFC's queue)

  nonisolated private func connectAndWrite(
    sessionBox: ScannerNDEFSessionBox, tagBox: ScannerNDEFTagBox, messageBox: ScannerNDEFMessageBox
  ) {
    sessionBox.connect(to: tagBox.tag) { error in
      if let error = error {
        sessionBox.invalidate(errorMessage: "Connection error: \(error.localizedDescription)")
        return
      }

      tagBox.queryNDEFStatus { status, capacity, error in
        guard error == nil else {
          sessionBox.invalidate(errorMessage: "Failed to query tag")
          return
        }

        switch status {
        case .notSupported:
          sessionBox.invalidate(errorMessage: "Tag is not NDEF compliant")
        case .readOnly:
          sessionBox.invalidate(errorMessage: "Tag is read-only")
        case .readWrite:
          self.writeMessage(messageBox, to: tagBox, sessionBox: sessionBox)
        @unknown default:
          sessionBox.invalidate(errorMessage: "Unknown tag status")
        }
      }
    }
  }

  nonisolated private func writeMessage(
    _ messageBox: ScannerNDEFMessageBox, to tagBox: ScannerNDEFTagBox, sessionBox: ScannerNDEFSessionBox
  ) {
    tagBox.writeNDEF(messageBox) { error in
      if let error = error {
        sessionBox.invalidate(errorMessage: "Write failed: \(error.localizedDescription)")
      } else {
        sessionBox.alertMessage = "Successfully wrote URL to tag"
        sessionBox.invalidate()
      }
    }
  }
}

extension Data {
  func hexEncodedString() -> String {
    return map { String(format: "%02hhX", $0) }.joined()
  }
}
