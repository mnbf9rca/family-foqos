func report(m: FamilyMember) {
  Log.info(
    "Member: \(m.displayName)",
    category: .cloudKit
  )
}
