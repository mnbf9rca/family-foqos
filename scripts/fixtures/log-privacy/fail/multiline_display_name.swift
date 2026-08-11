func report(member: FamilyMember) {
  Log.info(
    "Member: \(member.displayName)",
    category: .cloudKit
  )
}
