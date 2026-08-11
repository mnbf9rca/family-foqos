func report(error: Error) {
  Log.error("Failure: \(error)", category: .sync)
}
