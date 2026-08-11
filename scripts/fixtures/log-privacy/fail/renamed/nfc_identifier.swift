func report(value: String) {
  Log.info("NFC tag: \(value)", category: .nfc)
}

func reportAttempt(retries: Int) {
  Log.info("NFC tag attempt: \(retries)", category: .nfc)
}
