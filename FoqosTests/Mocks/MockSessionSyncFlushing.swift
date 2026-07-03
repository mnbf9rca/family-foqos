import Foundation

@testable import FamilyFoqos

@MainActor
final class MockSessionSyncFlushing: SessionSyncFlushing {
  private(set) var flushCount = 0
  func flushSessionCache() async { flushCount += 1 }
}
