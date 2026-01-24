import SwiftUI

struct ModeSelectionView: View {
    @EnvironmentObject var requestAuthorizer: RequestAuthorizer
    @ObservedObject private var appModeManager = AppModeManager.shared

    @State private var selectedMode: AppMode = .individual
    @State private var isAuthorizing = false
    @State private var showError = false
    @State private var errorMessage = ""

    let onModeSelected: (AppMode) -> Void

    /// Only show individual and child modes in the selection UI
    /// Parent mode can be activated later from Settings > Family Controls Dashboard
    private let availableModes: [AppMode] = [.individual, .child]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 12) {
                Image(systemName: "person.2.circle.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.primary.opacity(0.8))

                Text("How will you use Family Foqos?")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("Choose your role to get started")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 60)
            .padding(.bottom, 40)

            // Mode cards - only show individual and child options
            VStack(spacing: 16) {
                ForEach(availableModes, id: \.self) { mode in
                    SimplifiedModeCard(
                        mode: mode,
                        isSelected: selectedMode == mode,
                        onTap: {
                            withAnimation(.spring(response: 0.3)) {
                                selectedMode = mode
                            }
                        }
                    )
                }
            }
            .padding(.horizontal, 24)

            Spacer()

            // Info text based on selection
            modeInfoText
                .padding(.horizontal, 24)
                .padding(.bottom, 16)

            // Continue button
            Button(action: continueWithSelectedMode) {
                HStack {
                    if isAuthorizing {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    } else {
                        Text("Continue")
                            .fontWeight(.semibold)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(Color.accentColor)
                .foregroundColor(.white)
                .cornerRadius(16)
            }
            .disabled(isAuthorizing)
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
        .background(Color(.systemBackground))
        .alert("Authorization Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    @ViewBuilder
    private var modeInfoText: some View {
        VStack(spacing: 8) {
            switch selectedMode {
            case .individual, .parent:
                Label(
                    "Manage your own screen time. Family controls available in Settings.",
                    systemImage: "iphone"
                )
            case .child:
                Label(
                    "Requires parent approval via Screen Time Family Sharing",
                    systemImage: "person.2"
                )
            }
        }
        .font(.footnote)
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
    }

    private func continueWithSelectedMode() {
        isAuthorizing = true

        // Request authorization for the selected mode
        requestAuthorizer.requestAuthorization(for: selectedMode)

        // Wait a moment for authorization to complete
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if requestAuthorizer.isAuthorized {
                appModeManager.selectMode(selectedMode)
                onModeSelected(selectedMode)
            } else if let error = requestAuthorizer.authorizationError {
                errorMessage = error
                showError = true
            }
            isAuthorizing = false
        }
    }
}

/// Simplified mode card for the two-option selection UI
struct SimplifiedModeCard: View {
    let mode: AppMode
    let isSelected: Bool
    let onTap: () -> Void

    /// Simplified display name for the two-option UI
    private var simplifiedDisplayName: String {
        switch mode {
        case .individual, .parent:
            return "For myself"
        case .child:
            return "Child"
        }
    }

    /// Simplified description for the two-option UI
    private var simplifiedDescription: String {
        switch mode {
        case .individual, .parent:
            return "For personal use"
        case .child:
            return "Parent manages this device"
        }
    }

    /// Icon for the simplified UI
    private var simplifiedIconName: String {
        switch mode {
        case .individual, .parent:
            return "person.fill"
        case .child:
            return "face.smiling.fill"
        }
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 16) {
                // Icon
                Image(systemName: simplifiedIconName)
                    .font(.title2)
                    .foregroundColor(isSelected ? .white : .accentColor)
                    .frame(width: 44, height: 44)
                    .background(
                        Circle()
                            .fill(isSelected ? Color.accentColor : Color.accentColor.opacity(0.1))
                    )

                // Text
                VStack(alignment: .leading, spacing: 4) {
                    Text(simplifiedDisplayName)
                        .font(.headline)
                        .foregroundColor(.primary)

                    Text(simplifiedDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                // Checkmark
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.accentColor)
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(
                                isSelected ? Color.accentColor : Color.clear,
                                lineWidth: 2
                            )
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ModeSelectionView { mode in
        print("Selected mode: \(mode)")
    }
    .environmentObject(RequestAuthorizer())
}
