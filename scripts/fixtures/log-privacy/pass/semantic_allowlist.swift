func report(recordName: String, zoneName: String, id: UUID, timestamp: Date) {
  Log.info(ShareParticipantLog.statusMessage(userRecordName: recordName, acceptanceStatus: 2))
  Log.info(
    "participant=\(ShareParticipantLog.label(userRecordName: recordName)) "
      + "record=\(recordName) zone=\(zoneName) id=\(id) timestamp=\(timestamp)",
    category: .cloudKit
  )
  Log.info(
    "tag=\(DebugRedaction.physicalUnblockNFCTagIdForLog(\"ABCDEF12\")) "
      + "url=\(redactedURLString)",
    category: .nfc
  )
}
