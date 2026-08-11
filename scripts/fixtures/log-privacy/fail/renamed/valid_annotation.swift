func report(info: String) {
  // LOG-PRIVACY-SAFE: opaque server-generated participant state
  Log.debug("Participant: \(info)", category: .cloudKit)
}
