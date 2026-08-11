func report(p: CKShare.Participant) {
  Log.info("Name: \(p.userIdentity.nameComponents)", category: .cloudKit)
  Log.info("Email: \(p.userIdentity.lookupInfo?.emailAddress)", category: .cloudKit)
  Log.info("Phone: \(p.userIdentity.lookupInfo?.phoneNumber)", category: .cloudKit)
}
