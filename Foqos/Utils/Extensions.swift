import SwiftData
import SwiftUI

extension Collection {
  // Returns the element at the specified index if it is within bounds, otherwise nil.
  subscript(safe index: Index) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}

// MARK: - SwiftData Model Validation

extension Array where Element: PersistentModel {
  /// Filters out zombie SwiftData models — those whose `modelContext` has become nil or whose
  /// `isDeleted` flag is set after CloudKit sync. Accessing properties on such models causes
  /// `EXC_BREAKPOINT`. This defensive filter handles the timing window between deletion and
  /// SwiftUI re-render. Used by `@SafeQuery` internally and by views receiving plain arrays.
  var valid: [Element] {
    filter { $0.modelContext != nil && !$0.isDeleted }
  }
}
