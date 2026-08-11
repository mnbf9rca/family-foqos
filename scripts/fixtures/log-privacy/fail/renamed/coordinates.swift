func report(c: CLLocationCoordinate2D) {
  Log.debug("Coordinate: \(c)", category: .location)
  Log.debug("Latitude: \(c.latitude)", category: .location)
  Log.debug("Longitude: \(c.longitude)", category: .location)
}
