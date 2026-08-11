// Log.error("commented failure: \(error)", category: .sync)
/*
  Log.error("block-comment failure: \(error)", category: .sync)
  /* Log.info("nested comment: \(member.displayName)", category: .cloudKit) */
*/
let fakeLog = #"Log.error("raw string failure: \(error)", category: .sync)"#
let unicodeFakeLog = "🔐 Log.error(\"unicode string failure: \(error)\", category: .sync)"
let multilineFakeLog = """
  Log.error("multiline string failure: \(error)", category: .sync)
  """

Log.info("escaped quote: \"safe\"", category: .app)
Log.info(#"record=\#(recordName)"#, category: .cloudKit)
