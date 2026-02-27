import XCTest

@testable import FamilyFoqos

@MainActor
final class StartStopActionResolverFactoryTests: XCTestCase {

  func testGivenSameStrategyId_WhenCalledTwice_ThenReturnsDifferentInstances() {
    let first = StartStopActionResolver.getStrategyFromId(id: ManualBlockingStrategy.id)
    let second = StartStopActionResolver.getStrategyFromId(id: ManualBlockingStrategy.id)

    // Cast to AnyObject for identity comparison since BlockingStrategy is a protocol existential
    let firstObj = first as AnyObject
    let secondObj = second as AnyObject
    XCTAssertTrue(
      firstObj !== secondObj,
      "getStrategyFromId should return a new instance each call, not a shared reference"
    )
  }

  func testGivenEveryKnownStrategyId_WhenCalled_ThenReturnsFreshInstanceWithCorrectId() {
    let expectedIds = [
      ManualBlockingStrategy.id,
      NFCBlockingStrategy.id,
      NFCManualBlockingStrategy.id,
      NFCTimerBlockingStrategy.id,
      QRCodeBlockingStrategy.id,
      QRManualBlockingStrategy.id,
      QRTimerBlockingStrategy.id,
      ShortcutTimerBlockingStrategy.id,
    ]

    for strategyId in expectedIds {
      let strategy = StartStopActionResolver.getStrategyFromId(id: strategyId)
      XCTAssertEqual(
        strategy.getIdentifier(), strategyId,
        "Factory should return a strategy matching the requested ID"
      )
    }
  }

  func testGivenUnknownStrategyId_WhenCalled_ThenReturnsFallback() {
    let strategy = StartStopActionResolver.getStrategyFromId(id: "NonexistentStrategy")

    XCTAssertEqual(
      strategy.getIdentifier(), NFCBlockingStrategy.id,
      "Unknown ID should fall back to NFCBlockingStrategy"
    )
  }
}
