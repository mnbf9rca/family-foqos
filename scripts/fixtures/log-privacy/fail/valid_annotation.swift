func report(displayInfo: String) {
  // LOG-PRIVACY-SAFE: opaque server-generated participant state
  Log.debug("Participant: \(displayInfo)", category: .cloudKit)
}
