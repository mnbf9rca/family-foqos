func report(participant: CKShare.Participant) {
  let summary = participant.userIdentity.lookupInfo?.emailAddress ?? "unknown"
  Log.debug("Participant status: \(summary)", category: .cloudKit)
}
