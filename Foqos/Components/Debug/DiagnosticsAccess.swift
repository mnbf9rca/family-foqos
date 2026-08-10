import Foundation

enum DiagnosticsAccess {
  static func isRestricted(mode: AppMode) -> Bool {
    mode == .child
  }
}
