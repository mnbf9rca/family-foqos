func report(participant: CKShare.Participant) {
  let a = participant.userIdentity.nameComponents?.formatted() ?? ""
  let b = participant.userIdentity.lookupInfo?.emailAddress ?? ""
  let c = !a.isEmpty ? a : b
  Log.debug("Participant \(c) status", category: .cloudKit)
}
