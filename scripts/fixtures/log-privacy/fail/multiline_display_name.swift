func report(member: FamilyMember) {
  Log.info(
    "Member: \(member.displayName)",
    category: .cloudKit
  )
}

func reportMisleadingReceiver(mode: FamilyMember) {
  Log.info("Member: \(mode.displayName)", category: .cloudKit)
}

func reportMisleadingRole(role: FamilyMember) {
  Log.info("Member: \(role.displayName)", category: .cloudKit)
}
