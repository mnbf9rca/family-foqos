func report(participant: CKShare.Participant) {
  Log.info("Name: \(participant.userIdentity.nameComponents)", category: .cloudKit)
  Log.info("Email: \(participant.userIdentity.lookupInfo?.emailAddress)", category: .cloudKit)
  Log.info("Phone: \(participant.userIdentity.lookupInfo?.phoneNumber)", category: .cloudKit)
}
