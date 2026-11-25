import RecordToTextCore
import SwiftUI

/// Grouped provider/model selector for the unified macOS toolbar.
struct ToolbarModelMenu: View {
    @ObservedObject var viewModel: AppViewModel

    private static let aiStudioChoices: [QuickTranscriptionChoice] = [
        .aiStudioGemini4Neon,
        .aiStudioGemini4Hydrogen,
        .aiStudioGemini4Carbon,
        .aiStudioGemini4Argon
    ]

    private static let vertexChoices: [QuickTranscriptionChoice] = [
        .vertexGemini4Neon,
        .vertexGemini4Hydrogen,
        .vertexGemini4Carbon,
        .vertexGemini4Argon
    ]

    var body: some View {
        Menu {
            if Self.showsCustomSelectionHeader(for: viewModel) {
                Section("目前自訂／進階選擇") {
                    Button {} label: {
                        Label(
                            JobModelDisplayHelper.currentEngineSummary(viewModel.settings),
                            systemImage: "checkmark"
                        )
                    }
                    .disabled(true)
                }
            }

            Section("Google AI Studio") {
                ForEach(Self.aiStudioChoices) { choice in
                    choiceButton(for: choice)
                }
            }

            Section("Google Cloud Vertex AI") {
                ForEach(Self.vertexChoices) { choice in
                    choiceButton(for: choice)
                }
            }

            Section("本機 Qwen（不上雲）") {
                ForEach(viewModel.availableModels) { model in
                    Button {
                        selectLocalModel(model.id)
                    } label: {
                        if isLocalModelSelected(model.id) {
                            Label(model.displayName, systemImage: "checkmark")
                        } else {
                            Text(model.displayName)
                        }
                    }
                }
            }

            Divider()

            SettingsLink {
                Label("更多模型與引擎設定…", systemImage: "slider.horizontal.3")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: JobModelDisplayHelper.backendIcon(viewModel.settings.backendType))
                    .foregroundStyle(AppColors.accent)
                Text(JobModelDisplayHelper.currentEngineSummary(viewModel.settings))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .font(AppTypography.chipLabel)
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .fixedSize()
        .help(modelMenuHelpText)
        .accessibilityLabel("轉錄模型")
        .accessibilityValue(JobModelDisplayHelper.currentEngineSummary(viewModel.settings))
        .accessibilityHint("切換新錄音與等待中工作的後端與模型")
    }

    @ViewBuilder
    private func choiceButton(for choice: QuickTranscriptionChoice) -> some View {
        Button {
            viewModel.selectQuickTranscriptionChoice(choice)
        } label: {
            if viewModel.selectedQuickTranscriptionChoice == choice {
                Label(JobModelDisplayHelper.choiceMenuTitle(choice), systemImage: "checkmark")
            } else {
                Text(JobModelDisplayHelper.choiceMenuTitle(choice))
            }
        }
    }

    private func isLocalModelSelected(_ modelID: String) -> Bool {
        viewModel.settings.backendType == .localQwen && viewModel.settings.selectedModelID == modelID
    }

    static func showsCustomSelectionHeader(for viewModel: AppViewModel) -> Bool {
        if viewModel.selectedQuickTranscriptionChoice != nil {
            return false
        }
        if viewModel.settings.backendType == .localQwen,
           viewModel.availableModels.contains(where: { $0.id == viewModel.settings.selectedModelID })
        {
            return false
        }
        return true
    }

    private func selectLocalModel(_ modelID: String) {
        switch modelID {
        case ASRModelDescriptor.appleSiliconDefault.id:
            viewModel.selectQuickTranscriptionChoice(.qwen3ASR1_7B8bit)
        case ASRModelDescriptor.appleSiliconBF16.id:
            viewModel.selectQuickTranscriptionChoice(.qwen3ASR1_7BBF16)
        case ASRModelDescriptor.appleSilicon0_6B8bit.id:
            viewModel.selectQuickTranscriptionChoice(.qwen3ASR0_6B8bit)
        default:
            viewModel.setSetting(\.backendType, to: .localQwen)
            viewModel.setSelectedModelID(modelID)
            viewModel.refreshEnvironment()
        }
    }

    private var modelMenuHelpText: String {
        "切換新錄音與尚未開始工作的模型；執行中及檢查點續跑工作維持原設定"
    }
}

/// Toolbar overflow menu grouping lower-frequency utility actions.
struct ToolbarToolsMenu: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        Menu {
            Button {
                viewModel.chooseAndMergeTranscriptFiles()
            } label: {
                Label("合併文字稿…", systemImage: "arrow.triangle.merge")
            }

            Divider()

            Button {
                viewModel.refreshEnvironment()
                viewModel.isEnvironmentPresented = true
            } label: {
                Label("環境檢查…", systemImage: "checkmark.shield")
            }

            Button {
                viewModel.refreshRecoveryScan()
            } label: {
                Label("復原掃描…", systemImage: "tray.and.arrow.down")
            }

            Divider()

            Button(role: .destructive) {
                viewModel.requestUnsuccessfulCleanup()
            } label: {
                Label("清除未成功項目與殘留檔…", systemImage: "xmark.bin")
            }
            .disabled(!viewModel.hasUnsuccessfulItemsToClean || viewModel.isUnsuccessfulCleanupRunning)
        } label: {
            Label("工具", systemImage: "wrench.and.screwdriver")
        }
        .help("工具：合併文字稿（⌘⇧M）、環境檢查與復原掃描")
        .accessibilityLabel("工具選單")
        .accessibilityHint("開啟合併文字稿、環境檢查與復原掃描選單")
    }
}
