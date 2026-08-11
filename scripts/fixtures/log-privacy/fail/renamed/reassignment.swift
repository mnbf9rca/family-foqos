// swift-format-ignore-file
func report(p: CKShare.Participant) {
  var a = "safe"; a = p.userIdentity.lookupInfo?.emailAddress ?? ""
  Log.debug("Participant: \(a)", category: .cloudKit)

  var b = "safe"
  b = p.userIdentity.lookupInfo?.phoneNumber ?? ""
  Log.debug("Participant: \(b)", category: .cloudKit)
}
