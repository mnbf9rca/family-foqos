import Combine
import Foundation
import SwiftData
import UIKit

enum AppModelStore {
  static var schema: Schema {
    Schema([BlockedProfileSession.self, BlockedProfiles.self, SavedLocation.self, SavedTag.self])
  }

  static var configuration: ModelConfiguration {
    ModelConfiguration(
      schema: schema,
      isStoredInMemoryOnly: ScreenshotDemoMode.isActive,
      cloudKitDatabase: .none)
  }

  static var storeURL: URL {
    configuration.url
  }

  static func makeConfiguration(url: URL) -> ModelConfiguration {
    ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
  }

  static func makeContainer() throws -> ModelContainer {
    let schema = schema
    return try ModelContainer(for: schema, configurations: [configuration])
  }
}

/// Serializes startup for the UI and App Intents, including a launch without a scene.
@MainActor
final class ProtectedStoreLaunch: ObservableObject {
  enum State {
    case waitingForUnlock
    case failed
    case ready(ModelContainer, StartupRecoveryLocalSnapshot)
  }

  enum Unavailable: LocalizedError {
    case waitingForUnlock
    case openFailed

    var errorDescription: String? {
      switch self {
      case .waitingForUnlock: "Unlock your device to use Family Foqos."
      case .openFailed: "Family Foqos couldn't open its data. Open the app and try again."
      }
    }
  }

  static let shared: ProtectedStoreLaunch = {
    #if DEBUG && targetEnvironment(simulator)
      if let uiTestFixture {
        return uiTestFixture.makeLaunch()
      }
    #endif
    return ProtectedStoreLaunch(
      isProtectedDataAvailable: { UIApplication.shared.isProtectedDataAvailable },
      probeStore: { StartupRecoveryLocalState.readStore(at: AppModelStore.storeURL) },
      capture: StartupRecoveryLocalState.capture,
      open: AppModelStore.makeContainer,
      prepare: { prepareAppForOpenedStore($0) })
  }()

  #if DEBUG && targetEnvironment(simulator)
    static let uiTestFixture = ProtectedStoreLaunchUITestFixture()
  #endif

  @Published private(set) var state = State.waitingForUnlock

  private let isProtectedDataAvailable: () -> Bool
  private let probeStore: () -> StartupRecoveryStoreFinding
  private let capture: () -> StartupRecoveryLocalSnapshot
  private let open: () throws -> ModelContainer
  private let prepare: (ModelContainer) -> Void
  private var observation: AnyCancellable?
  private var snapshot: StartupRecoveryLocalSnapshot?
  private var isOpening = false
  private var pendingActions: [() -> Void] = []

  init(
    isProtectedDataAvailable: @escaping () -> Bool,
    probeStore: @escaping () -> StartupRecoveryStoreFinding,
    capture: @escaping () -> StartupRecoveryLocalSnapshot,
    open: @escaping () throws -> ModelContainer,
    prepare: @escaping (ModelContainer) -> Void = { _ in }
  ) {
    self.isProtectedDataAvailable = isProtectedDataAvailable
    self.probeStore = probeStore
    self.capture = capture
    self.open = open
    self.prepare = prepare
  }

  var isReady: Bool {
    if case .ready = state { return true }
    return false
  }

  func startObserving(center: NotificationCenter = .default) {
    guard observation == nil else { return }
    observation = center.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)
      .merge(with: center.publisher(for: UIApplication.willEnterForegroundNotification))
      .sink { @Sendable [weak self] _ in
        Task { @MainActor in self?.refresh() }
      }
  }

  func refresh() {
    guard !isReady, !isOpening, isProtectedDataAvailable() || hasReadableStore() else { return }
    isOpening = true
    defer { isOpening = false }

    let evidence = snapshot ?? capture()
    snapshot = evidence
    do {
      let container = try open()
      prepare(container)
      state = .ready(container, evidence)
      let actions = pendingActions
      pendingActions.removeAll()
      for action in actions { action() }
    } catch {
      Log.error("Model store open failed: \(redactedErrorForLog(error))", category: .app)
      state = .failed
    }
  }

  func readyContainer() throws -> ModelContainer {
    refresh()
    switch state {
    case .ready(let container, _): return container
    case .waitingForUnlock: throw Unavailable.waitingForUnlock
    case .failed: throw Unavailable.openFailed
    }
  }

  func afterOpen(_ action: @escaping () -> Void) {
    if isReady {
      action()
    } else {
      pendingActions.append(action)
    }
  }

  private func hasReadableStore() -> Bool {
    switch probeStore() {
    case .tableMissing, .profileCount: return true
    case .storeAbsent, .readFailed: return false
    }
  }
}

#if DEBUG && targetEnvironment(simulator)
  @MainActor
  final class ProtectedStoreLaunchUITestFixture {
    private enum Mode: String { case seed, locked, fail }
    private enum FixtureError: Error { case openFailed }

    private let mode: Mode
    private let storeURL: URL
    private var unlocked: Bool
    private var shouldFail: Bool

    init?() {
      let environment = ProcessInfo.processInfo.environment
      guard let identifier = environment["FOQOS_PROTECTED_LAUNCH_TEST_STORE"],
        let id = UUID(uuidString: identifier),
        let modeValue = environment["FOQOS_PROTECTED_LAUNCH_TEST_MODE"],
        let mode = Mode(rawValue: modeValue)
      else { return nil }

      self.mode = mode
      storeURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("ProtectedStoreLaunch-\(id.uuidString).store")
      unlocked = mode != .locked
      shouldFail = mode == .fail
    }

    func makeLaunch() -> ProtectedStoreLaunch {
      ProtectedStoreLaunch(
        isProtectedDataAvailable: { self.unlocked },
        probeStore: {
          self.unlocked ? StartupRecoveryLocalState.readStore(at: self.storeURL) : .readFailed
        },
        capture: {
          StartupRecoveryLocalSnapshot(
            onboardingValuePresent: true,
            appGroupStatePresent: false,
            store: StartupRecoveryLocalState.readStore(at: self.storeURL))
        },
        open: { try self.openFixture() },
        prepare: { prepareAppForOpenedStore($0) })
    }

    func unlock() {
      unlocked = true
      NotificationCenter.default.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
    }

    func allowRetry() { shouldFail = false }

    private func openFixture() throws -> ModelContainer {
      guard !shouldFail else { throw FixtureError.openFailed }
      let container = try ModelContainer(
        for: AppModelStore.schema,
        configurations: [AppModelStore.makeConfiguration(url: storeURL)])
      if mode == .seed {
        container.mainContext.insert(BlockedProfiles(name: "Stored before reboot"))
        try container.mainContext.save()
      }
      return container
    }
  }
#endif
