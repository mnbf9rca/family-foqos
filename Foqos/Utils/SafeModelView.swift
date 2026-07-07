import SwiftData
import SwiftUI

/// A generic view that validates a `PersistentModel` is still alive before rendering.
///
/// This is the third layer of defense against zombie SwiftData models:
/// 1. `@SafeQuery` filters zombies from query results
/// 2. `.valid` filters zombies from arrays
/// 3. `SafeModelView` guards at render time — catching the race between filtering and rendering
///
/// Usage:
/// ```swift
/// ForEach(profiles) { profile in
///   SafeModelView(profile) { p in
///     ProfileCard(profile: p)
///   }
/// }
/// ```
struct SafeModelView<Model: PersistentModel, Content: View>: View {
  let model: Model
  let content: (Model) -> Content

  init(_ model: Model, @ViewBuilder content: @escaping (Model) -> Content) {
    self.model = model
    self.content = content
  }

  var body: some View {
    let state = model.debugPersistentModelStateFor285
    let _ = Log.debug("[#285 PROBE] SafeModelView.body evaluate \(state)", category: .ui)
    if model.isPersistentModelValid {
      let _ = Log.debug("[#285 PROBE] SafeModelView.body allow content \(state)", category: .ui)
      content(model)
    } else {
      let _ = Log.debug("[#285 PROBE] SafeModelView.body suppress content \(state)", category: .ui)
      EmptyView()
    }
  }
}
