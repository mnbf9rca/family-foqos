func report(
  mode: AppMode,
  currentMode: AppMode,
  role: FamilyRole,
  ruleType: GeofenceRuleType,
  member: AppMode,
  participant: AppMode
) {
  Log.info("mode=\(mode.displayName)", category: .app)
  Log.info("current_mode=\(currentMode.displayName)", category: .app)
  Log.info("role=\(role.displayName)", category: .app)
  Log.info("rule_type=\(ruleType.displayName)", category: .app)
  Log.info("member_named_mode=\(member.displayName)", category: .app)
  Log.info("participant_named_mode=\(participant.displayName)", category: .app)
}
