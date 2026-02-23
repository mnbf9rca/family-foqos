import SwiftUI

struct EmptyStateView: View {
  let iconName: String
  let headingText: String

  var body: some View {
    VStack {
      Spacer()

      Image(systemName: iconName)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(width: 100, height: 100)
        .foregroundColor(.gray)

      Text(headingText)
        .font(.headline)
        .multilineTextAlignment(.center)
        .foregroundColor(.secondary)
        .padding()

      Spacer()
    }
  }
}

#Preview {
  EmptyStateView(iconName: "tray", headingText: "No items in your list")
}
