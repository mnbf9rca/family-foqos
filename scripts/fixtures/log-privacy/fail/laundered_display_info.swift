func report(participant: CKShare.Participant) {
  let displayInfo =
    participant.userIdentity.nameComponents?.givenName
    ?? participant.userIdentity.lookupInfo?.emailAddress
    ?? "unknown"
  Log.debug("Participant: \(displayInfo)", category: .cloudKit)
}
