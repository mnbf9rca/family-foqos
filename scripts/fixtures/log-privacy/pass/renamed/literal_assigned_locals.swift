func reportDetail() {
  let detail = "safe"
  Log.debug("Summary: \(detail)", category: .app)
}

func reportTitle() {
  let title: String = "ready"
  Log.debug("Label: \(title)", category: .app)
}

func reportCount() {
  let count = 42
  Log.debug("Attempts: \(count)", category: .app)
}

func reportEnabled() {
  let enabled = true
  Log.debug("Approved: \(enabled)", category: .app)
}
