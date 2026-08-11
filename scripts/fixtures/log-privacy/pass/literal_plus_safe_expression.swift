func report(error: Error) {
  Log.warning(
    "Operation failed: "
      + error.localizedDescription,
    category: .sync
  )
}
