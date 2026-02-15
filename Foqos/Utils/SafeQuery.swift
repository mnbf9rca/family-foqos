@preconcurrency import SwiftData  // ReferenceWritableKeyPath in @Query lacks Sendable conformance
import SwiftUI

/// A property wrapper that embeds @Query and auto-filters SwiftData zombie models.
/// Use this instead of @Query in all views — it prevents crashes from models deleted
/// via CloudKit sync whose modelContext has become nil.
@MainActor
@propertyWrapper
struct SafeQuery<Element: PersistentModel>: DynamicProperty {
  @Query private var elements: [Element]

  var wrappedValue: [Element] {
    elements.filter { $0.modelContext != nil && !$0.isDeleted }
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
}
