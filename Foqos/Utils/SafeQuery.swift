@preconcurrency import SwiftData  // ReferenceWritableKeyPath in @Query lacks Sendable conformance
import SwiftUI

/// A property wrapper that embeds @Query and auto-filters SwiftData zombie models.
/// Use this instead of @Query in all views — it prevents crashes from models whose
/// `modelContext` has become nil or whose `isDeleted` flag is set after CloudKit sync.
///
/// Note: `animation:` and `transaction:` parameters are intentionally omitted — no call
/// site uses them. Add overloads here if needed in the future.
@MainActor
@propertyWrapper
struct SafeQuery<Element: PersistentModel>: DynamicProperty {
  @Query private var elements: [Element]

  var wrappedValue: [Element] {
    elements.valid
  }

  init() {
    _elements = Query()
  }

  init(sort descriptors: [SortDescriptor<Element>]) {
    _elements = Query(sort: descriptors)
  }

  init<Value: Comparable>(
    sort keyPath: KeyPath<Element, Value>,
    order: SortOrder = .forward
  ) {
    _elements = Query(sort: keyPath, order: order)
  }

  init(
    filter: Predicate<Element>?,
    sort descriptors: [SortDescriptor<Element>] = []
  ) {
    _elements = Query(filter: filter, sort: descriptors)
  }

  init<Value: Comparable>(
    filter: Predicate<Element>?,
    sort keyPath: KeyPath<Element, Value>,
    order: SortOrder = .forward
  ) {
    _elements = Query(filter: filter, sort: keyPath, order: order)
  }

  // Optional-value keypath overloads (e.g. sort: \Model.endTime where endTime is Date?)
  init<Value: Comparable>(
    sort keyPath: KeyPath<Element, Value?>,
    order: SortOrder = .forward
  ) {
    _elements = Query(sort: keyPath, order: order)
  }

  init<Value: Comparable>(
    filter: Predicate<Element>?,
    sort keyPath: KeyPath<Element, Value?>,
    order: SortOrder = .forward
  ) {
    _elements = Query(filter: filter, sort: keyPath, order: order)
  }
}
