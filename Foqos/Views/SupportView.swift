import SwiftUI

let THREADS_URL = "https://www.threads.com/@softwarecuddler"
let TWITTER_URL = "https://x.com/softwarecuddler"

struct SupportView: View {
  @EnvironmentObject var themeManager: ThemeManager

  @State private var stampScale: CGFloat = 0.1
  @State private var stampRotation: Double = 0
  @State private var stampOpacity: Double = 0.0

  var body: some View {
    // Thank you stamp image and header
    VStack(alignment: .center, spacing: 30) {
      Spacer()

      Image("ThankYouStamp")
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(width: 300, height: 300)
        .scaleEffect(stampScale)
        .rotationEffect(.degrees(stampRotation))
        .opacity(stampOpacity)
        .onAppear {
          withAnimation(.spring(response: 0.4, dampingFraction: 0.6, blendDuration: 0)) {
            stampScale = 1
            stampRotation = 8
            stampOpacity = 1
          }
        }
        .padding(.bottom, 20)

      Text(
        "Thank you for your support! I created Family Foqos because I love the original Foqos app by @awaseem, but wanted to extend it to support family policies."
      )
      .font(.body)
      .multilineTextAlignment(.center)
      .foregroundColor(.secondary)
      .fadeInSlide(delay: 0.3)

      Text(
        "If you like it, please support Common Sense Media who provide valuable resources for families to make informed decisions about media and technology."
      )
      .font(.body)
      .multilineTextAlignment(.center)
      .foregroundColor(.secondary)
      .fadeInSlide(delay: 0.3)

      Spacer()

      ActionButton(
        title: "Donate to\nCommon Sense Media",
        backgroundColor: themeManager.themeColor,
        iconName: "heart.fill",
        action: {
          if let url = URL(string: "https://www.commonsensemedia.org/donate") {
            UIApplication.shared.open(url)
          }
        }
      )
      .fadeInSlide(delay: 0.6)
    }
    .padding(.horizontal, 20)
  }
}

#Preview {
  NavigationView {
    SupportView()
      .environmentObject(ThemeManager.shared)
  }
}
