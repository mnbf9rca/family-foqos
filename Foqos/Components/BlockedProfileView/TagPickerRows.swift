import SwiftUI

struct TagPickerRows: View {
  @Binding var selectedIds: [String]
  let tags: [(id: String, name: String)]
  let scanLabel: String
  let disabled: Bool
  let onChange: () -> Void
  let onScan: () -> Void

  private var rows: [(id: String, name: String)] {
    let known = Set(tags.map(\.id))
    return tags + selectedIds.filter { !known.contains($0) }.map { ($0, "Removed tag") }
  }

  var body: some View {
    ForEach(rows, id: \.id) { row in
      Button {
        if selectedIds.contains(row.id) { selectedIds.removeAll { $0 == row.id } } else { selectedIds.append(row.id) }
        onChange()
      } label: {
        HStack {
          Image(systemName: selectedIds.contains(row.id) ? "checkmark.circle.fill" : "circle")
          Text(row.name)
        }
      }
      .accessibilityValue(selectedIds.contains(row.id) ? "Selected" : "Not selected")
      .disabled(disabled)
    }
    Button(action: onScan) { Label(scanLabel, systemImage: "plus") }
      .disabled(disabled)
  }
}
