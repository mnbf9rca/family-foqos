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
  /// Filters out models that have been deleted from SwiftData but not yet removed from @Query.
  /// When a SwiftData model is deleted, its `modelContext` becomes nil. Accessing properties
  /// on such models causes a crash. This defensive filter handles the timing window between
  /// SwiftData deletion and SwiftUI re-render.
  var valid: [Element] {
    filter { $0.modelContext != nil }
  }
}
