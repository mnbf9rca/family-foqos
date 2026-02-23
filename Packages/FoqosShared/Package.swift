// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "FoqosShared",
  platforms: [.iOS(.v17)],
  products: [
    .library(name: "FoqosShared", targets: ["FoqosShared"])
  ],
  targets: [
    .target(name: "FoqosShared")
  ]
)
