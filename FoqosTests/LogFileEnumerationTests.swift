import XCTest

@testable import FamilyFoqos

final class LogFileEnumerationTests: XCTestCase {
  func testGivenMainAppBundleId_WhenLogBaseName_ThenApp() {
    XCTAssertEqual(Log.logBaseName(forBundleIdentifier: "com.cynexia.family-foqos"), "app")
  }

  func testGivenMonitorBundleId_WhenLogBaseName_ThenMonitor() {
    XCTAssertEqual(
      Log.logBaseName(forBundleIdentifier: "com.cynexia.family-foqos.FoqosDeviceMonitor"),
      "monitor"
    )
  }

  func testGivenWidgetBundleId_WhenLogBaseName_ThenWidget() {
    XCTAssertEqual(
      Log.logBaseName(forBundleIdentifier: "com.cynexia.family-foqos.FoqosWidget"),
      "widget"
    )
  }

  func testGivenShieldBundleId_WhenLogBaseName_ThenShield() {
    XCTAssertEqual(
      Log.logBaseName(forBundleIdentifier: "com.cynexia.family-foqos.FoqosShieldConfig"),
      "shield"
    )
  }

  func testGivenUnknownBundleId_WhenLogBaseName_ThenSanitizedAndDistinct() {
    let tag = Log.logBaseName(forBundleIdentifier: "com.cynexia.family-FoqosTests")

    XCTAssertNotEqual(tag, "app")
    XCTAssertFalse(tag.contains("."))
    XCTAssertEqual(tag, "com-cynexia-family-foqostests")
  }

  func testGivenNilBundleId_WhenLogBaseName_ThenApp() {
    XCTAssertEqual(Log.logBaseName(forBundleIdentifier: nil), "app")
  }

  func testGivenMultiProcessFiles_WhenEnumerating_ThenAllIncludedLegacyExcluded() throws {
    let fileManager = FileManager.default
    let dir = fileManager.temporaryDirectory.appendingPathComponent("LogEnum-\(UUID().uuidString)")
    try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: dir) }

    let expected = ["foqos-app.log", "foqos-monitor.log", "foqos-monitor.1.log"]
    for name in expected {
      try "x".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    try "x".write(to: dir.appendingPathComponent("foqos.log"), atomically: true, encoding: .utf8)
    try "x".write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

    let names = Set(
      Log.allLogFileURLs(inDirectory: dir, using: fileManager).map(\.lastPathComponent))
    XCTAssertEqual(names, Set(expected))
  }

  func testGivenTwoProcessCurrentFiles_WhenStagingName_ThenDistinct() {
    let app = URL(fileURLWithPath: "/tmp/foqos-app.log")
    let monitor = URL(fileURLWithPath: "/tmp/foqos-monitor.log")

    XCTAssertEqual(Log.stagingDestinationName(for: app), "foqos-app.log")
    XCTAssertNotEqual(Log.stagingDestinationName(for: app), Log.stagingDestinationName(for: monitor))
  }
}
