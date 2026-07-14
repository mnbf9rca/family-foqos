import Combine
import Foundation
import Network

@MainActor
final class NetworkReachabilityMonitor: ObservableObject {
  @Published private(set) var isOnline: Bool = true
  var onReconnect: (@MainActor () -> Void)?

  private var monitor: NWPathMonitor?
  private let queue = DispatchQueue(label: "com.cynexia.family-foqos.reachability")
  private var lastKnownSatisfied: Bool?

  #if DEBUG
    var isMonitoringForTest: Bool { monitor != nil }
  #endif

  func start() {
    guard monitor == nil else { return }
    let monitor = NWPathMonitor()
    self.monitor = monitor
    monitor.pathUpdateHandler = { [weak self] path in
      let isSatisfied = path.status == .satisfied
      Task { @MainActor in
        self?.handlePathUpdate(isSatisfied: isSatisfied)
      }
    }
    monitor.start(queue: queue)
  }

  func stop() {
    monitor?.cancel()
    monitor = nil
    lastKnownSatisfied = nil
  }

  func handlePathUpdate(isSatisfied: Bool) {
    let wasSatisfied = lastKnownSatisfied
    lastKnownSatisfied = isSatisfied
    isOnline = isSatisfied

    if wasSatisfied == false && isSatisfied {
      Log.info("Network reconnected; re-driving sync", category: .sync)
      onReconnect?()
    }
  }
}
