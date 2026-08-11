func report(p: CKShare.Participant) {
  let label =
    p.userIdentity.nameComponents?.givenName
    ?? p.userIdentity.lookupInfo?.emailAddress
    ?? "unknown"
  Log.debug("Participant: \(label)", category: .cloudKit)
}
