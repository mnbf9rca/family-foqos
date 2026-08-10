import Foundation
import os

/// Scenario staged by one demo-mode app launch (one launch = one screenshot scene).
enum ScreenshotDemoScenario: String {
  case homeActive = "home-active"
  case profileEditor = "profile-editor"
  case parentDashboard = "parent-dashboard"
}

/// Screenshot demo mode: active ONLY when launched with `--screenshot-demo`
/// (fastlane snapshot UI tests). Compiled to a constant `false` outside DEBUG,
/// so no demo path exists in the App Store binary.
enum ScreenshotDemoMode {
  #if DEBUG
    /// Test-only escape hatch so unit tests can exercise demo-gated code paths.
    private static let overrideStorage = OSAllocatedUnfairLock(initialState: Bool?.none)

    /// Test-only escape hatch so unit tests can stage a scenario without launch arguments.
    private static let scenarioOverrideStorage =
      OSAllocatedUnfairLock(initialState: ScreenshotDemoScenario?.none)

    static var overrideForTesting: Bool? {
      get { overrideStorage.withLock { $0 } }
      set { overrideStorage.withLock { $0 = newValue } }
    }

    static var scenarioOverrideForTesting: ScreenshotDemoScenario? {
      get { scenarioOverrideStorage.withLock { $0 } }
      set { scenarioOverrideStorage.withLock { $0 = newValue } }
    }

    static var isActive: Bool {
      if let overrideForTesting { return overrideForTesting }
      return ProcessInfo.processInfo.arguments.contains("--screenshot-demo")
    }

    static var scenario: ScreenshotDemoScenario? {
      guard isActive else { return nil }
      if let scenarioOverrideForTesting { return scenarioOverrideForTesting }
      let args = ProcessInfo.processInfo.arguments
      guard let flagIndex = args.firstIndex(of: "--demo-scenario"),
        args.indices.contains(flagIndex + 1)
      else { return nil }
      return ScreenshotDemoScenario(rawValue: args[flagIndex + 1])
    }
  #else
    static let isActive = false
    static let scenario: ScreenshotDemoScenario? = nil
  #endif
}
