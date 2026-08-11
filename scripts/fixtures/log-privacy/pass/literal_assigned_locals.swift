func reportSummary() {
  let summary = "safe"
  Log.debug("Summary: \(summary)", category: .app)
}

func reportLabel() {
  let label: String = "ready"
  Log.debug("Label: \(label)", category: .app)
}

func reportAttempts() {
  let attempts = 42
  Log.debug("Attempts: \(attempts)", category: .app)
}

func reportApproval() {
  let approved = true
  Log.debug("Approved: \(approved)", category: .app)
}
