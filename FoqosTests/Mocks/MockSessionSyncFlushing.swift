import Foundation

@testable import FamilyFoqos

@MainActor
final class MockSessionSyncFlushing: SessionSyncFlushing {
  private(set) var flushCount = 0
  var beforeFlush: (() async -> Void)?

  func flushSessionCache() async {
    flushCount += 1
    await beforeFlush?()
  }
}
