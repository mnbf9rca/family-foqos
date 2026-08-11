func report(m: FamilyMember) {
  Log.info(
    "Member: \(m.displayName)",
    category: .cloudKit
  )
}

func reportMisleadingReceiver(currentMode: FamilyMember) {
  Log.info("Member: \(currentMode.displayName)", category: .cloudKit)
}

func reportMisleadingRole(r: FamilyMember) {
  Log.info("Member: \(r.displayName)", category: .cloudKit)
}
