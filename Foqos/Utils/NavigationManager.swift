import SwiftData
import SwiftUI

@MainActor
class NavigationManager: ObservableObject {
  static let shared = NavigationManager()

  @Published private(set) var deliveries: [ProfileTagLink.Delivery] = []
  @Published var deliveryError: String?
  @Published var navigateToProfileId: String?
  private(set) var sceneOwnsCommands = false
  private let consumedActivities = NSHashTable<NSUserActivity>.weakObjects()

  func registerSceneOwnership() { sceneOwnsCommands = true }

  func receiveSwiftUI(_ url: URL) {
    guard !sceneOwnsCommands else { return }
    handleLink(url)
  }

  func receiveSwiftUI(_ activity: NSUserActivity) {
    guard !sceneOwnsCommands else { return }
    handleActivity(activity)
  }

  func handleActivity(_ activity: NSUserActivity) {
    guard !consumedActivities.contains(activity) else { return }
    consumedActivities.add(activity)
    do { deliveries.append(try ProfileTagLink.classify(activity)) } catch { deliveryError = error.localizedDescription }
  }

  func handleLink(_ url: URL) {
    if let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
      c.scheme?.lowercased() == "https", c.host?.lowercased() == "family-foqos.app",
      c.user == nil, c.password == nil, c.port == nil
    {
      let parts = c.path.split(separator: "/", omittingEmptySubsequences: false)
      if parts.count == 3, parts[0].isEmpty, parts[1] == "navigate",
        let id = UUID(uuidString: String(parts[2]))
      {
        navigateToProfileId = id.uuidString
        return
      }
    }
    do { deliveries.append(try ProfileTagLink.classify(url)) } catch { deliveryError = error.localizedDescription }
  }

  func takeDelivery() -> ProfileTagLink.Delivery? {
    deliveries.isEmpty ? nil : deliveries.removeFirst()
  }

  private var dispatching = false
  func dispatchQueued(using manager: StrategyManager, context: ModelContext, ready: Bool, now: Date = Date()) async {
    guard ready, !dispatching else { return }
    dispatching = true
    defer { dispatching = false }
    while let delivery = takeDelivery() {
      await manager.handleDelivery(delivery, context: context, now: now)
    }
  }

  func clearNavigation() { navigateToProfileId = nil }
}
