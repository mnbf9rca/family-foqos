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
    if activity.activityType == NSUserActivityTypeBrowsingWeb, let url = activity.webpageURL,
      handleNonCommandURL(url)
    {
      return
    }
    do { deliveries.append(try ProfileTagLink.classify(activity)) } catch { deliveryError = error.localizedDescription }
  }

  func handleLink(_ url: URL) {
    guard !handleNonCommandURL(url) else { return }
    do { deliveries.append(try ProfileTagLink.classify(url)) } catch { deliveryError = error.localizedDescription }
  }

  private func handleNonCommandURL(_ url: URL) -> Bool {
    guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
      c.host?.lowercased() == "family-foqos.app"
    else { return true }
    if c.scheme?.lowercased() == "https",
      c.user == nil, c.password == nil, c.port == nil
    {
      let parts = c.path.split(separator: "/", omittingEmptySubsequences: false)
      if parts.count == 3, parts[0].isEmpty, parts[1] == "navigate",
        let id = UUID(uuidString: String(parts[2]))
      {
        navigateToProfileId = id.uuidString
        return true
      }
    }
    return c.path != "/profile" && !c.path.hasPrefix("/profile/")
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
