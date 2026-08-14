import CloudKit

extension CloudKitNetworkService {
  static let sharedDatabaseSubscriptionID = "family-foqos-shared-database-v1"

  enum SharedDatabaseSubscriptionAction: Equatable {
    case keep
    case create
    case replace
  }

  private enum SharedDatabaseSubscriptionError: Error {
    case missingSaveResult
  }

  static func makeSharedDatabaseSubscription() -> CKDatabaseSubscription {
    let subscription = CKDatabaseSubscription(subscriptionID: sharedDatabaseSubscriptionID)
    let notificationInfo = CKSubscription.NotificationInfo()
    notificationInfo.shouldSendContentAvailable = true
    subscription.notificationInfo = notificationInfo
    return subscription
  }

  static func sharedDatabaseSubscriptionAction(
    existing: CKSubscription?
  ) -> SharedDatabaseSubscriptionAction {
    guard let existing else { return .create }
    guard let databaseSubscription = existing as? CKDatabaseSubscription,
      databaseSubscription.subscriptionID == sharedDatabaseSubscriptionID,
      let notificationInfo = databaseSubscription.notificationInfo,
      notificationInfo.shouldSendContentAvailable,
      notificationInfo.alertBody == nil,
      notificationInfo.alertLocalizationKey == nil,
      notificationInfo.soundName == nil,
      !notificationInfo.shouldBadge
    else {
      return .replace
    }
    return .keep
  }

  /// Establishes the one shared-database subscription owned by the child data path.
  /// The stable ID makes repeated startup/foreground repair calls idempotent.
  func ensureSharedDatabaseSubscription() async throws {
    let database = sharedDatabase
    let existing: CKSubscription?
    do {
      existing = try await database.subscription(for: Self.sharedDatabaseSubscriptionID)
    } catch let error as CKError where error.code == .unknownItem {
      existing = nil
    }

    switch Self.sharedDatabaseSubscriptionAction(existing: existing) {
    case .keep:
      return
    case .replace:
      do {
        try await database.deleteSubscription(withID: Self.sharedDatabaseSubscriptionID)
      } catch let error as CKError where error.code == .unknownItem {
        // The subscription disappeared between fetch and repair; continue with creation.
      }
    case .create:
      break
    }

    let subscription = Self.makeSharedDatabaseSubscription()
    let results = try await database.modifySubscriptions(
      saving: [subscription],
      deleting: [])
    guard let saveResult = results.saveResults[Self.sharedDatabaseSubscriptionID] else {
      throw SharedDatabaseSubscriptionError.missingSaveResult
    }
    _ = try saveResult.get()
    Log.info("Shared database subscription established", category: .cloudKit)
  }
}
