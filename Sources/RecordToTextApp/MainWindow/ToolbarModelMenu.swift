import RecordToTextCore
import SwiftUI

struct QuickModelMenu: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        Menu {
            ForEach(QuickTranscriptionChoice.allCases) { choice in
                Button {
                    viewModel.selectQuickTranscriptionChoice(choice)
                } label: {
                    Label(
                        choice.displayName,
                        systemImage: quickModelMenuIcon(for: choice)
                    )
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: viewModel.selectedModelIcon)
                Text(viewModel.selectedModelName)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.caption.weight(.medium))
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .fixedSize()
        .help("切換新錄音與尚未開始工作的模型；執行中及檢查點續跑工作維持原設定")
        .accessibilityLabel("轉錄模型")
        .accessibilityValue(viewModel.selectedModelName)
        .accessibilityHint("點擊以切換 Qwen、Vertex AI 或 Google AI Studio")
    }

    private func quickModelMenuIcon(
        for choice: QuickTranscriptionChoice
    ) -> String {
        if viewModel.selectedQuickTranscriptionChoice == choice {
            return "checkmark"
        }
        return choice.backendType == .localQwen ? "apple.logo" : "cloud.fill"
    }
}
