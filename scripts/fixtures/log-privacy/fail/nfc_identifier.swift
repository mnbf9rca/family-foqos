func report(tagIdentifier: String) {
  Log.info("NFC tag: \(tagIdentifier)", category: .nfc)
}

func reportAttempt(attemptCount: Int) {
  Log.info("NFC tag attempt: \(attemptCount)", category: .nfc)
}
