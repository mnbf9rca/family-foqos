func report(coordinate: CLLocationCoordinate2D) {
  Log.debug("Coordinate: \(coordinate)", category: .location)
  Log.debug("Latitude: \(coordinate.latitude)", category: .location)
  Log.debug("Longitude: \(coordinate.longitude)", category: .location)
}
