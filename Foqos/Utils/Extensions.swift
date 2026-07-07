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
  /// Filters out zombie SwiftData models across both deletion windows (see
  /// `PersistentModel.isPersistentModelValid`). Used by `@SafeQuery` internally and by
  /// views receiving plain arrays.
  var valid: [Element] {
    filter { $0.isPersistentModelValid }
  }
}

extension PersistentModel {
  /// Single source of truth for "is this SwiftData model safe to read stored attributes from?"
  ///
  /// Rejects zombie models across BOTH deletion windows:
  ///  - Pre-save (`context.delete` without save): `isDeleted == true`.
  ///  - Post-save (`context.delete` + `context.save`): SwiftData resets `isDeleted` to `false`
  ///    and leaves `modelContext` non-nil, but the store row is gone — reading any stored
  ///    attribute traps with `EXC_BREAKPOINT`. The context de-registers the id on save, so
  ///    `registeredModel(for:)` returns nil. Reading `modelContext`, `isDeleted`, and
  ///    `persistentModelID` is metadata-only and does not fault the vacated row.
  var isPersistentModelValid: Bool {
    guard let context = modelContext, !isDeleted else { return false }
    let registered: Self? = context.registeredModel(for: persistentModelID)
    return registered != nil
  }
}
