import SwiftUI

/// A view for entering a lock code (PIN) to unlock managed profiles
struct LockCodeEntryView: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let subtitle: String?
    let onVerify: (String) -> Bool
    let onSuccess: () -> Void

    @State private var code: String = ""
    @State private var showError: Bool = false
    @State private var isVerifying: Bool = false

    private let codeLength = 4

    init(
        title: String = "Enter Lock Code",
        subtitle: String? = nil,
        onVerify: @escaping (String) -> Bool,
        onSuccess: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.onVerify = onVerify
        self.onSuccess = onSuccess
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                // Lock icon
                Image(systemName: "lock.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.accentColor)
                    .padding(.top, 40)

                // Title and subtitle
                VStack(spacing: 8) {
                    Text(title)
                        .font(.title2)
                        .fontWeight(.bold)

                    if let subtitle = subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                }

                // Code dots display
                HStack(spacing: 16) {
                    ForEach(0..<codeLength, id: \.self) { index in
                        Circle()
                            .fill(index < code.count ? Color.accentColor : Color(.systemGray4))
                            .frame(width: 16, height: 16)
                            .animation(.easeInOut(duration: 0.1), value: code.count)
                    }
                }
                .padding(.vertical, 8)
                .modifier(ShakeEffect(shakeNumber: showError ? 3 : 0))

                // Error message
                if showError {
                    Text("Incorrect code. Please try again.")
                        .font(.caption)
                        .foregroundColor(.red)
                        .transition(.opacity)
                }

                // Number pad
                VStack(spacing: 12) {
                    ForEach(0..<3) { row in
                        HStack(spacing: 24) {
                            ForEach(1...3, id: \.self) { col in
                                let number = row * 3 + col
                                NumberButton(number: "\(number)") {
                                    addDigit("\(number)")
                                }
                            }
                        }
                    }

                    // Bottom row: empty, 0, delete
                    HStack(spacing: 24) {
                        // Empty space (same size as number buttons)
                        Color.clear
                            .frame(width: 72, height: 72)

                        // 0 button
                        NumberButton(number: "0") {
                            addDigit("0")
                        }

                        // Delete button (same size as number buttons, no background)
                        DeleteButton(disabled: code.isEmpty) {
                            deleteDigit()
                        }
                    }
                }

                Spacer()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func addDigit(_ digit: String) {
        guard code.count < codeLength else { return }

        withAnimation(.easeInOut(duration: 0.1)) {
            showError = false
            code += digit
        }

        // Auto-verify when code is complete
        if code.count == codeLength {
            verifyCode()
        }
    }

    private func deleteDigit() {
        guard !code.isEmpty else { return }
        code.removeLast()
        showError = false
    }

    private func verifyCode() {
        isVerifying = true

        // Small delay for UX
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if onVerify(code) {
                onSuccess()
                dismiss()
            } else {
                withAnimation(.easeInOut) {
                    showError = true
                }
                code = ""
                // Haptic feedback for error
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.error)
            }
            isVerifying = false
        }
    }
}

// MARK: - Number Button

private struct NumberButton: View {
    let number: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(number)
                .font(.title)
                .fontWeight(.medium)
                .foregroundColor(.primary)
                .frame(width: 72, height: 72)
                .background(
                    Circle()
                        .fill(Color(.systemGray6))
                )
        }
        .buttonStyle(LockCodeScaleButtonStyle())
    }
}

// MARK: - Delete Button

private struct DeleteButton: View {
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "delete.backward.fill")
                .font(.title2)
                .foregroundColor(disabled ? Color(.systemGray3) : .primary)
                .frame(width: 72, height: 72)
        }
        .disabled(disabled)
        .buttonStyle(LockCodeScaleButtonStyle())
    }
}

// MARK: - Lock Code Scale Button Style

private struct LockCodeScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Shake Effect

private struct ShakeEffect: GeometryEffect {
    var shakeNumber: CGFloat

    var animatableData: CGFloat {
        get { shakeNumber }
        set { shakeNumber = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let translation = sin(shakeNumber * .pi * 2) * 8
        return ProjectionTransform(CGAffineTransform(translationX: translation, y: 0))
    }
}

// MARK: - Lock Code Setup View

/// A view for setting up a new lock code
struct LockCodeSetupView: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let onSave: (String) -> Void

