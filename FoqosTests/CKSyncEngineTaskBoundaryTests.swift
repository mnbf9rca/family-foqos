import XCTest

@testable import FamilyFoqos

@MainActor
final class CKSyncEngineTaskBoundaryTests: XCTestCase {
  @TaskLocal private static var isInsideDelegateCallback = false

  func testRunDetachedDoesNotInheritDelegateTaskLocal() async {
    let capture = TaskLocalCapture()

    let task = Self.$isInsideDelegateCallback.withValue(true) {
      CKSyncEngineTaskBoundary.runDetached {
        await capture.set(Self.isInsideDelegateCallback)
      }
    }

    await task.value

    let observed = await capture.value
    XCTAssertEqual(observed, false)
  }
}

private actor TaskLocalCapture {
  private var observedValue: Bool?

  var value: Bool? {
    observedValue
  }

  func set(_ value: Bool) {
    observedValue = value
  }
}
