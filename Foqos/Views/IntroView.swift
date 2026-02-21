import SwiftUI

struct IntroView: View {
  let onRequestAuthorization: () -> Void

  var body: some View {
    AnimatedIntroContainer(
      onRequestAuthorization: onRequestAuthorization
    )
  }
}

#Preview {
  IntroView {
    Log.debug("Request authorization tapped", category: .ui)
  }
}
