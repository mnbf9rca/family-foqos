func report(member: FamilyMember, error: Error, records: [CKRecord]) {
  Log.info(
    "member=\(member.redactedLogLabel) role=\(member.role.displayName) count=\(records.count)",
    category: .cloudKit
  )
  Log.error("failure=\(redactedErrorForLog(error))", category: .cloudKit)
  Log.error("localized=\(error.localizedDescription)", category: .cloudKit)
}
