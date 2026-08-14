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

  func testGivenVisibleTitleOrSubtitle_WhenResolvingRegistration_ThenReplacesIt() {
    let titled = CloudKitNetworkService.makeSharedDatabaseSubscription()
    titled.notificationInfo?.title = "Visible title"
    let subtitled = CloudKitNetworkService.makeSharedDatabaseSubscription()
    subtitled.notificationInfo?.subtitle = "Visible subtitle"

    XCTAssertEqual(
      CloudKitNetworkService.sharedDatabaseSubscriptionAction(existing: titled),
      .replace)
    XCTAssertEqual(
      CloudKitNetworkService.sharedDatabaseSubscriptionAction(existing: subtitled),
      .replace)
  }

  func testGivenSharedSubscription_WhenConfigured_ThenDeliveryIsSilent() {
    let subscription = CloudKitNetworkService.makeSharedDatabaseSubscription()

    XCTAssertEqual(
      subscription.subscriptionID,
      CloudKitNetworkService.sharedDatabaseSubscriptionID)
    XCTAssertEqual(subscription.notificationInfo?.shouldSendContentAvailable, true)
    XCTAssertNil(subscription.notificationInfo?.alertBody)
    XCTAssertNil(subscription.notificationInfo?.alertLocalizationKey)
    XCTAssertNil(subscription.notificationInfo?.alertLocalizationArgs)
    XCTAssertNil(subscription.notificationInfo?.title)
    XCTAssertNil(subscription.notificationInfo?.titleLocalizationKey)
    XCTAssertNil(subscription.notificationInfo?.titleLocalizationArgs)
    XCTAssertNil(subscription.notificationInfo?.subtitle)
    XCTAssertNil(subscription.notificationInfo?.subtitleLocalizationKey)
    XCTAssertNil(subscription.notificationInfo?.subtitleLocalizationArgs)
    XCTAssertNil(subscription.notificationInfo?.alertActionLocalizationKey)
    XCTAssertNil(subscription.notificationInfo?.alertLaunchImage)
    XCTAssertNil(subscription.notificationInfo?.soundName)
    XCTAssertNil(subscription.notificationInfo?.desiredKeys)
    XCTAssertEqual(subscription.notificationInfo?.shouldBadge, false)
    XCTAssertEqual(subscription.notificationInfo?.shouldSendMutableContent, false)
    XCTAssertNil(subscription.notificationInfo?.category)
    XCTAssertNil(subscription.notificationInfo?.collapseIDKey)
  }
}
