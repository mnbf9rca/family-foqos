#Preview("Primary") {
  Button("Select") {
    Log.debug("Selected preview mode", category: .ui)
  }
}

#Preview("Scanner") {
  Scanner(
    onSuccess: { Log.debug("Preview scanned code", category: .ui) },
    onFailure: { _ in Log.debug("Preview scanning failed", category: .ui) }
  )
}

#Preview("Locations") {
  MapPicker { _ in
    Log.debug("Selected preview location", category: .ui)
    Log.debug("Selected alternate preview location", category: .ui)
  }
}
