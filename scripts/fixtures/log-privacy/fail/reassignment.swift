// swift-format-ignore-file
func report(participant: CKShare.Participant) {
  var summary = "safe"; summary = participant.userIdentity.lookupInfo?.emailAddress ?? ""
  Log.debug("Participant: \(summary)", category: .cloudKit)

  var detail = "safe"
  detail = participant.userIdentity.lookupInfo?.phoneNumber ?? ""
  Log.debug("Participant: \(detail)", category: .cloudKit)
}