    @State private var code: String = ""
    @State private var confirmCode: String = ""
    @State private var step: SetupStep = .enter
    @State private var showError: Bool = false

    private let codeLength = 4

    private enum SetupStep {
        case enter
        case confirm
    }

    init(
        title: String = "Set Lock Code",
        onSave: @escaping (String) -> Void
    ) {
        self.title = title
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                // Lock icon
                Image(systemName: step == .enter ? "lock.open.fill" : "lock.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.accentColor)
                    .padding(.top, 40)
                    .animation(.easeInOut, value: step)

                // Title and subtitle
                VStack(spacing: 8) {
                    Text(step == .enter ? title : "Confirm Code")
                        .font(.title2)
                        .fontWeight(.bold)

                    Text(step == .enter
                         ? "Enter a 4-digit code"
                         : "Enter the same code again")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    if step == .enter {
                        Text("This makes your device a parent device")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                // Code dots display
                HStack(spacing: 16) {
                    ForEach(0..<codeLength, id: \.self) { index in
                        let currentCode = step == .enter ? code : confirmCode
                        Circle()
                            .fill(index < currentCode.count ? Color.accentColor : Color(.systemGray4))
                            .frame(width: 16, height: 16)
                            .animation(.easeInOut(duration: 0.1), value: currentCode.count)
                    }
                }
                .padding(.vertical, 8)
                .modifier(ShakeEffect(shakeNumber: showError ? 3 : 0))

                // Error message
                if showError {
                    Text("Codes don't match. Please try again.")
                        .font(.caption)
                        .foregroundColor(.red)
                        .transition(.opacity)
                }

                // Number pad
                VStack(spacing: 12) {
                    ForEach(0..<3) { row in
                        HStack(spacing: 24) {
                            ForEach(1...3, id: \.self) { col in
                                let number = row * 3 + col
                                NumberButton(number: "\(number)") {
                                    addDigit("\(number)")
                                }
                            }
                        }
                    }

                    HStack(spacing: 24) {
                        // Empty space (same size as number buttons)
                        Color.clear
                            .frame(width: 72, height: 72)

                        NumberButton(number: "0") {
                            addDigit("0")
                        }

                        // Delete button (same size as number buttons, no background)
                        DeleteButton(disabled: currentCode.isEmpty) {
                            deleteDigit()
                        }
                    }
                }

                Spacer()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var currentCode: String {
        step == .enter ? code : confirmCode
    }

    private func addDigit(_ digit: String) {
        guard currentCode.count < codeLength else { return }

        withAnimation(.easeInOut(duration: 0.1)) {
            showError = false
            if step == .enter {
                code += digit
            } else {
                confirmCode += digit
            }
        }

        // Check when code is complete
        if currentCode.count == codeLength {
            handleCodeComplete()
        }
    }

    private func deleteDigit() {
        guard !currentCode.isEmpty else { return }
        if step == .enter {
            code.removeLast()
        } else {
            confirmCode.removeLast()
        }
        showError = false
    }

    private func handleCodeComplete() {
        if step == .enter {
            // Move to confirm step
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                withAnimation {
                    step = .confirm
                }
            }
        } else {
            // Verify codes match
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if code == confirmCode {
                    onSave(code)
                    dismiss()
                } else {
                    withAnimation(.easeInOut) {
                        showError = true
                    }
                    confirmCode = ""
                    let generator = UINotificationFeedbackGenerator()
                    generator.notificationOccurred(.error)
                }
            }
        }
    }
}

// MARK: - Preview

#Preview("Lock Code Entry") {
    LockCodeEntryView(
        title: "Enter Lock Code",
        subtitle: "Enter your parent lock code to edit this managed profile",
        onVerify: { code in
            code == "1234"
        },
        onSuccess: {
            print("Success!")
        }
    )
}

#Preview("Lock Code Setup") {
    LockCodeSetupView(
        title: "Set Lock Code",
        onSave: { code in
            print("Code saved: \(code)")
        }
    )
}
