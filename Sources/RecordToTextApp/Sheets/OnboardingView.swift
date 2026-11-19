import AppKit
import RecordToTextCore
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    @State private var step = 0
    @State private var isEnvironmentDetailsPresented = false

    private let stepCount = 3

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: AppSpacing.lg) {
                progressIndicator

                Group {
                    switch step {
                    case 0:
                        backendSelectionStep
                    case 1:
                        outputStep
                    default:
                        environmentStep
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)

            Divider()

            HStack(spacing: AppSpacing.sm) {
                if step > 0 {
                    Button("上一步") {
                        advanceStep(to: step - 1)
                    }
                }

                Spacer()

                if step < stepCount - 1 {
                    Button("繼續") {
                        let next = step + 1
                        advanceStep(to: next)
                        if next == 2 {
                            viewModel.refreshEnvironment()
                            if viewModel.settings.backendType == .localQwen {
                                viewModel.refreshSelectedModelCacheStatus()
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                } else {
                    if needsAdditionalSetupInSettings {
                        Button("完成並開啟設定…") {
                            viewModel.completeOnboarding()
                            openSettings()
                        }
                        .buttonStyle(.bordered)
                    }

                    Button("開始使用") {
                        viewModel.completeOnboarding()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        }
        .frame(width: 680, height: 520)
        .sheet(isPresented: $isEnvironmentDetailsPresented) {
            EnvironmentCheckView(viewModel: viewModel)
                .tint(AppColors.accent)
        }
    }

    private func advanceStep(to target: Int) {
        if reduceMotion {
            step = target
        } else {
            withAnimation(.easeOut(duration: 0.18)) {
                step = target
            }
        }
    }

    private var progressIndicator: some View {
        HStack(spacing: AppSpacing.sm) {
            ForEach(0..<stepCount, id: \.self) { index in
                Capsule()
                    .fill(index <= step ? AppColors.accent : Color.secondary.opacity(0.22))
                    .frame(width: index == step ? 34 : 14, height: 5)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: step)
        .accessibilityLabel("設定步驟 \(step + 1)，共 \(stepCount) 步")
    }

    // MARK: - Step 1: App Icon + Interactive Backend Selection

    private var backendSelectionStep: some View {
        VStack(spacing: AppSpacing.lg) {
            appIconView

            VStack(spacing: 6) {
                Text("選擇適合的轉錄方式")
                    .font(.system(size: 25, weight: .semibold))
                Text("可依隱私與部署需求隨時切換引擎。雲端模式會上傳音訊片段；本機模式全程留在這台 Mac。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }

            BackendSelectionRow(viewModel: viewModel)

            VStack(alignment: .leading, spacing: 8) {
                OnboardingFact(
                    icon: "person.wave.2.fill",
                    text: "Gemini 雲端支援講者區分與時間戳；本機 Qwen 完全離線不外傳"
                )
                OnboardingFact(
                    icon: "character.book.closed.fill",
                    text: "自動輸出台灣繁體中文，並支援專案詞庫與錄音背景提示"
                )
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.vertical, AppSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColors.cardBackground, in: RoundedRectangle(cornerRadius: AppRadius.row))
            .overlay {
                RoundedRectangle(cornerRadius: AppRadius.row)
                    .stroke(AppColors.hairlineBorder(colorSchemeContrast: contrast), lineWidth: 1)
            }
        }
    }

    @ViewBuilder
    private var appIconView: some View {
        if let app = NSApp, let icon = app.applicationIconImage {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(AppColors.accent)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Step 2: Output Home

    private var outputStep: some View {
        VStack(spacing: 22) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 52, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(AppColors.accent)

            VStack(spacing: 8) {
                Text("選擇文字稿的家")
                    .font(.system(size: 25, weight: .semibold))
                Text("預設會把所有轉出的文字檔整理在同一個資料夾。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }

            VStack(alignment: .leading, spacing: AppSpacing.md) {
                Text("目前預設輸出資料夾")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(viewModel.settings.defaultOutputDirectory)
                    .font(AppTypography.monoDetail)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: AppSpacing.sm) {
                    Button("選擇其他資料夾…") {
                        viewModel.chooseDefaultOutputDirectory()
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Text("進入主畫面後，也可改為「與來源同資料夾」")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(AppSpacing.lg)
            .frame(maxWidth: 540, alignment: .leading)
            .background(AppColors.cardBackground, in: RoundedRectangle(cornerRadius: AppRadius.card))
            .overlay {
                RoundedRectangle(cornerRadius: AppRadius.card)
                    .stroke(AppColors.hairlineBorder(colorSchemeContrast: contrast), lineWidth: 1)
            }
        }
    }

    // MARK: - Step 3: Environment & Readiness

    private var needsAdditionalSetupInSettings: Bool {
        if let report = viewModel.environmentReport, !report.isReady {
            return true
        }
        switch viewModel.settings.backendType {
        case .googleAIStudio:
            return viewModel.settings.googleAIStudioAPIKey?
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        case .vertexAI:
            return false
        case .localQwen:
            return !viewModel.isSelectedModelCached
        }
    }

    private var environmentStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 50, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(AppColors.accent)

            VStack(spacing: 7) {
                Text("確認轉錄環境")
                    .font(.system(size: 25, weight: .semibold))
                Text("已依「\(viewModel.settings.backendType.displayName)」檢查所需工具與準備狀態。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }

            if let report = viewModel.environmentReport {
                let allReady = !needsAdditionalSetupInSettings
                InlineCallout(color: allReady ? AppColors.success : AppColors.warning) {
                    HStack(spacing: AppSpacing.md) {
                        Image(systemName: allReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(allReady ? AppColors.success : AppColors.warning)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(allReady ? "環境已就緒" : "尚有設定可於開始前補齊")
                                .font(.headline)
                            Text(environmentStatusMessage(report: report, allReady: allReady))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button("查看詳情") {
                            isEnvironmentDetailsPresented = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .frame(maxWidth: 540)
            } else {
                ProgressView("正在檢查…")
                    .controlSize(.small)
            }
        }
        .onAppear {
            viewModel.refreshEnvironment()
            if viewModel.settings.backendType == .localQwen {
                viewModel.refreshSelectedModelCacheStatus()
            }
        }
    }

    private func environmentStatusMessage(report: EnvironmentReport, allReady: Bool) -> String {
        if allReady {
            return "目前選擇的轉錄引擎與相關工具皆已備妥，可直接拖入錄音開始。"
        }
        if !report.isReady {
            let missing = report.components
                .filter { !$0.isAvailable }
                .map(\.component.displayName)
                .joined(separator: "、")
            return missing.isEmpty
                ? "仍有執行環境待驗證，可按「查看詳情」或稍後在設定處理。"
                : "尚缺元件：\(missing)。可按「查看詳情」檢視安裝與切換指引。"
        }
        if viewModel.settings.backendType == .googleAIStudio {
            return "音訊工具已就緒；可按下方「完成並開啟設定…」貼上 Google AI Studio API Key。"
        }
        return "音訊工具已就緒；可按下方「完成並開啟設定…」下載或匯入本機 Qwen 模型。"
    }
}

private struct OnboardingFact: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(AppColors.accent)
                .frame(width: 20)
            Text(text)
                .font(.callout)
        }
    }
}
