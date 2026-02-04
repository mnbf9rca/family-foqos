import SwiftUI

// MARK: - DEPRECATED
// This component is deprecated as of schema V2. Profile start/stop behavior is now
// configured via ProfileStartTriggers and ProfileStopConditions using the
// StartTriggerSelector and StopConditionSelector components.
// Keeping for backwards compatibility during migration period.

struct BlockingStrategyList: View {
  let strategies: [BlockingStrategy]
  @Binding var selectedStrategy: BlockingStrategy?
  var disabled: Bool = false
  var disabledText: String?

  var body: some View {
    Section("Blocking Strategy") {
      VStack(alignment: .leading, spacing: 8) {
        VStack {
          ForEach(strategies, id: \.name) { strategy in
            StrategyRow(
              strategy: strategy,
              isSelected: selectedStrategy?.name == strategy.name,
              onTap: {
                if !disabled {
                  selectedStrategy = strategy
                }
              }
            )
            .opacity(disabled ? 0.5 : 1)
          }
        }

        if let disabledText = disabledText, disabled {
          Text(disabledText)
            .foregroundStyle(.red)
            .padding(.top, 4)
            .font(.caption)
        }
      }.padding(0)
    }
  }
}

#Preview {
  @Previewable @State var selectedStrategy: BlockingStrategy?
  NavigationStack {
    Form {
      Section {
        BlockingStrategyList(
          strategies: [NFCBlockingStrategy(), ManualBlockingStrategy()],
          selectedStrategy: $selectedStrategy,
          disabled: true,
          disabledText: "Strategy selection is locked"
        )
      }
    }
  }
}
