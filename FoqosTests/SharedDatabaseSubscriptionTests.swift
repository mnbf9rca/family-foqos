import CloudKit
import XCTest

@testable import FamilyFoqos

@MainActor
final class SharedDatabaseSubscriptionTests: XCTestCase {
  func testGivenMissingSubscription_WhenResolvingRegistration_ThenCreatesIt() {
    XCTAssertEqual(
      CloudKitNetworkService.sharedDatabaseSubscriptionAction(existing: nil),
      .create)
  }

  func testGivenCurrentSubscription_WhenResolvingRegistration_ThenKeepsIt() {
    let subscription = CloudKitNetworkService.makeSharedDatabaseSubscription()

    XCTAssertEqual(
      CloudKitNetworkService.sharedDatabaseSubscriptionAction(existing: subscription),
      .keep)
  }

  func testGivenStaleSubscription_WhenResolvingRegistration_ThenReplacesIt() {
    let subscription = CKDatabaseSubscription(
      subscriptionID: CloudKitNetworkService.sharedDatabaseSubscriptionID)

    XCTAssertEqual(
      CloudKitNetworkService.sharedDatabaseSubscriptionAction(existing: subscription),
      .replace)
  }

  func testGivenSharedSubscription_WhenConfigured_ThenDeliveryIsSilent() {
    let subscription = CloudKitNetworkService.makeSharedDatabaseSubscription()

    XCTAssertEqual(
      subscription.subscriptionID,
      CloudKitNetworkService.sharedDatabaseSubscriptionID)
    XCTAssertEqual(subscription.notificationInfo?.shouldSendContentAvailable, true)
    XCTAssertNil(subscription.notificationInfo?.alertBody)
    XCTAssertNil(subscription.notificationInfo?.soundName)
    XCTAssertEqual(subscription.notificationInfo?.shouldBadge, false)
  }
}
