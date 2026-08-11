func report(participant: CKShare.Participant) {
  let status = participant.userIdentity.lookupInfo?.emailAddress ?? "unknown"
  Log.debug("Participant status: \(status)", category: .cloudKit)
}
